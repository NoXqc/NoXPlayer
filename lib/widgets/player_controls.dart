import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import 'epg_guide.dart';

/// Renders whatever [PlaybackService] is currently playing.
///
/// Purely presentational — it doesn't own a controller or start playback
/// itself; call `context.read<PlaybackService>().play(channel)` to start
/// something, and every mounted [VideoPlayerPane] (inline pane, fullscreen
/// screen, mini-player) reflects the same live video.
class VideoPlayerPane extends StatelessWidget {
  const VideoPlayerPane(
      {super.key, this.showEpgBar = true, this.showControls = true});

  final bool showEpgBar;

  /// [PlayerScreen] renders its own auto-hiding controls overlay (so the
  /// seek bar can't permanently steal D-pad focus) and just wants the bare
  /// video here — pass false there.
  final bool showControls;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackService>();
    final channel = playback.currentChannel;
    final controller = playback.controller;

    if (channel == null || controller == null) {
      return const Center(child: Text('Select a channel to start watching'));
    }

    if (playback.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_friendlyPlaybackError(playback.error!),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ExpansionTile(
                title: const Text('Technical details',
                    style: TextStyle(fontSize: 12)),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      playback.error!,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<void>(
      future: playback.initFuture,
      builder: (context, snapshot) {
        if (!controller.value.isInitialized) {
          return const Center(child: CircularProgressIndicator());
        }

        return Column(
          children: [
            // rawId, not the composite `id` — see
            // PlaylistManager.knownChannelIdsFor's doc comment.
            if (showEpgBar) EpgGuide(channelId: channel.rawId),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Plain AspectRatio again — the FittedBox-at-native-size
                  // workaround tried here was for the stock `video_player`
                  // package's Texture-stretch bug specifically, which is
                  // exactly what switching to `video_player_hdr`'s
                  // platform-view rendering is meant to avoid needing a
                  // workaround for at all.
                  Center(
                    child: AspectRatio(
                      aspectRatio: controller.value.aspectRatio == 0
                          ? 16 / 9
                          : controller.value.aspectRatio,
                      // Keyed to the controller instance — confirmed on
                      // real hardware as the cause of a frozen frame
                      // surviving a channel switch: with no key here,
                      // Flutter sees "same widget type, same position"
                      // when a new controller replaces the old one and
                      // tries to update the existing platform view
                      // element in place instead of tearing it down and
                      // creating a fresh one. On this device's renderer
                      // that in-place rebind doesn't actually take — the
                      // native surface keeps showing whatever the
                      // previous channel last painted. Same fix shape as
                      // Group Management's checkbox stale-repaint bug
                      // earlier this session: force element recreation
                      // via a changing key instead of relying on an
                      // in-place update this hardware silently drops.
                      child: VideoPlayerHdr(controller,
                          key: ObjectKey(controller)),
                    ),
                  ),
                  if (showControls)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: PlayerControls(
                        controller: controller,
                        title: channel.name,
                        // rawId, not the composite `id` — see
                        // PlaylistManager.knownChannelIdsFor's doc comment;
                        // Channel.isLiveId also documents that it expects
                        // rawId, not id.
                        channelId: channel.rawId,
                        isLive: Channel.isLiveId(channel.rawId),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Translates the handful of raw platform exceptions actually seen in the
/// wild into something a viewer can act on. Confirmed on real hardware
/// (a Formuler box) via a `MediaCodecVideoRenderer` error dumping a 4K
/// HEVC 10-bit HDR (`ColorInfo(BT2020, ..., ST2084 PQ, ..., 10bit)`)
/// stream's format — the device's decoder reports the format as
/// supported (`format_supported=YES`) but still fails to actually decode
/// it. That's a real hardware/driver limitation on that box, not
/// something `video_player`/Flutter can route around — no amount of app
/// code makes an incapable decoder chip decode 10-bit HDR. This just
/// stops surfacing that as a raw stack-trace-shaped string.
String _friendlyPlaybackError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('mediacodecvideorenderer') ||
      (lower.contains('hevc') && lower.contains('10bit'))) {
    return 'This device\'s hardware video decoder can\'t play this stream — '
        'likely a 4K HDR (HEVC 10-bit) format it doesn\'t support, even '
        'though it claims to. This is a hardware limitation, not something '
        'the app can fix. If your provider offers a non-4K/HD version of '
        'this channel or title, try that instead.';
  }
  return 'Playback error:\n$raw';
}

/// Bottom-anchored playback controls: play/pause, seek bar, elapsed/total
/// duration. Rebuilds on every controller tick via [ValueListenableBuilder]
/// rather than manual `setState` calls. Fullscreen/immersive mode is a
/// screen-level concern (see [PlayerScreen]), not a control-bar one.
class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.controller,
    required this.title,
    required this.channelId,
    required this.isLive,
    this.isFavorite,
    this.onToggleFavorite,
    this.onPrevious,
    this.onNext,
  });

  final VideoPlayerHdrController controller;
  final String title;

  /// Which EPG programme to check remaining time against — only read
  /// when [isLive] is true.
  final String channelId;

  /// Whether [controller]'s own `duration`/`position` should be trusted
  /// at all for the seek bar and skip buttons. Confirmed on real hardware:
  /// some live HLS streams report a small *nonzero* duration here — the
  /// length of their current DVR sliding window (e.g. ~60s), not the
  /// zero/unknown value a clean live stream reports — which made the seek
  /// bar activate and show a constantly-resetting ~1-minute timer instead
  /// of staying hidden the way a real live stream's `duration == 0` case
  /// already did. `video_player_hdr` has no live/VOD signal of its own to
  /// check instead (its `VideoPlayerHdrValue` has no `isLive` field) — so
  /// this comes from the caller, which already knows the channel's
  /// id-based classification (`Channel.isLiveId`), never from the video
  /// duration. When true, the seek bar/skip buttons/elapsed-duration text
  /// are replaced by the current EPG programme's remaining time instead
  /// (see [_LiveRemainingLabel]) — actually meaningful for a live channel,
  /// unlike a number that resets every minute.
  final bool isLive;

  /// Null hides the favorite button entirely (the shared inline preview
  /// panes don't pass these) — [PlayerScreen] is the one caller that does,
  /// so pressing Down to reveal these controls also surfaces "add to
  /// favorites" for whatever's playing.
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;

  /// Null hides the button entirely — a movie or live channel has no
  /// previous/next *episode* concept (see PlaybackService.previousUpChannel/
  /// nextUpChannel, both null in that case), and only [PlayerScreen] passes
  /// these at all, same as [onToggleFavorite] above.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ValueListenableBuilder<VideoPlayerHdrValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final position = value.position;
          final duration = value.duration;
          // See [isLive]'s doc comment — never inferred from duration.
          final showSeek = !isLive && duration.inMilliseconds > 0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (showSeek)
                    Text(
                      '${_formatDuration(position)} / ${_formatDuration(duration)}',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    )
                  else if (isLive)
                    _LiveRemainingLabel(channelId: channelId),
                ],
              ),
              // Excluded from D-pad focus always: a focused Slider consumes
              // Left/Right itself for seeking, ahead of any ancestor
              // Shortcuts/CallbackShortcuts trying to use those keys for
              // navigation (e.g. PlayerScreen's "Left always goes back").
              // Touch/mouse dragging is unaffected — this only removes it
              // from keyboard/remote focus traversal.
              if (showSeek)
                ExcludeFocus(
                  child: Slider(
                    value: position.inMilliseconds
                        .clamp(0, duration.inMilliseconds)
                        .toDouble(),
                    max: duration.inMilliseconds.toDouble(),
                    onChanged: (v) =>
                        controller.seekTo(Duration(milliseconds: v.toInt())),
                  ),
                ),
              // All the action buttons live in one row now — favorite
              // used to sit alone above the seek bar, which put it out of
              // reach of normal up/down movement within this bar (Up from
              // there had nowhere to go but out to the top bar). Grouped
              // here with play/pause (and skip, for VOD) instead, with
              // room to add more later.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (onToggleFavorite != null)
                    IconButton(
                      icon: Icon(
                        isFavorite == true ? Icons.star : Icons.star_border,
                        color: isFavorite == true ? Colors.amber : Colors.white,
                      ),
                      tooltip: isFavorite == true
                          ? 'Remove from favorites'
                          : 'Add to favorites',
                      onPressed: onToggleFavorite,
                    ),
                  // Episode nav — distinct icon shape (skip_previous/next,
                  // not replay_10/forward_10) so it doesn't read as "seek
                  // within this episode" the way the buttons either side
                  // of play/pause already do.
                  if (onPrevious != null)
                    IconButton(
                      icon:
                          const Icon(Icons.skip_previous, color: Colors.white),
                      tooltip: 'Previous episode',
                      onPressed: onPrevious,
                    ),
                  // Skip/fast-seek only makes sense for VOD.
                  if (showSeek)
                    _SkipButton(
                      icon: Icons.replay_10,
                      onSeek: (amount) {
                        final target = position - amount;
                        controller.seekTo(
                            target < Duration.zero ? Duration.zero : target);
                      },
                    ),
                  IconButton(
                    icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white),
                    onPressed: () => value.isPlaying
                        ? controller.pause()
                        : controller.play(),
                  ),
                  if (showSeek)
                    _SkipButton(
                      icon: Icons.forward_10,
                      onSeek: (amount) {
                        final target = position + amount;
                        controller
                            .seekTo(target > duration ? duration : target);
                      },
                    ),
                  if (onNext != null)
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      tooltip: 'Next episode',
                      onPressed: onNext,
                    ),
                  _AudioTrackButton(controller: controller),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Replaces the elapsed/duration text for a live channel with something
/// actually meaningful: how long is left in whatever's currently airing,
/// from EPG data (`EpgProgram.stop`) — not the video controller's own
/// duration, which is exactly the number that turned out not to be
/// trustworthy for live streams (see [PlayerControls.isLive]). Sits
/// inside the same [ValueListenableBuilder] that already rebuilds on
/// every video position tick, so "N min left" counts down at the same
/// cadence for free, no separate timer needed; `context.watch<EpgService>`
/// additionally keeps it correct across a real EPG data refresh.
class _LiveRemainingLabel extends StatelessWidget {
  const _LiveRemainingLabel({required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final programme = epg.getCurrentProgram(channelId);
    if (programme == null) return const SizedBox.shrink();
    final remaining = programme.stop.difference(DateTime.now());
    if (remaining.isNegative) return const SizedBox.shrink();
    final minutes = remaining.inMinutes;
    return Text(
      minutes < 1 ? 'Ending now' : '$minutes min left',
      style: const TextStyle(color: Colors.white70, fontSize: 12),
    );
  }
}

/// Lets the user pick an audio track — some providers mislabel a stream's
/// language in its title (confirmed: a title that says "EN" but whose
/// actual audio track isn't English), and there's no way to tell or fix
/// that without a picker like this. `video_player_hdr`'s underlying
/// platform interface already exposes multi-track audio (it wraps
/// ExoPlayer on Android, which has always supported this internally) —
/// this is a UI on top of an existing capability, not new plumbing.
/// Hidden entirely for a stream with only one (or zero known) tracks —
/// showing a picker with a single, unchangeable option is just noise.
class _AudioTrackButton extends StatefulWidget {
  const _AudioTrackButton({required this.controller});

  final VideoPlayerHdrController controller;

  @override
  State<_AudioTrackButton> createState() => _AudioTrackButtonState();
}

class _AudioTrackButtonState extends State<_AudioTrackButton> {
  List<VideoAudioTrack>? _tracks;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    if (!widget.controller.isAudioTrackSupportAvailable()) return;
    try {
      final tracks = await widget.controller.getAudioTracks();
      if (mounted) setState(() => _tracks = tracks);
    } catch (_) {
      // Not every stream/platform combination actually has track info
      // available even when the capability check passes — leave the
      // button hidden (_tracks stays null) rather than show a picker
      // that can't do anything.
    }
  }

  String _trackLabel(VideoAudioTrack track) {
    final label = track.label;
    if (label != null && label.isNotEmpty) return label;
    final language = track.language;
    if (language != null && language.isNotEmpty && language != 'und')
      return language.toUpperCase();
    return 'Track ${track.id}';
  }

  Future<void> _openPicker() async {
    // Re-fetch right before showing rather than trusting the initState
    // snapshot — reflects the actual current selection (isSelected) even
    // if something else changed it since this button first loaded.
    List<VideoAudioTrack> tracks;
    try {
      tracks = await widget.controller.getAudioTracks();
    } catch (_) {
      return;
    }
    if (!mounted || tracks.length < 2) return;
    setState(() => _tracks = tracks);

    final chosen = await showModalBottomSheet<VideoAudioTrack>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Audio Track',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
            ),
            for (final track in tracks)
              ListTile(
                leading: Icon(
                  track.isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: track.isSelected ? Colors.amber : Colors.white54,
                ),
                title: Text(_trackLabel(track),
                    style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(sheetContext).pop(track),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      await widget.controller.selectAudioTrack(chosen.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _tracks;
    if (tracks == null || tracks.length < 2) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.multitrack_audio, color: Colors.white),
      tooltip: 'Audio track',
      onPressed: _openPicker,
    );
  }
}

/// A tap jumps 10 seconds; holding it down keeps seeking in that direction,
/// accelerating the longer it's held — same "hold to fast-forward" most
/// video players have. Handles both touch (hold gesture) and D-pad (a
/// held Select/Enter key) — Flutter has no built-in "key held for N ms"
/// primitive, so this tracks key down/up timing by hand, the same
/// technique used for the group-row long-press menu in TvHomeScreen.
class _SkipButton extends StatefulWidget {
  const _SkipButton({required this.icon, required this.onSeek});

  final IconData icon;

  /// Called once with a 10-second amount for a normal tap/click, or
  /// repeatedly with a growing amount for as long as it's held.
  final void Function(Duration amount) onSeek;

  @override
  State<_SkipButton> createState() => _SkipButtonState();
}

class _SkipButtonState extends State<_SkipButton> {
  Timer? _holdTimer;
  int _tick = 0;
  bool _heldPastTap = false;
  bool _focused = false;

  static const _tapAmount = Duration(seconds: 10);
  static const _holdInterval = Duration(milliseconds: 400);

  void _startHold() {
    _tick = 0;
    _heldPastTap = false;
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(_holdInterval, (_) {
      _heldPastTap = true;
      _tick++;
      // Accelerates the longer it's held: 10s, 10s, 10s, then 20s a tick,
      // then 30s a tick, and so on — not just a constant fast-seek speed.
      widget.onSeek(Duration(seconds: 10 * (1 + _tick ~/ 3)));
    });
  }

  void _endHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (!_heldPastTap) widget.onSeek(_tapAmount);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isActivateKey = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA;
    if (!isActivateKey) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _startHold();
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _endHold();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    final focusFill =
        isMinimal ? Colors.white.withValues(alpha: 0.16) : scheme.primary;
    return Focus(
      onKeyEvent: _handleKeyEvent,
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        onTapDown: (_) => _startHold(),
        onTapUp: (_) => _endHold(),
        onTapCancel: _endHold,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _focused ? focusFill : Colors.transparent,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 28),
        ),
      ),
    );
  }
}
