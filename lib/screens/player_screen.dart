import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../utils/constants.dart';
import '../utils/tv_theme.dart';
import '../widgets/epg_guide.dart';
import '../widgets/player_controls.dart';
import 'search_screen.dart';

/// Fullscreen playback screen for VOD/episodes. Pushed the same way for
/// every channel type — attaches to the same shared [PlaybackService]
/// controller, so it never restarts playback that's already running.
///
/// **Live playback redirect**: a *live* channel never actually shows this
/// screen's own chrome. `LiveIslandOverlay` (a sibling of the `Navigator`,
/// not a descendant — see main.dart's `builder`) owns one persistent video
/// widget for whatever's live, with two presentations (fullscreen chrome,
/// or the small floating pill) driven purely by `PlaybackService
/// .isMinimized` — never a pushed/popped route. That's deliberate: a
/// pushed route for the "fullscreen" state would get buried under
/// whatever the user navigates to *next* while minimized, breaking "the
/// pill follows you anywhere" the moment they visit a second screen. It
/// also sidesteps a real, reproducible native-Android bug found tonight:
/// pushing a fresh route for every fullscreen-minimize-fullscreen cycle
/// recreates the video's platform view's native `SurfaceView` each time,
/// and doing that in quick succession races the previous one's teardown,
/// leaving a stale, invisible-yet-touch-blocking view sitting over the
/// pill — confirmed on real hardware, and confirmed absent when the
/// underlying view is never destroyed and recreated to begin with.
///
/// So every existing call site still just does
/// `Navigator.push(MaterialPageRoute(builder: (_) => PlayerScreen(channel:
/// ...)))` unchanged, for both VOD and live — [initState] below is the one
/// place that decides which behavior a given channel actually gets. For a
/// live channel, it calls `play()` + `restore()` (which is all
/// `LiveIslandOverlay` needs to show its own fullscreen presentation,
/// already rendered as a sibling *above* this route) and pops itself on
/// the very next frame without ever building a Scaffold/video of its own
/// — see [_isLiveRedirect].
///
/// Also owns the actual "fullscreen" behavior other apps mean by that word:
/// landscape orientation + hidden system bars ([_toggleImmersive]) — but
/// only the "hidden system bars" half of that on a TV-sized screen. A TV
/// never physically rotates, so forcing an orientation there does nothing
/// useful and can actively backfire: [AppPreferences.layoutMode] "auto"
/// (see main.dart) picks the TV UI vs. phone UI based on
/// `MediaQuery.size.width`, and forcing `portraitUp` on restore was
/// observed to shrink that reported width enough to flip the *entire app*
/// into the phone layout after leaving fullscreen on a TV box. Orientation
/// is now only ever touched when [_isTvLayout] is false.
///
/// D-pad navigation is a small explicit state machine rather than default
/// focus traversal, mirroring the fix applied to [TvHomeScreen]'s columns:
/// - **Left**, whenever focus hasn't been deliberately moved into the top
///   or bottom bar, exits back to the channel/catalog list — the primary
///   way out on a remote, not just the physical device Back button.
/// - **Up** first reveals the top bar (back/search/fullscreen + the
///   current/next EPG line for live channels); pressed again, it moves
///   focus onto the back button so Left/Right can reach Search too.
/// - **Down** does the same for the bottom bar (title/seek bar/play-pause).
/// Both bars auto-hide after inactivity so they can't permanently trap the
/// D-pad the way the seek bar used to.
///
/// Popping this route for a VOD/episode needs no special handling on the
/// way out — playback just keeps running unrepresented in the background
/// via the same shared [PlaybackService], since it already has its own
/// resumable "Continue Watching" entry and a floating bubble that keeps a
/// VOD playing indefinitely isn't wanted there. Live channels don't reach
/// this build at all; see the redirect above.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.channel});

  final Channel channel;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _immersive = false;
  bool _topVisible = false;
  bool _bottomVisible = false;
  Timer? _hideTimer;

  /// Captured once instead of doing `context.read` inside the deferred
  /// `Navigator.pop()` callback the live redirect above schedules — that
  /// callback can fire after this screen's element is already being torn
  /// down, where a fresh `context.read` isn't safe, but a plain Dart
  /// object reference captured ahead of time stays perfectly usable
  /// regardless of the widget's own lifecycle.
  late final PlaybackService _playback;

  /// Refreshed on every build (see [build]) and read from [_toggleImmersive]
  /// / [_restoreChrome] / [dispose] — those don't call [build] themselves,
  /// so this caches the last-known answer rather than doing a fresh
  /// `context.watch`/`MediaQuery.of` lookup from places where that's
  /// unsafe (dispose) or unnecessary (a plain button handler).
  bool _isTvLayout = false;

  final FocusScopeNode _topScope = FocusScopeNode(debugLabel: 'player-top');
  final FocusScopeNode _bottomScope = FocusScopeNode(debugLabel: 'player-bottom');

  bool get _focusInBar => _topScope.hasFocus || _bottomScope.hasFocus;

  /// Search from the player should land on the tab that matches what's
  /// playing — inferred from the Xtream id prefix (see
  /// XtreamApiService.getVodStreams/getSeriesEpisodes/getLiveStreams).
  String get _searchScope {
    final id = widget.channel.id;
    if (id.startsWith('xt_vod_')) return 'Movies';
    if (id.startsWith('xt_ep_')) return 'TV Shows';
    return 'TV';
  }

  /// Live channels never actually show this screen's own chrome — see the
  /// class doc comment's "Live playback redirect" section. Set in
  /// [initState] and read from [build] so both places agree without
  /// recomputing `Channel.isLiveId` from possibly-stale local state.
  bool _isLiveRedirect = false;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.play(widget.channel);
    // `play()` only resets `isMinimized` when it actually starts a *new*
    // channel — reopening fullscreen for whatever's already playing (the
    // exact minimized-live scenario: tapping the same channel again, or
    // any other manual way back in) hits its "already this channel"
    // no-op guard and returns before reaching that reset, so the island
    // stayed marked minimized (and visible) even with fullscreen back on
    // top of it. This being called at all means we're not minimized,
    // unconditionally, regardless of how playback itself got here.
    _playback.restore();
    _isLiveRedirect = Channel.isLiveId(widget.channel.id);
    if (_isLiveRedirect) {
      // See "Live playback redirect" — pop this route on the very next
      // frame instead of ever building its Scaffold/video. `restore()`
      // above already flipped `isMinimized` to false, which is all
      // `LiveIslandOverlay` needs to show its own fullscreen chrome+video
      // (rendered as a sibling *above* the Navigator, so it's already
      // visible underneath this route's brief, invisible flash). Every
      // existing call site keeps pushing `PlayerScreen(channel: ...)`
      // unchanged — VOD/episodes vs. live is decided here, in one place,
      // rather than requiring every call site to branch.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }
    _topScope.addListener(_onBarFocusChange);
    _bottomScope.addListener(_onBarFocusChange);
    _resetHideTimer();
  }

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

  /// Once inside a bar (e.g. focus on the new favorite-star button next to
  /// the seek bar), Up/Down always jumping straight to "reveal/focus the
  /// scope" — instead of first trying to move to the *next* thing in that
  /// bar (star → play/pause) — left nothing reachable past the star: the
  /// exact "trapped, can't do anything else" bug the seek bar itself used
  /// to have. Try the normal move first, same fallback pattern used
  /// elsewhere this session; only fall back to the reveal/jump behavior
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

  @override
  void dispose() {
    _hideTimer?.cancel();
    _topScope.removeListener(_onBarFocusChange);
    _bottomScope.removeListener(_onBarFocusChange);
    _topScope.dispose();
    _bottomScope.dispose();
    // Defensive: never leave the whole app stuck in landscape/immersive
    // mode if this screen is popped while _immersive was still on.
    if (_immersive) _restoreChrome();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // See "Live playback redirect" on the class doc comment — this route
    // is about to pop itself (already scheduled in initState) and must
    // never build a Scaffold/video of its own for a live channel, since
    // `LiveIslandOverlay` is already showing its own fullscreen
    // presentation underneath this brief, otherwise-invisible frame.
    if (_isLiveRedirect) return const SizedBox.shrink();
    final playback = context.watch<PlaybackService>();
    final controller = playback.controller;
    final prefs = context.watch<AppPreferences>();
    // Just to rebuild (and so the star reflects the current state) when
    // toggled from this screen — widget.channel is the same object
    // instance PlaylistManager.toggleFavorite mutates, not a copy.
    final playlist = context.watch<PlaylistManager>();
    // Auto-advancing into the next episode (see PlaybackService's up-next
    // queue) swaps `playback.currentChannel` without this screen being
    // popped/re-pushed — everything below reflects whatever's *actually*
    // playing, not just the episode this screen was originally opened for.
    final channel = playback.currentChannel ?? widget.channel;
    _isTvLayout = prefs.layoutMode == 'tv' ||
        (prefs.layoutMode == 'auto' &&
            MediaQuery.of(context).size.width >= AppConstants.tvLayoutWidthThreshold);

    return withTvThemeIfNeeded(context, (context) => Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowUp): _handleUp,
          const SingleActivator(LogicalKeyboardKey.arrowDown): _handleDown,
          if (!_focusInBar) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => Navigator.of(context).pop(),
            // Right never had any established purpose here — it simply had
            // no handler at all, so with no bar focused (nothing else on
            // this screen to move to) it fell through to Flutter's
            // *default* directional focus search across every focusable
            // widget currently attached, including whatever's still
            // mounted (just covered, never torn down) on the route
            // underneath. If that was a big Movies/TV Shows catalog with
            // hundreds of poster cards, that geometric search over a huge
            // focus graph is expensive enough to hang weaker hardware —
            // confirmed on real hardware as a genuine ANR ("Input
            // dispatching timed out... Waited 5004ms for KeyEvent", CPU at
            // 186%), not a clean exception: the video kept playing (it's
            // driven independently of the Dart UI thread) while the UI
            // froze solid until Android force-killed the app. A no-op here,
            // same as Left/Up/Down always being consumed, is enough.
            const SingleActivator(LogicalKeyboardKey.arrowRight): () {},
          },
        },
        child: Focus(
          autofocus: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _revealBottomOnTap,
            // No outer SafeArea here (deliberately — it was tried and
            // wasn't the fix; left off anyway since it's unneeded once the
            // real bug below is fixed). The top/bottom bars keep their own
            // narrow `SafeArea(bottom: false)` for their own content.
            //
            // Every entry in this Stack's children list must resolve to a
            // `Positioned` widget, with no exceptions — see [UpNextBubble]
            // for why: Stack only sizes itself to fill the available space
            // (`constraints.biggest`) when *every* child is `Positioned`;
            // a single non-positioned child (even a zero-size
            // `SizedBox.shrink()`) makes Stack size itself to fit that
            // child instead, which was collapsing this entire Stack —
            // video included — to 0x0 whenever `UpNextBubble` had nothing
            // to show (i.e. essentially always). That was the actual cause
            // of the black fullscreen screen.
            child: Stack(
              children: [
                  Positioned.fill(
                    // See HomeScreen's identical fix for why this is
                    // keyed to the channel rather than const.
                    child: VideoPlayerPane(
                      key: ValueKey(channel.id),
                      showControls: false,
                      showEpgBar: false,
                    ),
                  ),

                  // Top bar: back, current/next EPG line (live only), search,
                  // fullscreen toggle. Positioned has to be the outermost
                  // widget of this Stack entry — burying it under
                  // ExcludeFocus/AnimatedOpacity (as an earlier draft of
                  // this did) breaks Stack's "nearest RenderObjectWidget
                  // ancestor" resolution for Positioned's parent data.
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
                                      onPressed: () => Navigator.of(context).pop(),
                                    ),
                                    Expanded(
                                      child: _searchScope == 'TV'
                                          ? EpgGuide(channelId: channel.id)
                                          : Text(
                                              channel.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(color: Colors.white),
                                            ),
                                    ),
                                    TopBarIconButton(
                                      icon: Icons.search,
                                      tooltip: 'Search',
                                      onPressed: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => SearchScreen(initialScope: _searchScope),
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
                  if (controller != null)
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
                                isLive: Channel.isLiveId(channel.id),
                                isFavorite: channel.isFavorite,
                                onToggleFavorite: () => playlist.toggleFavorite(channel),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                  if (controller != null)
                    UpNextBubble(
                      controller: controller,
                      nextChannel: playback.nextUpChannel,
                      onPlayNow: () {
                        final next = playback.nextUpChannel;
                        if (next != null) playback.play(next);
                      },
                      onDismiss: playback.dismissAutoAdvance,
                    ),
                ],
              ),
          ),
        ),
      ),
    ));
  }
}

/// A Netflix-style "Up Next" card in the corner of the screen once an
/// episode is close to ending — [PlaybackService] already auto-advances
/// at 30 seconds remaining; this surfaces that instead of letting it
/// happen silently, and lets the user jump immediately or cancel it for
/// this episode. Reacts to the controller directly (not `PlaybackService`,
/// which only notifies on channel/controller changes) since it needs to
/// know the position every tick, the same way the seek bar does.
class UpNextBubble extends StatelessWidget {
  const UpNextBubble({
    super.key,
    required this.controller,
    required this.nextChannel,
    required this.onPlayNow,
    required this.onDismiss,
  });

  final VideoPlayerHdrController controller;
  final Channel? nextChannel;
  final VoidCallback onPlayNow;
  final VoidCallback onDismiss;

  static const _showAt = Duration(seconds: 45);
  static const _autoAdvanceAt = Duration(seconds: 30);

  // Every branch below returns a `Positioned`, never a bare widget — this
  // sits directly in PlayerScreen's Stack (not wrapped in Positioned at
  // the call site), and Stack's sizing rule is "size to fill the available
  // space only if EVERY child is Positioned; otherwise size to fit the
  // non-positioned children instead". A single bare `SizedBox.shrink()`
  // here (the "nothing to show" case, which is most of the time) used to
  // demote the whole Stack to a non-positioned-children layout, and since
  // that shrink box's natural size is zero, the entire Stack — video
  // included — collapsed to 0x0 and painted nothing. This was the actual
  // cause of the black fullscreen screen; confirmed via a LayoutBuilder +
  // RenderBox size dump (NOX_DIAG) showing bounded incoming constraints
  // but a 0x0 resulting Stack size.
  static const _hidden = Positioned(right: 24, bottom: 110, width: 0, height: 0, child: SizedBox.shrink());

  @override
  Widget build(BuildContext context) {
    final next = nextChannel;
    if (next == null) return _hidden;
    return ValueListenableBuilder<VideoPlayerHdrValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final duration = value.duration;
        if (duration <= Duration.zero) return _hidden;
        final remaining = duration - value.position;
        if (remaining > _showAt || remaining < Duration.zero) return _hidden;

        final countdown = (remaining - _autoAdvanceAt).inSeconds.clamp(0, 999);
        final hasLogo = next.logoUrl != null && next.logoUrl!.isNotEmpty;

        return Positioned(
          right: 24,
          bottom: 110,
          width: 320,
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: hasLogo
                          ? CachedNetworkImage(
                              imageUrl: next.logoUrl!,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => const UpNextFallbackIcon(),
                            )
                          : const UpNextFallbackIcon(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Up Next', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        Text(
                          next.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          countdown > 0 ? 'Playing in ${countdown}s' : 'Playing now...',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_circle_fill, color: Colors.white, size: 30),
                        tooltip: 'Play now',
                        onPressed: onPlayNow,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                        tooltip: 'Dismiss',
                        onPressed: onDismiss,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class UpNextFallbackIcon extends StatelessWidget {
  const UpNextFallbackIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade800,
      alignment: Alignment.center,
      child: const Icon(Icons.movie, color: Colors.white38, size: 28),
    );
  }
}

/// Plain [IconButton]s gave no visible cue for which of the top bar's three
/// buttons the D-pad cursor was actually on — Material's default focus
/// highlight is too subtle to read at 10-foot distance, especially over a
/// busy video background. Same highlight pattern as the rest of the TV UI
/// (Material+InkWell+onFocusChange, e.g. TvHomeScreen's _SelectableRow): a
/// solid filled circle behind the icon while focused.
class TopBarIconButton extends StatefulWidget {
  const TopBarIconButton({super.key, required this.icon, required this.onPressed, this.tooltip});

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  State<TopBarIconButton> createState() => TopBarIconButtonState();
}

class TopBarIconButtonState extends State<TopBarIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: _focused ? scheme.primary : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onPressed,
          onFocusChange: (f) => setState(() => _focused = f),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(widget.icon, color: _focused ? scheme.onPrimary : Colors.white, size: 22),
          ),
        ),
      ),
    );
    return widget.tooltip != null ? Tooltip(message: widget.tooltip!, child: button) : button;
  }
}
