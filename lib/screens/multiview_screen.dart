import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_android/video_player_android.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../models/channel.dart';
import '../services/playlist_manager.dart';
import '../widgets/hold_to_activate.dart';

/// TV-remote-first multiview grid — several live channels playing at
/// once, one with audio focus at a time. Same idea/UX as
/// `DesktopMultiviewScreen` (Windows), independently implemented here
/// against `video_player_hdr` instead of `media_kit` — there is no
/// cross-platform video engine in this app (see `pubspec.yaml`'s
/// media_kit comment), so each platform needs its own.
///
/// Worth naming plainly: `video_player_hdr` can render via a platform view
/// (adopted elsewhere in this app, see `playback_service.dart`'s own doc
/// comment, specifically to dodge an Android GPU-texture rendering bug on
/// a *single* fullscreen stream) or a plain texture. This screen uses
/// [VideoViewType.textureView], not platform views — confirmed directly on
/// real hardware (a Formuler) via a live CPU/thread dump during a glitch:
/// with 3-4 simultaneous platform views, the app alone was pegging ~94%
/// of a CPU core concentrated in the main thread/RenderThread/GC, not any
/// audio or video codec thread — the signature of Android's hybrid-
/// composition overhead for multiple concurrent platform views, not an
/// actual decode bottleneck. A plain texture is a cheap GPU blit per
/// instance instead, which is exactly the "many simultaneous small tiles"
/// shape this screen has (the opposite of the single large fullscreen
/// view platform-view rendering was adopted for elsewhere).
///
/// This re-opens a different, already-fixed bug's risk, though: this
/// app has documented history of a *shared-decode-session* texture bug on
/// real Fire Stick hardware (see `LiveResumeHint`'s doc comment — the
/// scrapped "Live Island" pill: one decode session rendered in two places
/// at once corrupted both). [_MultiviewFullscreenView] reuses a cell's
/// already-playing controller rather than starting a second decode
/// session, but the grid's own cell tile stays mounted underneath while
/// that route is pushed on top (`Navigator.push` doesn't unmount the
/// previous route) — the same two-simultaneous-consumers shape. Needs
/// real-hardware verification specifically on that promote-to-fullscreen
/// flow, the same as everything else in this app.
class MultiviewScreen extends StatefulWidget {
  const MultiviewScreen({super.key});

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

/// Not part of the upstream [VideoPlayerPlatform] interface — callers
/// reach this by casting [VideoPlayerPlatform.instance] to our vendored
/// [AndroidVideoPlayer]. Stops ExoPlayer from decoding/mixing audio for
/// this instance at all (unlike [VideoPlayerHdrController.setVolume],
/// which still pays that cost at zero gain) — background Multiview audio
/// was overloading this device class's audio mixer once several slots
/// were open at once (confirmed via a live `dumpsys media.audio_flinger`
/// capture on a Formuler showing constant AudioTrack churn/teardown).
///
/// Only ever called once, from [_assign], right after a controller is
/// created — never to toggle an already-playing instance's state. That
/// was tried first (toggling whichever cell became active/inactive) and
/// reliably destabilized the toggled cell a few seconds later (a frozen
/// frame with looping audio, or vice versa) on real hardware, even
/// delayed and debounced. [_setActive] now recreates a cell via [_assign]
/// instead of toggling it in place whenever its role needs to change,
/// specifically so this is never called against a controller that's
/// already stable/playing.
Future<void> _setAudioEnabled(
    VideoPlayerHdrController controller, bool enabled) async {
  final platform = VideoPlayerPlatform.instance;
  if (platform is! AndroidVideoPlayer) return;
  // video_player_hdr marks `textureId` @visibleForTesting — its own doc
  // comment says "shouldn't be used by anyone depending on the plugin".
  // Deliberate here anyway: it's the same int video_player_android calls
  // playerId (both sides of that call are our own vendored copy), and
  // there's no other way to address a specific instance from outside the
  // controller. Re-check this if video_player_hdr's version ever bumps.
  // ignore: invalid_use_of_visible_for_testing_member
  await platform.setAudioTrackTypeDisabled(controller.textureId, !enabled);
}

class _MultiviewCell {
  Channel? channel;
  VideoPlayerHdrController? controller;
  final FocusNode focusNode = FocusNode(debugLabel: 'multiview-cell');
}

/// The 4-channel grid was removed — every extra concurrent stream raises
/// how often two cells' independent reconnect cycles collide and trip the
/// provider-side discontinuity documented on `ExoPlayerEventListener
/// .onPlayerError`, and 2 cells measurably held up far better in testing
/// than 3-4. Fixed at 2 now rather than configurable.
class _MultiviewScreenState extends State<MultiviewScreen> {
  static const _cellCount = 2;
  final List<_MultiviewCell> _cells =
      List.generate(_cellCount, (_) => _MultiviewCell());
  int _activeCell = 0;

  /// The cell index currently promoted to [_MultiviewFullscreenView], if
  /// any — see [_openFullscreen]'s own doc comment for why its grid tile
  /// needs to stop rendering its own video widget for as long as that's
  /// true.
  int? _promotedCell;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cells[0].focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final cell in _cells) {
      cell.controller?.dispose();
      cell.focusNode.dispose();
    }
    super.dispose();
  }

  /// Deliberately the *opposite* order from `PlaybackService
  /// .reloadCurrentChannel`'s own "build the replacement fully before
  /// touching the old one" technique — that avoids a black flash when
  /// there's only ever one stream playing, but here several cells are
  /// already decoding at once, close to this hardware's own concurrent-
  /// decoder-session ceiling. Keeping the old controller alive while the
  /// new one initializes briefly needs N+1 simultaneous sessions instead
  /// of N — reported directly as tipping a completely different,
  /// already-stable cell into freezing as a result of reloading or
  /// swapping an unrelated one. Disposing the old controller first here
  /// instead, accepting a brief black flash on the cell actually being
  /// touched, is the safer trade-off once multiview is already this
  /// close to the hardware's real limit.
  Future<void> _assign(int index, Channel channel) async {
    final cell = _cells[index];
    if (cell.controller != null) {
      final old = cell.controller;
      setState(() => cell.controller = null);
      await old!.dispose();
    }
    // mixWithOthers: true — defaults to false, which lets this new
    // controller's own initialize()/play() request *exclusive* Android
    // audio focus even though it's about to be muted for every cell but
    // the active one. That exclusive request is itself enough to make
    // the system silently pause whichever controller actually held
    // focus — reported directly as exactly this: reloading one (muted
    // or not) cell froze the *other*, audio-focused one specifically,
    // not a random sibling, which pointed at audio focus rather than
    // the video decode/rendering path itself.
    final newController = VideoPlayerHdrController.networkUrl(
      Uri.parse(channel.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await newController.initialize(viewType: VideoViewType.textureView);
      if (!mounted) {
        unawaited(newController.dispose());
        return;
      }
      final isActive = index == _activeCell;
      await newController.setVolume(isActive ? 1.0 : 0.0);
      await newController.play();
      setState(() {
        cell.channel = channel;
        cell.controller = newController;
      });
      // See this file's own doc comment on `_setAudioEnabled` for why
      // this is only ever applied once, right here at creation — never to
      // an already-playing cell. Still delayed (not called immediately
      // after creation): doing so corrupted the video surface solid green
      // on real hardware, the same renderer-reset risk the vendored
      // player's own video-dimension-change workaround already documents
      // for this exact trackSelector API. 300ms mirrors that workaround's
      // own delay. The `cell.controller == newController` check guards
      // against this cell having already been reassigned again by the
      // time this fires.
      if (!isActive) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (cell.controller == newController) {
          await _setAudioEnabled(newController, false);
        }
      }
    } catch (_) {
      unawaited(newController.dispose());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn\'t start that channel')));
      }
    }
  }

  /// The "Reload" action — see `PlayerControls`' own Reload button /
  /// `PlaybackService.reloadCurrentChannel`'s doc comment for why a
  /// manual relaunch (not an automatic watchdog) is this app's
  /// established fix for a channel that's silently stalled (frozen
  /// frame, no spinner, no error). Requested directly for every
  /// multiview cell for the same reason.
  Future<void> _reload(int index) async {
    final channel = _cells[index].channel;
    if (channel != null) await _assign(index, channel);
  }

  void _clear(int index) {
    final cell = _cells[index];
    final old = cell.controller;
    setState(() {
      cell.channel = null;
      cell.controller = null;
    });
    unawaited(old?.dispose());
  }

  /// Recreates both the newly- and previously-active cells via [_assign]
  /// rather than toggling either one's audio state in place — see this
  /// file's own doc comment on `_setAudioEnabled` for why. Costs a brief
  /// reconnect/rebuffer on both instead of an instant mute/unmute, the
  /// accepted trade-off for never touching an already-stable cell's audio
  /// state again. A no-op if [index] is already the active cell.
  Future<void> _setActive(int index) async {
    final newChannel = _cells[index].channel;
    if (newChannel == null) return;
    final previousActive = _activeCell;
    if (previousActive == index) return;
    setState(() => _activeCell = index);
    final previousChannel = _cells[previousActive].channel;
    await Future.wait([
      _assign(index, newChannel),
      if (previousChannel != null) _assign(previousActive, previousChannel),
    ]);
  }

  /// True while a picker push is already in flight — [HoldToActivate]'s
  /// own doc comment documents a real, confirmed-on-hardware class of bug
  /// this guards against: a single remote Select press occasionally
  /// reaching both its own synthesized `onTap` *and* the wrapped
  /// `InkWell`'s ambient keyboard-Activate handling, firing the callback
  /// twice. Reported directly here as exactly that shape of symptom — a
  /// flash, then the picker list still showing instead of the grid — a
  /// second `Navigator.push` stacking a second copy of the picker on top
  /// of the first, so popping one just reveals the other underneath. This
  /// makes a second call a no-op instead of a second push, regardless of
  /// what actually triggered it.
  bool _openingPicker = false;

  Future<void> _openPicker(int index) async {
    if (_openingPicker) return;
    _openingPicker = true;
    try {
      final playlist = context.read<PlaylistManager>();
      final channels = playlist.visibleChannels(category: 'tv');
      final chosen = await Navigator.of(context).push<Channel>(
        MaterialPageRoute(
            builder: (_) => _ChannelPickerScreen(channels: channels)),
      );
      if (chosen != null) await _assign(index, chosen);
    } finally {
      _openingPicker = false;
    }
  }

  /// Remote hardware has no separate "swap"/"remove" buttons to aim a
  /// D-pad at the way the Windows screen's mouse-driven icons do — a
  /// held Select (see [HoldToActivate]) opens this instead, the same
  /// "hold for more options" convention the live channel list and the
  /// Timeline guide's program blocks already use elsewhere in this app.
  Future<void> _showCellActions(int index) async {
    if (_cells[index].channel == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.fullscreen, color: Colors.white),
              title: const Text('Full screen',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('fullscreen'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh, color: Colors.white),
              title:
                  const Text('Reload', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('reload'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz, color: Colors.white),
              title: const Text('Change channel',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('swap'),
            ),
            ListTile(
              leading: const Icon(Icons.close, color: Colors.white),
              title:
                  const Text('Remove', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'fullscreen':
        await _openFullscreen(index);
      case 'reload':
        await _reload(index);
      case 'swap':
        await _openPicker(index);
      case 'remove':
        _clear(index);
    }
  }

  /// Reuses the cell's already-playing controller rather than starting a
  /// second decode session for the same stream — this box is already
  /// close to its real concurrent-decoder ceiling (see `_assign`'s doc
  /// comment), so a fullscreen view is just a bigger window onto the same
  /// session, not a new one. A plain `Navigator.push` (no `PopScope`
  /// override here) means Back simply pops this route, landing back on
  /// the multiview grid underneath with that same controller still
  /// playing — requested directly ("back should bring us to the multi
  /// view").
  Future<void> _openFullscreen(int index) async {
    final cell = _cells[index];
    final channel = cell.channel;
    if (channel == null) return;
    // Awaited — if this index wasn't already active, `_setActive` tears
    // down and recreates it (see that method's own doc comment), so the
    // controller to actually show fullscreen doesn't exist yet until this
    // finishes.
    await _setActive(index);
    final controller = cell.controller;
    if (!mounted || controller == null) return;
    // Now that this screen uses textureView (see this file's own top doc
    // comment), the grid tile staying mounted underneath while
    // [_MultiviewFullscreenView] renders the exact same controller on top
    // is the known shared-decode-session bug's shape — two simultaneous
    // consumers of the same texture. Suppressing the grid tile's own
    // video widget for the promoted index (it falls back to the existing
    // "no controller" placeholder) avoids that outright, regardless of
    // view type.
    setState(() => _promotedCell = index);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          _MultiviewFullscreenView(channel: channel, controller: controller),
    ));
    if (mounted) setState(() => _promotedCell = null);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Text('Multiview',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const Icon(Icons.volume_up, color: Colors.amber, size: 16),
                    const SizedBox(width: 4),
                    const Text(
                        '= audio — Select to switch, hold Select for options',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              // Not a theoretical caveat — confirmed directly on real
              // hardware: a provider's own backend enforcing its
              // connection cap *per stream* (not per device) looks
              // exactly like a local playback bug otherwise. A slot
              // beyond the account's limit just stalls a few seconds in,
              // silently, no error shown. See PlaylistProfile
              // .maxConnections' own doc comment, and that field's "Max
              // connections" row in Playlist Manager, for the actual
              // number a given account allows.
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber, size: 14),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Multiview is limited by each playlist\'s maximum '
                        'connections — check Playlist Manager if channels '
                        'stall after a few seconds.',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // Requested directly, after an extensive real-hardware
              // investigation traced Multiview's periodic freezes/
              // buffering to the upstream provider's own server closing
              // and re-establishing each stream's connection every few
              // seconds — concurrent cells' independent reconnect cycles
              // occasionally collide, which media3 detects and fails
              // fast on (see ExoPlayerEventListener.onPlayerError). That
              // failure is now caught and auto-recovered, but the
              // provider-side cause itself isn't something this app can
              // fix — this sets the right expectation instead of letting
              // a stall look like a silent bug.
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber, size: 14),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Freezing or buffering can happen — the app will '
                        'relaunch that channel automatically. If it '
                        'doesn\'t, hold Select on the stream and choose '
                        'Reload.',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // A fixed 2x2 Row-of-Rows, not GridView — GridView is a
              // Scrollable, and its own `childAspectRatio: 16/9` didn't
              // exactly match every real TV's actual available height,
              // making it genuinely scrollable by a few pixels. Reported
              // directly: moving D-pad focus down to the bottom row then
              // triggered Flutter's default "scroll the newly-focused
              // widget into view" behavior, shifting the top row
              // partially off-screen. A plain Row/Column+Expanded layout
              // always exactly fills whatever space is actually
              // available, with no Scrollable involved at all — nothing
              // left for that default behavior to act on.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  // Stacked (Column), not side-by-side — requested
                  // directly: splitting a landscape screen into left/
                  // right halves squeezes each cell into a tall, narrow
                  // near-square, badly distorting a widescreen video's
                  // actual shape. Splitting top/bottom instead lets each
                  // cell span the full screen width, keeping something
                  // much closer to its real aspect ratio even though it's
                  // shorter.
                  // The cell *frame* (border/header/buttons) fills the
                  // whole row, same as a quad cell fills its quarter —
                  // reported directly that constraining the whole frame to
                  // 16:9 (an earlier version of this fix) made dual cells
                  // look noticeably smaller than quad's. Only the video
                  // itself is aspect-constrained now (inside `_buildCell`),
                  // letterboxing within the full-size frame instead of
                  // shrinking the frame around it.
                  // Flex 13:7 instead of a flat 50/50 split when only one
                  // of the two cells actually has a channel in it — a
                  // plain even split made a single active stream look
                  // small (letterboxed within an exactly-half-height row),
                  // reported directly as needing to be "bigger by 30%".
                  // 13:7 gives the occupied row exactly 65% of the
                  // available height, i.e. 1.3x the even-split baseline —
                  // once both cells are filled they're back to equal flex
                  // (13:13) and split evenly like a normal multiview grid.
                  child: Column(
                    children: [
                      Expanded(
                          flex: _cells[0].channel != null ? 13 : 7,
                          child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _buildCell(0))),
                      Expanded(
                          flex: _cells[1].channel != null ? 13 : 7,
                          child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _buildCell(1))),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCell(int index) {
    final cell = _cells[index];
    final active = index == _activeCell && cell.channel != null;
    void onTap() =>
        cell.channel == null ? _openPicker(index) : _setActive(index);
    return HoldToActivate(
      onTap: onTap,
      onHold: cell.channel == null ? null : () => _showCellActions(index),
      child: _MultiviewCellTile(
        focusNode: cell.focusNode,
        channel: cell.channel,
        // null (not cell.controller) while this exact cell is promoted to
        // fullscreen — see _openFullscreen's own doc comment.
        controller: index == _promotedCell ? null : cell.controller,
        active: active,
        onTap: onTap,
        onLongPress:
            cell.channel == null ? null : () => _showCellActions(index),
      ),
    );
  }
}

class _MultiviewCellTile extends StatefulWidget {
  const _MultiviewCellTile({
    required this.focusNode,
    required this.channel,
    required this.controller,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final FocusNode focusNode;
  final Channel? channel;
  final VideoPlayerHdrController? controller;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_MultiviewCellTile> createState() => _MultiviewCellTileState();
}

class _MultiviewCellTileState extends State<_MultiviewCellTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // The frame (border included) is now aspect-constrained to the video's
    // own ratio, not just the video inside it — requested directly: an
    // earlier version of this was reverted for looking "noticeably
    // smaller" next to the quad grid, but quad is gone now, so there's
    // nothing left for a full-row frame to visually match against.
    // (A wider-than-native frame with a BoxFit.cover crop was tried first
    // to also widen the picture itself, but VideoPlayerHdr has no
    // intrinsic size for FittedBox to scale from — it rendered blank.)
    final ratio =
        widget.controller != null && widget.controller!.value.aspectRatio != 0
            ? widget.controller!.value.aspectRatio
            : 16 / 9;
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: InkWell(
          focusNode: widget.focusNode,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onFocusChange: (f) => setState(() => _focused = f),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.active
                    ? Colors.amber
                    : (_focused ? Colors.white : Colors.white24),
                width: widget.active || _focused ? 3 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.controller != null &&
                    widget.controller!.value.isInitialized)
                  VideoPlayerHdr(widget.controller!,
                      key: ObjectKey(widget.controller))
                else
                  ColoredBox(
                    color: const Color(0xFF1A1A1A),
                    child: Center(
                      child: Icon(
                          widget.channel == null
                              ? Icons.add_circle_outline
                              : Icons.hourglass_empty,
                          color: Colors.white38,
                          size: 36),
                    ),
                  ),
                if (widget.channel != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      // Was a 2-stop gradient fading to transparent almost
                      // immediately — reported directly as barely visible
                      // against a bright/busy video frame. A mid-bar stop
                      // keeps the whole header solidly dark (not just its
                      // very top edge) before fading out underneath it, and
                      // the text itself now carries its own shadow as a
                      // second, independent line of contrast — the same
                      // "readable over anything behind it" fix already used
                      // elsewhere in this app (e.g. PosterCard's progress
                      // label) rather than relying on the backdrop alone.
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.6, 1.0],
                          colors: [
                            Colors.black.withValues(alpha: 0.92),
                            Colors.black.withValues(alpha: 0.92),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Row(
                        children: [
                          if (widget.active) ...[
                            const Icon(Icons.volume_up,
                                color: Colors.amber,
                                size: 15,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 4)
                                ]),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              widget.channel!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 4)
                                  ]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pushed from a cell's hold-Select menu ("Full screen") — reuses that
/// cell's already-playing `VideoPlayerHdrController` instead of starting a
/// second decode session for the same stream. Popping (Back) just returns
/// to the multiview grid underneath, where the same controller is still
/// playing, unaffected.
class _MultiviewFullscreenView extends StatefulWidget {
  const _MultiviewFullscreenView(
      {required this.channel, required this.controller});

  final Channel channel;
  final VideoPlayerHdrController controller;

  @override
  State<_MultiviewFullscreenView> createState() =>
      _MultiviewFullscreenViewState();
}

class _MultiviewFullscreenViewState extends State<_MultiviewFullscreenView> {
  final _backFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.setVolume(1.0);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _backFocus.requestFocus());
  }

  @override
  void dispose() {
    _backFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: widget.controller.value.aspectRatio == 0
                    ? 16 / 9
                    : widget.controller.value.aspectRatio,
                child: VideoPlayerHdr(widget.controller,
                    key: ObjectKey(widget.controller)),
              ),
            ),
            Positioned(
              left: 4,
              top: 4,
              child: IconButton(
                focusNode: _backFocus,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: Text(
                  widget.channel.name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Search-and-pick list for assigning a channel to a cell — same shape
/// as `GroupCatalogScreen`'s own picker-style lists, with the same
/// text-field escape fix `_AddProfileScreenState`/`TmdbSettingsScreen`
/// already use elsewhere in this app (see either's own, fuller doc
/// comment): `EditableText` claims arrow keys for itself whenever a text
/// field has focus, so plain default Down traversal never actually
/// escapes a focused search field on real remote hardware, regardless of
/// what's focusable below it.
class _ChannelPickerScreen extends StatefulWidget {
  const _ChannelPickerScreen({required this.channels});

  final List<Channel> channels;

  @override
  State<_ChannelPickerScreen> createState() => _ChannelPickerScreenState();
}

class _ChannelPickerScreenState extends State<_ChannelPickerScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _firstResultFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleSearchFieldEscapeKey);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _firstResultFocus.requestFocus());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleSearchFieldEscapeKey);
    _searchController.dispose();
    _searchFocus.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  bool _handleSearchFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) return false;
    if (FocusManager.instance.primaryFocus != _searchFocus) return false;
    _firstResultFocus.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.channels
        : widget.channels
            .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Pick a channel'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Search channels...',
                hintStyle: TextStyle(color: Colors.white54),
                prefixIcon: Icon(Icons.search, color: Colors.white54),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final c = filtered[i];
                return ListTile(
                  focusNode: i == 0 ? _firstResultFocus : null,
                  leading: (c.logoUrl != null && c.logoUrl!.isNotEmpty)
                      ? Image.network(c.logoUrl!,
                          width: 32,
                          height: 32,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.tv, color: Colors.white54))
                      : const Icon(Icons.tv, color: Colors.white54),
                  title:
                      Text(c.name, style: const TextStyle(color: Colors.white)),
                  onTap: () => Navigator.of(context).pop(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
