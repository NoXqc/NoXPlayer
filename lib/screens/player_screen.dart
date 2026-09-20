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

/// Fullscreen playback screen. Pushed when a channel is tapped on a phone,
/// or when the mini-player bar is tapped to expand back into fullscreen —
/// either way it attaches to the same shared [PlaybackService] controller,
/// so it never restarts playback that's already running.
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

  /// Refreshed on every build (see [build]) and read from [_toggleImmersive]
  /// / [_restoreChrome] / [dispose] — those don't call [build] themselves,
  /// so this caches the last-known answer rather than doing a fresh
  /// `context.watch`/`MediaQuery.of` lookup from places where that's
  /// unsafe (dispose) or unnecessary (a plain button handler).
  bool _isTvLayout = false;

  final FocusScopeNode _topScope = FocusScopeNode(debugLabel: 'player-top');
  final FocusScopeNode _bottomScope =
      FocusScopeNode(debugLabel: 'player-bottom');

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

  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.play(widget.channel);
    // Read by LiveResumeHint — stops its hold-Right gesture from firing
    // again on top of an already-showing fullscreen view, and hides its
    // reminder text while this is showing. Deferred a frame: this is
    // called from `initState`, itself running mid-build for the frame
    // that's mounting this freshly-pushed route — `setFullscreenActive`'s
    // `notifyListeners()` reaching another, already-mounted widget's
    // `setState()` at that exact moment isn't a safe time to do it.
    // Confirmed on real hardware as the cause of the reminder text
    // sometimes not hiding when it should: a release build has no
    // assertion for this (unlike debug), so the resulting rebuild just
    // silently got lost instead of throwing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playback.setFullscreenActive(true);
    });
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
      final moved = FocusManager.instance.primaryFocus
              ?.focusInDirection(TraversalDirection.up) ??
          false;
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
      final moved = FocusManager.instance.primaryFocus
              ?.focusInDirection(TraversalDirection.down) ??
          false;
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

  /// A remote's dedicated hardware Play/Pause button (or separate Play/
  /// Pause keys, on remotes that split them) should just work regardless
  /// of where D-pad focus currently is — requiring the user to navigate to
  /// the on-screen button first defeats the entire point of a physical
  /// media key existing. Bound alongside Up/Down below rather than gated
  /// by `!_focusInBar` the way Left/Right are: this should fire no matter
  /// which bar (if any) currently has focus, not just when none does. A
  /// remote with no such key simply never sends this event — the on-screen
  /// button (and D-pad navigation to it) keeps working exactly as before.
  void _handlePlayPause() {
    final controller = _playback.controller;
    if (controller == null) return;
    _resetHideTimer();
    controller.value.isPlaying ? controller.pause() : controller.play();
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
    // Deferred a frame for the same reason `initState` defers the
    // opposite call — this runs mid-build for the frame that's tearing
    // down this route, not a safe time for another widget's `setState`
    // to land. `_playback` is a long-lived singleton, safe to touch
    // after this widget's own disposal.
    //
    //
    // Live TV deliberately keeps playing in the background (see
    // LiveResumeHint) — channel-surfing while keeping a live stream "on
    // standby" is a real pattern a live stream's own lack of a fixed
    // endpoint supports. A movie/episode has a clear stop, and backing
    // out was reported directly as leaving it audibly still playing with
    // no way back short of manually finding and reselecting it — no
    // resume prompt exists for VOD at all, unlike live. Stopping it here
    // instead, with the exact position saved (see
    // PlaybackService._teardown), means Continue Watching is the one,
    // deliberate way back in, instead of a confusing background audio
    // leak with no discoverable resume path. Bundled into the same
    // deferred callback as setFullscreenActive below — stop() also calls
    // notifyListeners(), the exact same "not safe mid-teardown" case that
    // callback already exists for.
    final ch = _playback.currentChannel;
    final shouldStopVod = ch != null && !Channel.isLiveId(ch.rawId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shouldStopVod) unawaited(_playback.stop());
      _playback.setFullscreenActive(false);
    });
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
            (prefs.isTelevision ||
                MediaQuery.of(context).size.width >=
                    AppConstants.tvLayoutWidthThreshold));

    return withTvThemeIfNeeded(
        context,
        (context) => Scaffold(
              backgroundColor: Colors.black,
              body: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.arrowUp): _handleUp,
                  const SingleActivator(LogicalKeyboardKey.arrowDown):
                      _handleDown,
                  // Some remotes send a single combined key, others send separate
                  // Play and Pause keys (e.g. a dedicated Pause button) — bound to
                  // the same toggle handler either way, since it already checks
                  // the actual current state rather than assuming.
                  const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
                      _handlePlayPause,
                  const SingleActivator(LogicalKeyboardKey.mediaPlay):
                      _handlePlayPause,
                  const SingleActivator(LogicalKeyboardKey.mediaPause):
                      _handlePlayPause,
                  if (!_focusInBar) ...{
                    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                        Navigator.of(context).pop(),
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
                    // `Positioned` widget, with no exceptions — see [_UpNextBubble]
                    // for why: Stack only sizes itself to fill the available space
                    // (`constraints.biggest`) when *every* child is `Positioned`;
                    // a single non-positioned child (even a zero-size
                    // `SizedBox.shrink()`) makes Stack size itself to fit that
                    // child instead, which was collapsing this entire Stack —
                    // video included — to 0x0 whenever `_UpNextBubble` had nothing
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
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 4),
                                    child: SafeArea(
                                      bottom: false,
                                      child: Row(
                                        children: [
                                          _TopBarIconButton(
                                            icon: Icons.arrow_back,
                                            tooltip: 'Back',
                                            onPressed: () =>
                                                Navigator.of(context).pop(),
                                          ),
                                          Expanded(
                                            child: _searchScope == 'TV'
                                                ? EpgGuide(
                                                    // rawId, not the
                                                    // composite `id` — see
                                                    // PlaylistManager
                                                    // .knownChannelIdsFor's
                                                    // doc comment.
                                                    channelId: channel.rawId)
                                                : Text(
                                                    channel.name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        color: Colors.white),
                                                  ),
                                          ),
                                          _TopBarIconButton(
                                            icon: Icons.search,
                                            tooltip: 'Search',
                                            onPressed: () =>
                                                Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) => SearchScreen(
                                                    initialScope: _searchScope),
                                              ),
                                            ),
                                          ),
                                          _TopBarIconButton(
                                            icon: _immersive
                                                ? Icons.fullscreen_exit
                                                : Icons.fullscreen,
                                            tooltip: _immersive
                                                ? 'Exit fullscreen'
                                                : 'Fullscreen',
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
                                      // rawId, not the composite `id` —
                                      // see PlaylistManager
                                      // .knownChannelIdsFor's doc comment;
                                      // Channel.isLiveId also documents
                                      // that it expects rawId, not id.
                                      channelId: channel.rawId,
                                      isLive: Channel.isLiveId(channel.rawId),
                                      isFavorite: channel.isFavorite,
                                      onToggleFavorite: () =>
                                          playlist.toggleFavorite(channel),
                                      onPrevious: playback.previousUpChannel !=
                                              null
                                          ? () => playback
                                              .play(playback.previousUpChannel!)
                                          : null,
                                      onNext: playback.nextUpChannel != null
                                          ? () => playback
                                              .play(playback.nextUpChannel!)
                                          : null,
                                      onActivity: _resetHideTimer,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                        if (controller != null)
                          _UpNextBubble(
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
class _UpNextBubble extends StatelessWidget {
  const _UpNextBubble({
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
  static const _hidden = Positioned(
      right: 24, bottom: 110, width: 0, height: 0, child: SizedBox.shrink());

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
                              errorWidget: (_, __, ___) =>
                                  const _UpNextFallbackIcon(),
                            )
                          : const _UpNextFallbackIcon(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Up Next',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 12)),
                        Text(
                          next.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          countdown > 0
                              ? 'Playing in ${countdown}s'
                              : 'Playing now...',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_circle_fill,
                            color: Colors.white, size: 30),
                        tooltip: 'Play now',
                        onPressed: onPlayNow,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white54, size: 18),
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

class _UpNextFallbackIcon extends StatelessWidget {
  const _UpNextFallbackIcon();

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
class _TopBarIconButton extends StatefulWidget {
  const _TopBarIconButton(
      {required this.icon, required this.onPressed, this.tooltip});

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  State<_TopBarIconButton> createState() => _TopBarIconButtonState();
}

class _TopBarIconButtonState extends State<_TopBarIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Same translucent-white-fill swap as everywhere else for Minimalist
    // — see `_tvButtonStyle`'s doc comment.
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    final focusFill =
        isMinimal ? Colors.white.withValues(alpha: 0.16) : scheme.primary;
    final focusForeground = isMinimal ? Colors.white : scheme.onPrimary;
    final button = Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: _focused ? focusFill : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onPressed,
          onFocusChange: (f) => setState(() => _focused = f),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(widget.icon,
                color: _focused ? focusForeground : Colors.white, size: 22),
          ),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: button)
        : button;
  }
}
