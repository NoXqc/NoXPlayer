import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../screens/player_screen.dart';
import '../screens/search_screen.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import '../utils/tv_theme.dart';
import '../widgets/epg_guide.dart';
import '../widgets/player_controls.dart';

/// Owns *everything* about watching live TV once a channel starts playing:
/// the fullscreen chrome (top/bottom bars, EPG line, Up Next bubble) *and*
/// the small floating "island" pill — the same idea as iOS's Dynamic
/// Island or HyperOS's floating notification — shown while browsing
/// anywhere else in the app. These are two presentations of the same
/// state, not two different screens: [PlaybackService.isMinimized] alone
/// decides which one is showing, and there is exactly one persistent
/// `_LiveVideoSurface` underneath both (see [_buildVideo]).
///
/// **Why this owns the video too, instead of [PlayerScreen] pushing a
/// route for it (like VOD/episodes still do)**: two real, reproduced
/// problems, both root-caused on a real Firestick.
///
/// 1. The pill needs to float above *whatever screen the user has
///    navigated to since minimizing* (Settings, Search, a different TV
///    group, anything) — not just the one screen it appeared on top of.
///    A pushed route can't do that; it gets buried under the next thing
///    pushed on top of it. Being a sibling of the `Navigator` (see
///    main.dart's `builder`) is what makes "floats above anything,
///    everywhere" possible at all — `Navigator.of(context)` from in here
///    finds nothing, which is why [navigatorKey] exists, for the one
///    thing that still needs the *real* Navigator (Search).
/// 2. Every fullscreen-minimize-fullscreen cycle used to push a brand new
///    [PlayerScreen] route, which mounted a brand new `VideoPlayerHdr`
///    platform view — a real native Android `SurfaceView` — every single
///    time, discarding the previous one. Cycling that quickly (expand,
///    then minimize again within a couple seconds) raced the previous
///    view's teardown against the new one's creation: confirmed on real
///    hardware via `dumpsys SurfaceFlinger` that the *native* layer
///    hierarchy was completely normal in both the working and failing
///    cases — no stale/leaked surface, nothing visibly wrong natively —
///    which points at Flutter's own bookkeeping of where that platform
///    view's "hole" belongs going stale faster than its async native-side
///    size-confirmation round-trip could keep up. The pill would end up
///    genuinely present in the widget tree (confirmed: a D-pad hold-Down
///    could still focus it) yet invisible *and* touch-blind — Flutter had
///    left a stale hole over it. Waiting longer between cycles gave that
///    round-trip time to settle and reliably avoided it, which is exactly
///    the signature of a resize/recreate race, not a logic bug. The only
///    fix that structurally can't hit this: never destroy the platform
///    view across a minimize/expand cycle in the first place — see
///    [_buildVideo]'s `key`, which only ever changes on a genuine channel
///    switch, never on expand/collapse.
///
/// [PlayerScreen] still exists and still gets pushed via `Navigator.push`
/// from every existing call site, for both VOD and live — it just quietly
/// redirects for a live channel instead of showing anything of its own
/// (see that class's doc comment). `initState` there already calls
/// `play()` + `restore()`, which is all this widget needs to show its
/// expanded presentation; the pushed route pops itself a frame later.
class LiveIslandOverlay extends StatefulWidget {
  const LiveIslandOverlay({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<LiveIslandOverlay> createState() => _LiveIslandOverlayState();
}

class _LiveIslandOverlayState extends State<LiveIslandOverlay> {
  // ---------------------------------------------------------------------
  // Collapsed (pill) state — unchanged from before this rewrite.
  // ---------------------------------------------------------------------

  // Was 3 seconds — confirmed on real hardware as feeling much too slow
  // for something you do repeatedly; HoldToActivate's favorite-hold uses
  // 550ms, but this changes focus across a bigger jump (into/out of a
  // whole separate overlay, not just toggling one row's favorite state),
  // so it stays a bit more deliberate than that to avoid firing on a
  // slightly-too-long ordinary press.
  static const _holdDuration = Duration(milliseconds: 1200);

  /// Groups the pill's own focusable pieces (the resume tap target, the
  /// play/pause button) so [_handleGlobalKey] can tell "focus is
  /// somewhere on the island" (`.hasFocus`, true for the scope or any
  /// descendant) apart from "focus is somewhere else in the app" with one
  /// check, and so [_focusIsland] has one thing to call `.requestFocus()`
  /// on regardless of which specific descendant ends up taking it — same
  /// `FocusScopeNode` pattern the expanded bars below use too.
  final FocusScopeNode _islandScope = FocusScopeNode(debugLabel: 'live-island');

  /// Whatever had focus right before [_focusIsland] moved it onto the
  /// island — restored by [_leaveIsland] so holding Up to leave lands
  /// back where the user actually was, not wherever Flutter's default
  /// fallback would otherwise pick.
  FocusNode? _previousFocus;

  Timer? _enterHoldTimer;
  Timer? _leaveHoldTimer;
  bool _enterHoldFired = false;
  bool _leaveHoldFired = false;

  /// One-time onboarding hint shown the first time the pill ever appears
  /// (see [_maybeShowHint]) — persisted via StorageService so it only
  /// ever shows once, not every time something gets minimized.
  Timer? _hintTimer;
  bool _showHint = false;

  /// Edge-detection for the collapsed pill specifically (not the expanded
  /// chrome — see [_wasExpanded] for that one), read/written only in
  /// [build].
  bool _wasPillVisible = false;

  // ---------------------------------------------------------------------
  // Expanded (fullscreen chrome) state — ported from the old PlayerScreen,
  // which no longer builds any of this for a live channel. See that
  // class's doc comment for why.
  // ---------------------------------------------------------------------

  bool _immersive = false;
  bool _topVisible = false;
  bool _bottomVisible = false;
  Timer? _hideTimer;
  bool _wasExpanded = false;

  /// Refreshed on every build, read from [_toggleImmersive]/[_restoreChrome]
  /// — those don't call `build` themselves, so this caches the last-known
  /// answer rather than doing a fresh `context.watch`/`MediaQuery.of`
  /// lookup from a plain button handler.
  bool _isTvLayout = false;

  final FocusScopeNode _topScope = FocusScopeNode(debugLabel: 'live-player-top');
  final FocusScopeNode _bottomScope = FocusScopeNode(debugLabel: 'live-player-bottom');

  bool get _focusInBar => _topScope.hasFocus || _bottomScope.hasFocus;

  /// Search from here should land on the TV tab — a live channel is the
  /// only thing this widget ever shows fullscreen for, unlike
  /// `PlayerScreen`'s version of this getter which also has to handle VOD.
  static const _searchScope = 'TV';

  /// Captured once and listened to directly (`addListener`/`setState`)
  /// instead of `context.watch<PlaybackService>()` in [build] — see git
  /// history for the investigation that ruled out `context.watch` making
  /// any difference to the bug this rewrite actually fixes; kept as-is
  /// since there's no reason to churn it further.
  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.addListener(_onPlaybackChanged);
    // NOT HardwareKeyboard.instance.addHandler — confirmed on real hardware
    // (and in Flutter's own source: hardware_keyboard.dart's
    // KeyEventManager.keyMessageHandler doc comment literally says "All
    // destinations will always receive the event regardless of the
    // handlers' results") that a HardwareKeyboard handler's return value
    // does NOT stop the event from also reaching the focus tree — it's a
    // parallel, always-fires observer, not a gate. That's exactly why an
    // earlier version of this "consumed" the key yet the underlying
    // screen's own Down-navigation still rapid-fired the whole time it
    // was held. `FocusManager.addEarlyKeyEventHandler` is the actual gate:
    // it runs before any focus-tree handler, and returning
    // `KeyEventResult.handled` here genuinely stops the event from
    // reaching whatever's focused underneath.
    FocusManager.instance.addEarlyKeyEventHandler(_handleGlobalKey);
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleGlobalKey);
    _enterHoldTimer?.cancel();
    _leaveHoldTimer?.cancel();
    _hintTimer?.cancel();
    _hideTimer?.cancel();
    _islandScope.dispose();
    _topScope.removeListener(_onBarFocusChange);
    _bottomScope.removeListener(_onBarFocusChange);
    _topScope.dispose();
    _bottomScope.dispose();
    if (_immersive) _restoreChrome();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Collapsed (pill) gestures — unchanged from before this rewrite.
  // ---------------------------------------------------------------------

  /// Two symmetric hold gestures, watched ahead of the normal focus tree
  /// (see [initState]) rather than woven into every screen's own focus
  /// scope — a real architectural cost for a rarely-used escape hatch.
  ///
  /// Same technique `HoldToActivate` already uses for "hold Select to
  /// favorite" (see that widget's doc comment): claim the key fully from
  /// the first `KeyDownEvent`, so none of Android's repeated key-downs
  /// during a physical hold ever reach whatever's focused underneath —
  /// then, on `KeyUpEvent`, if the hold never actually completed, manually
  /// perform the equivalent of whatever a normal quick press would have
  /// done (`focusInDirection`) instead of just discarding it. Two earlier,
  /// simpler attempts each got half of this right and not the other: pure
  /// observation (never consuming) let every repeat leak through as real
  /// navigation, visibly scrolling whatever list was focused for the
  /// whole hold; pure consumption (claiming it always, with no synthesized
  /// tap) killed Down entirely for as long as the island was showing. This
  /// is the actual fix — a quick press behaves exactly as if the island
  /// didn't exist, and only a genuine sustained hold does anything extra.
  KeyEventResult _handleGlobalKey(KeyEvent event) {
    final playback = _playback;
    // Must match [build]'s pill-visibility condition exactly, not just
    // `isMinimized` alone — an earlier bug had these two disagree, which
    // left this watching for a hold that could never resolve to anything
    // visible. Gating on the exact same condition the pill's own
    // visibility uses makes that structurally impossible.
    final show = playback.isMinimized && playback.currentChannel != null && playback.controller != null;
    if (!show) return KeyEventResult.ignored;

    final onIsland = _islandScope.hasFocus;

    if (!onIsland && event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) {
        _enterHoldFired = false;
        _enterHoldTimer?.cancel();
        _enterHoldTimer = Timer(_holdDuration, () {
          _enterHoldFired = true;
          _focusIsland();
        });
        return KeyEventResult.handled;
      }
      // Confirmed the actual remaining leak: Android sends a distinct
      // `KeyRepeatEvent` — not another `KeyDownEvent` — for every repeat
      // while a directional key is physically held (this is exactly why
      // holding Down scrolls a list smoothly at all). Only checking for
      // `KeyDownEvent`/`KeyUpEvent` left every one of those unclaimed, so
      // they kept leaking through as real navigation the whole hold, no
      // different from not consuming anything at all.
      // `HoldToActivate` never needed this: Select/Enter doesn't auto-
      // repeat on this remote, only the directional keys do.
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (event is KeyUpEvent) {
        _enterHoldTimer?.cancel();
        _enterHoldTimer = null;
        if (!_enterHoldFired) {
          FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.down);
        }
        return KeyEventResult.handled;
      }
    }

    if (onIsland && event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (event is KeyDownEvent) {
        _leaveHoldFired = false;
        _leaveHoldTimer?.cancel();
        _leaveHoldTimer = Timer(_holdDuration, () {
          _leaveHoldFired = true;
          _leaveIsland();
        });
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (event is KeyUpEvent) {
        _leaveHoldTimer?.cancel();
        _leaveHoldTimer = null;
        if (!_leaveHoldFired) {
          FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up);
        }
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  void _focusIsland() {
    _enterHoldTimer = null;
    if (!mounted) return;
    if (!_playback.isMinimized) return;
    _previousFocus = FocusManager.instance.primaryFocus;
    _islandScope.requestFocus();
  }

  void _leaveIsland() {
    _leaveHoldTimer = null;
    if (!mounted) return;
    final prev = _previousFocus;
    _previousFocus = null;
    // A node captured minutes ago could have been disposed by whatever
    // screen owned it rebuilding in the meantime — this is genuinely the
    // only way to find out, there's no public "is this node still safe to
    // use" check to ask first.
    try {
      if (prev != null) {
        prev.requestFocus();
        return;
      }
    } catch (_) {
      // Falls through to the plain unfocus below.
    }
    _islandScope.unfocus();
  }

  /// Used to be a `Navigator.push` of a fresh `PlayerScreen` — now purely
  /// a state flip. See the class doc comment for why that push was itself
  /// the bug.
  void _expand() {
    if (_playback.currentChannel == null) return;
    _playback.restore();
  }

  /// Called once, the first time [build] sees the pill transition from
  /// hidden to shown — reads/writes the persisted flag directly (no
  /// context.watch involved) so this never re-fires just because
  /// something else rebuilt this widget while already showing.
  void _maybeShowHint() {
    final storage = context.read<StorageService>();
    if (storage.getHasSeenLiveIslandHint()) return;
    unawaited(storage.setHasSeenLiveIslandHint());
    setState(() => _showHint = true);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  // ---------------------------------------------------------------------
  // Expanded (fullscreen chrome) behavior — ported from the old
  // PlayerScreen almost verbatim; see that class's doc comment.
  // ---------------------------------------------------------------------

  void _onBarFocusChange() {
    if (mounted) setState(() {});
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() {
          _topVisible = false;
          _bottomVisible = false;
        });
      }
    });
  }

  /// Once inside a bar (e.g. focus on the favorite-star button next to the
  /// seek bar), Up/Down always jumping straight to "reveal/focus the
  /// scope" — instead of first trying to move to the *next* thing in that
  /// bar (star → play/pause) — left nothing reachable past the star. Try
  /// the normal move first; only fall back to the reveal/jump behavior
  /// once there's nowhere further to go.
  void _handleUp() {
    _resetHideTimer();
    if (_focusInBar) {
      final moved = FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up) ?? false;
      if (moved) return;
    }
    if (!_topVisible) {
      setState(() => _topVisible = true);
      return;
    }
    _topScope.requestFocus();
  }

  void _handleDown() {
    _resetHideTimer();
    if (_focusInBar) {
      final moved = FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.down) ?? false;
      if (moved) return;
    }
    if (!_bottomVisible) {
      setState(() => _bottomVisible = true);
      return;
    }
    _bottomScope.requestFocus();
  }

  void _revealBottomOnTap() {
    _resetHideTimer();
    setState(() => _bottomVisible = true);
  }

  Future<void> _toggleImmersive() async {
    final next = !_immersive;
    setState(() => _immersive = next);
    if (next) {
      if (!_isTvLayout) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await _restoreChrome();
    }
  }

  Future<void> _restoreChrome() async {
    if (!_isTvLayout) {
      // Release the lock instead of forcing portraitUp specifically — a
      // phone/tablet held sideways (or a tablet used in landscape as its
      // normal orientation) shouldn't get snapped to portrait just because
      // it watched a video fullscreen; letting go of the restriction lets
      // the sensor/app defaults decide instead.
      await SystemChrome.setPreferredOrientations([]);
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// The one persistent video widget for whatever's live — created once
  /// per channel (the key only changes on a genuine channel switch, never
  /// on expand/collapse) and never destroyed across a minimize/expand
  /// cycle. See the class doc comment for exactly why that matters, and
  /// [_LiveVideoSurface]'s for why this isn't `VideoPlayerPane`.
  Widget _buildVideo(Channel channel, VideoPlayerHdrController controller) {
    return _LiveVideoSurface(key: ValueKey(channel.id), controller: controller);
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback;
    final channel = playback.currentChannel;
    final controller = playback.controller;
    // `isSilentlyResuming` (see PlaybackService's doc comment) must gate
    // this exactly like it gates TvHomeScreen's preview pane — a cold-
    // start background resume shouldn't make this overlay jump straight
    // to its fullscreen presentation before the user has actually looked
    // for it, even though the stream itself is already loading regardless.
    // Missing this check reintroduced that exact bug: `isMinimized`
    // starts `false` by default, and a silent resume never calls
    // `restore()`, so without this, `expanded` below would evaluate
    // `true` immediately on cold start.
    final hasVideo = channel != null &&
        controller != null &&
        Channel.isLiveId(channel.id) &&
        !playback.isSilentlyResuming;

    if (!hasVideo) {
      // Always Positioned, shown or not — see the doc comment on
      // `UpNextBubble` (player_screen.dart) for why a bare non-Positioned
      // child here would collapse this whole Stack (and the Navigator
      // painted alongside it) to 0x0.
      _wasPillVisible = false;
      _wasExpanded = false;
      return const Positioned(bottom: 24, left: 0, right: 0, child: SizedBox.shrink());
    }

    final expanded = !playback.isMinimized;

    // ---- Collapsed-pill hint-bubble edge detection (unchanged shape). ----
    final pillVisible = !expanded;
    if (pillVisible && !_wasPillVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeShowHint();
      });
    } else if (!pillVisible && _wasPillVisible) {
      // The pill just disappeared (expanded to fullscreen). Hard-reset
      // every bit of state tied to it being on screen — any of this left
      // dangling from one cycle (an armed hold timer, `_islandScope`
      // still reporting `hasFocus` after its own widget was already
      // replaced) could desync from reality and poison the next time the
      // pill appears.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _enterHoldTimer?.cancel();
        _enterHoldTimer = null;
        _enterHoldFired = false;
        _leaveHoldTimer?.cancel();
        _leaveHoldTimer = null;
        _leaveHoldFired = false;
        _previousFocus = null;
        _islandScope.unfocus();
      });
    }
    _wasPillVisible = pillVisible;

    // ---- Expanded-chrome edge detection. ----
    if (expanded && !_wasExpanded) {
      _resetHideTimer();
    } else if (!expanded && _wasExpanded) {
      // Leaving fullscreen the same way PlayerScreen's old `dispose()`
      // used to — except this Element never actually gets disposed
      // anymore, so this is the only place left to do it.
      if (_immersive) {
        _immersive = false;
        unawaited(_restoreChrome());
      }
    }
    _wasExpanded = expanded;

    final video = Positioned(
      // Expanded: fills the screen. Collapsed: shrunk to a barely-there
      // 6x6 dot tucked in the corner — NOT a visible "still recording"
      // thumbnail, which was tried first and hit a real, separate bug on
      // real hardware: TvHomeScreen's own preview pane is a completely
      // independent consumer of the same controller, and having both a
      // visible thumbnail *and* that preview pane mounted simultaneously
      // meant two native decoder surfaces competing for the same stream
      // — confirmed as the cause of the thumbnail freezing on its first
      // frame while the other consumer kept updating. Shrinking it to
      // where "frozen or not" is imperceptible sidesteps that without
      // touching TvHomeScreen's own, separately-already-fixed preview
      // pane. Not zero/negative size, which risks its own class of
      // platform-view edge case — just small enough not to matter. Same
      // `_buildVideo` widget either way — only its bounds change, never
      // its identity.
      //
      // The Material/GestureDetector wrapper below is UNCONDITIONAL —
      // present with the same widget types in both branches, differing
      // only in property *values* (onTap). Branching the wrapper's
      // presence itself (e.g. only wrapping when collapsed) would change
      // this slot's child *type* between builds, which Flutter treats as
      // "this is a different widget" regardless of any key on a
      // descendant — tearing down and recreating the video Element (and
      // its native platform view) on every expand/collapse after all,
      // silently undoing the entire point of this rewrite. Confirmed the
      // hard way while building this.
      //
      // `clipBehavior` is unconditionally `Clip.none` — confirmed on real
      // hardware as the cause of a *third*, separate real bug when this
      // was `Clip.antiAlias` for the thumbnail: clipping a platform view
      // forces Android's embedding onto a fallback compositing path
      // instead of a direct hardware overlay, and this HDR video
      // rendered through that fallback path came out badly washed out —
      // visible even full-screen, where nothing was being clipped at
      // all, and even affecting other content in the same frame. Now
      // that the collapsed size is an imperceptible dot, there's nothing
      // worth rounding/clipping anyway.
      left: expanded ? 0 : null,
      top: expanded ? 0 : 4,
      right: expanded ? 0 : 4,
      bottom: expanded ? 0 : null,
      width: expanded ? null : 6,
      height: expanded ? null : 6,
      child: Material(
        color: Colors.black,
        clipBehavior: Clip.none,
        child: GestureDetector(
          onTap: expanded ? null : _expand,
          child: _buildVideo(channel, controller),
        ),
      ),
    );

    if (!expanded) {
      return Stack(children: [video, _buildPill(playback, channel, controller)]);
    }

    return Stack(children: [video, _buildExpandedChrome(context, playback, channel, controller)]);
  }

  Widget _buildPill(PlaybackService playback, Channel channel, VideoPlayerHdrController controller) {
    // Bottom, not top — the TV layout's top bar/tab row and most screens'
    // AppBars already occupy the top edge; bottom-center stays clear of
    // all of them and matches where the older Home-only MiniPlayerBar
    // already sits, so "now playing" is always in the same place.
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showHint) ...[
                const _IslandHintBubble(),
                const SizedBox(height: 8),
              ],
              FocusScope(
                node: _islandScope,
                child: _IslandPill(
                  title: channel.name,
                  controller: controller,
                  onExpand: _expand,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedChrome(
    BuildContext context,
    PlaybackService playback,
    Channel channel,
    VideoPlayerHdrController controller,
  ) {
    final prefs = context.watch<AppPreferences>();
    final playlist = context.watch<PlaylistManager>();
    _isTvLayout = prefs.layoutMode == 'tv' ||
        (prefs.layoutMode == 'auto' &&
            MediaQuery.of(context).size.width >= AppConstants.tvLayoutWidthThreshold);

    return Positioned.fill(
      child: withTvThemeIfNeeded(
        context,
        (context) => BackButtonListener(
          onBackButtonPressed: () async {
            _playback.minimize();
            return true;
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowUp): _handleUp,
                const SingleActivator(LogicalKeyboardKey.arrowDown): _handleDown,
                if (!_focusInBar) ...{
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): _playback.minimize,
                  // Right never had any established purpose here — see
                  // the identical guard this was ported from in
                  // player_screen.dart for the ANR this avoids: with no
                  // handler, it falls through to Flutter's expensive
                  // default directional focus search across every
                  // focusable widget currently attached — and everything
                  // underneath (TvHomeScreen, its catalog) is *always*
                  // still mounted now, not just "covered by a route", so
                  // this guard matters even more here than it did there.
                  const SingleActivator(LogicalKeyboardKey.arrowRight): () {},
                },
              },
              child: Focus(
                autofocus: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _revealBottomOnTap,
                  // Every entry in this Stack's children list must resolve
                  // to a `Positioned` widget — see `UpNextBubble`'s doc
                  // comment (player_screen.dart) for why.
                  child: Stack(
                    children: [
                      // Top bar: back (minimizes, doesn't pop — there's no
                      // route here to pop), current/next EPG line, search,
                      // fullscreen toggle.
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ExcludeFocus(
                          excluding: !_topVisible,
                          child: AnimatedOpacity(
                            opacity: _topVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: FocusTraversalGroup(
                              child: FocusScope(
                                node: _topScope,
                                child: Container(
                                  color: Colors.black54,
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                  child: SafeArea(
                                    bottom: false,
                                    child: Row(
                                      children: [
                                        TopBarIconButton(
                                          icon: Icons.arrow_back,
                                          tooltip: 'Back',
                                          onPressed: _playback.minimize,
                                        ),
                                        Expanded(child: EpgGuide(channelId: channel.id)),
                                        TopBarIconButton(
                                          icon: Icons.search,
                                          tooltip: 'Search',
                                          onPressed: () => widget.navigatorKey.currentState?.push(
                                            MaterialPageRoute(
                                              builder: (_) => const SearchScreen(initialScope: _searchScope),
                                            ),
                                          ),
                                        ),
                                        TopBarIconButton(
                                          icon: _immersive ? Icons.fullscreen_exit : Icons.fullscreen,
                                          tooltip: _immersive ? 'Exit fullscreen' : 'Fullscreen',
                                          onPressed: _toggleImmersive,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Bottom bar: title, seek bar, play/pause.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ExcludeFocus(
                          excluding: !_bottomVisible,
                          child: AnimatedOpacity(
                            opacity: _bottomVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: FocusTraversalGroup(
                              child: FocusScope(
                                node: _bottomScope,
                                child: PlayerControls(
                                  controller: controller,
                                  title: channel.name,
                                  channelId: channel.id,
                                  isLive: true,
                                  isFavorite: channel.isFavorite,
                                  onToggleFavorite: () => playlist.toggleFavorite(channel),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // No `UpNextBubble` here — `PlaybackService
                      // .nextUpChannel` only ever resolves against a VOD/
                      // episode queue (`_upNextQueue`, set by
                      // SeriesDetailScreen) that a live channel's id is
                      // never part of, so it would always be hidden. See
                      // PlayerScreen for the VOD path that actually uses it.
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one persistent live-video surface — used for BOTH the fullscreen
/// presentation and the small corner thumbnail, always the exact same
/// widget type at the exact same key either way (only the outer
/// `Positioned` bounds around it differ — see [_LiveIslandOverlayState
/// .build]), so its native platform view is never destroyed and
/// recreated just because its *size* changed. That's the entire point
/// of this rewrite, so this deliberately is NOT `VideoPlayerPane`: that
/// widget's error/loading fallback is full paragraphs of text sized for
/// a full screen (a "Technical details" ExpansionTile included) —
/// confirmed on real hardware that reusing it here overflowed illegibly
/// once crammed into a 128x72 thumbnail. This stays legible, or at
/// least harmless, at any size.
class _LiveVideoSurface extends StatelessWidget {
  const _LiveVideoSurface({super.key, required this.controller});

  final VideoPlayerHdrController controller;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: ValueListenableBuilder<VideoPlayerHdrValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          if (value.hasError) {
            return const Center(
              child: Icon(Icons.error_outline, color: Colors.white38, size: 20),
            );
          }
          if (!value.isInitialized) {
            return const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Center(
            child: AspectRatio(
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
              // Keyed to the controller instance — same reasoning as
              // `VideoPlayerPane`'s identical fix: forces Flutter to
              // recreate this specific leaf if the controller instance
              // itself is ever swapped without this whole surface being
              // rebuilt around it, rather than silently rebinding a
              // stale platform view in place.
              child: VideoPlayerHdr(controller, key: ObjectKey(controller)),
            ),
          );
        },
      ),
    );
  }
}

/// One-time explainer shown next to the pill the very first time it
/// appears — nothing about a floating pill's function is self-evident
/// (an iOS user recognizes the shape; nobody's D-pad-navigated one
/// before), so this spells out the two gestures that matter.
class _IslandHintBubble extends StatelessWidget {
  const _IslandHintBubble();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
      child: const Text(
        'Hold Down to select, Hold Up to leave',
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}

/// The pill itself: a breathing "live" dot + channel name (tap/select to
/// resume fullscreen) and a small play/pause toggle, as two separate
/// focusable pieces side by side rather than one nested inside the
/// other's tap target — overlapping focus/tap areas there made D-pad
/// Right-to-reach-the-button and touch-tap-the-button ambiguous with
/// tapping the pill body itself.
class _IslandPill extends StatefulWidget {
  const _IslandPill({required this.title, required this.controller, required this.onExpand});

  final String title;
  final VideoPlayerHdrController controller;
  final VoidCallback onExpand;

  @override
  State<_IslandPill> createState() => _IslandPillState();
}

class _IslandPillState extends State<_IslandPill> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat(reverse: true);

  // Flutter's default focus visual for a plain InkWell/IconButton is a
  // faint tinted overlay — confirmed on real hardware as "way too subtle"
  // to read at 10-foot distance. Tracking focus explicitly and swapping
  // to a solid accent fill instead matches the convention already used
  // everywhere else in this TV UI (e.g. PlayerScreen's TopBarIconButton,
  // TvHomeScreen's _SelectableRow).
  bool _resumeFocused = false;
  bool _buttonFocused = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Confirmed on real hardware: a plain black87 fill with just a
    // Material elevation shadow was nearly invisible sitting over a dark
    // video frame (the exact spot this pill usually appears, right after
    // leaving a live channel) — visible if you knew to look for it, but
    // easy to mistake for "gone". An explicit accent-colored border reads
    // clearly against literally any background, video included, instead
    // of relying on a brightness/shadow contrast that a dark scene can
    // defeat entirely.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.primary, width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.7), blurRadius: 14, spreadRadius: 1),
        ],
      ),
      child: Material(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: _resumeFocused ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: widget.onExpand,
              onFocusChange: (f) => setState(() => _resumeFocused = f),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, child) {
                        final t = Curves.easeInOut.transform(_pulse.value);
                        return Opacity(opacity: 0.35 + (t * 0.65), child: child);
                      },
                      child: Icon(
                        Icons.circle,
                        color: _resumeFocused ? scheme.onPrimary : Colors.redAccent,
                        size: 10,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _resumeFocused ? scheme.onPrimary : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ValueListenableBuilder<VideoPlayerHdrValue>(
            valueListenable: widget.controller,
            builder: (context, value, _) => Tooltip(
              message: value.isPlaying ? 'Pause' : 'Play',
              child: Material(
                color: _buttonFocused ? scheme.primary : Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onFocusChange: (f) => setState(() => _buttonFocused = f),
                  onTap: () => value.isPlaying ? widget.controller.pause() : widget.controller.play(),
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: _buttonFocused ? scheme.onPrimary : Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    ));
  }
}
