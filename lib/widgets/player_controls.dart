import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../services/playback_service.dart';
import 'epg_guide.dart';

/// Renders whatever [PlaybackService] is currently playing.
///
/// Purely presentational — it doesn't own a controller or start playback
/// itself; call `context.read<PlaybackService>().play(channel)` to start
/// something, and every mounted [VideoPlayerPane] (inline pane, fullscreen
/// screen, mini-player) reflects the same live video.
class VideoPlayerPane extends StatelessWidget {
  const VideoPlayerPane({super.key, this.showEpgBar = true, this.showControls = true});

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
              Text(_friendlyPlaybackError(playback.error!), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ExpansionTile(
                title: const Text('Technical details', style: TextStyle(fontSize: 12)),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      playback.error!,
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
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
            if (showEpgBar) EpgGuide(channelId: channel.id),
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
                      aspectRatio:
                          controller.value.aspectRatio == 0 ? 16 / 9 : controller.value.aspectRatio,
                      child: VideoPlayerHdr(controller),
                    ),
                  ),
                  if (showControls)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: PlayerControls(controller: controller, title: channel.name),
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
  if (lower.contains('mediacodecvideorenderer') || (lower.contains('hevc') && lower.contains('10bit'))) {
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
    this.isFavorite,
    this.onToggleFavorite,
  });

  final VideoPlayerHdrController controller;
  final String title;

  /// Null hides the favorite button entirely (the shared inline preview
  /// panes don't pass these) — [PlayerScreen] is the one caller that does,
  /// so pressing Down to reveal these controls also surfaces "add to
  /// favorites" for whatever's playing.
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;

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
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    '${_formatDuration(position)} / ${_formatDuration(duration)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
              // Excluded from D-pad focus always: a focused Slider consumes
              // Left/Right itself for seeking, ahead of any ancestor
              // Shortcuts/CallbackShortcuts trying to use those keys for
              // navigation (e.g. PlayerScreen's "Left always goes back").
              // Touch/mouse dragging is unaffected — this only removes it
              // from keyboard/remote focus traversal.
              ExcludeFocus(
                child: Slider(
                  value: duration.inMilliseconds == 0
                      ? 0
                      : position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble(),
                  max: duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds.toDouble(),
                  onChanged: duration.inMilliseconds == 0
                      ? null
                      : (v) => controller.seekTo(Duration(milliseconds: v.toInt())),
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
                      tooltip: isFavorite == true ? 'Remove from favorites' : 'Add to favorites',
                      onPressed: onToggleFavorite,
                    ),
                  // Skip/fast-seek only makes sense for VOD — a live
                  // stream's duration.inMilliseconds is 0, same signal
                  // already used above to disable the seek bar.
                  if (duration.inMilliseconds > 0)
                    _SkipButton(
                      icon: Icons.replay_10,
                      onSeek: (amount) {
                        final target = position - amount;
                        controller.seekTo(target < Duration.zero ? Duration.zero : target);
                      },
                    ),
                  IconButton(
                    icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                    onPressed: () => value.isPlaying ? controller.pause() : controller.play(),
                  ),
                  if (duration.inMilliseconds > 0)
                    _SkipButton(
                      icon: Icons.forward_10,
                      onSeek: (amount) {
                        final target = position + amount;
                        controller.seekTo(target > duration ? duration : target);
                      },
                    ),
                ],
              ),
            ],
          );
        },
      ),
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
            color: _focused ? scheme.primary : Colors.transparent,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 28),
        ),
      ),
    );
  }
}
