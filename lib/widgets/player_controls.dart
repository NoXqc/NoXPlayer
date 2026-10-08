import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../utils/video_quality.dart';
import 'epg_guide.dart';

/// Renders whatever [PlaybackService] is currently playing.
///
/// Purely presentational — it doesn't own a controller or start playback
/// itself; call `context.read<PlaybackService>().play(channel)` to start
/// something, and every mounted [VideoPlayerPane] (inline pane, fullscreen
/// screen, mini-player) reflects the same live video.
class VideoPlayerPane extends StatelessWidget {
  const VideoPlayerPane(
      {super.key,
      this.showEpgBar = true,
      this.showControls = true,
      this.switchButtonFocusNode});

  final bool showEpgBar;

  /// [PlayerScreen] renders its own auto-hiding controls overlay (so the
  /// seek bar can't permanently steal D-pad focus) and just wants the bare
  /// video here — pass false there.
  final bool showControls;

  /// [PlayerScreen] needs to know when this button has focus (and be able
  /// to move focus onto/off of it itself) so its own D-pad handling can
  /// treat it as a third explicit zone alongside its top/bottom bars,
  /// rather than leaving it to Flutter's directional focus search — that
  /// search isn't bounded to "the bar you're currently in" the way you'd
  /// expect, and was confirmed to jump straight from the bottom bar to the
  /// top bar, skipping this button entirely, once it existed as a third
  /// focusable thing geometrically between two very differently-shaped
  /// full-width bars. Null (this pane's small inline preview instances,
  /// tv_home_screen.dart/home_screen.dart) just falls back to an internal,
  /// non-autofocusing node — those have no such handling and shouldn't
  /// steal focus for an errored preview tile anyway.
  final FocusNode? switchButtonFocusNode;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackService>();
    final channel = playback.currentChannel;
    final controller = playback.controller;

    if (channel == null || controller == null) {
      return const Center(child: Text('Select a channel to start watching'));
    }

    if (playback.error != null) {
      // Reached only once this playlist's own connection attempt *and*
      // its backup servers (see PlaylistProfile.backupServers) have both
      // already failed — a manually-linked channel on another playlist
      // (see PlayerControls.linkedChannel's doc comment) is offered here
      // front-and-center, since at this point this playlist genuinely has
      // nothing left to try on its own.
      final channelLink =
          context.watch<PlaylistManager>().channelLinkFor(channel);
      final linkedChannel = channelLink == null
          ? null
          : context.read<PlaylistManager>().resolveChannelLink(channelLink);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_friendlyPlaybackError(playback.error!),
                  textAlign: TextAlign.center),
              if (linkedChannel != null) ...[
                const SizedBox(height: 16),
                _SwitchToLinkedChannelButton(
                  focusNode: switchButtonFocusNode,
                  label:
                      'Switch to ${context.read<PlaylistManager>().playlistNameFor(linkedChannel.playlistId)}: ${linkedChannel.name}',
                  onPressed: () =>
                      context.read<PlaybackService>().play(linkedChannel),
                ),
              ],
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
            if (showEpgBar) EpgGuide(channelId: channel.epgId),
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
                  // A reconnect (either a manual Reload or an automatic
                  // backup-server retry) used to replace this whole pane
                  // with a plain `Center` — the frozen last frame has no
                  // reason to disappear while a fresh connection comes up
                  // behind it, and a full black takeover read as a crash,
                  // not a recovery in progress (reported directly: "looks
                  // less like Windows restart"). A small floating card is
                  // the same translucent-scrim look the Recall picker
                  // already uses, just centered over the video instead of
                  // anchored to the controls bar.
                  if (playback.reconnectStatus != null)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 22),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                                width: 28,
                                height: 28,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(height: 16),
                            Text(playback.reconnectStatus!,
                                textAlign: TextAlign.center),
                          ],
                        ),
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
                        channelId: channel.epgId,
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

/// Takes an externally-owned [FocusNode] when the caller needs to drive/
/// observe this button's focus itself (see
/// [VideoPlayerPane.switchButtonFocusNode]'s doc comment — [PlayerScreen]
/// is the only such caller) and requests focus for it once this widget is
/// actually built. A plain `autofocus: true` isn't reliable here: whoever
/// hosts this pane typically claims focus for its own key handling well
/// before a stream error (and this button) can exist, so an ambient
/// autofocus flag has nothing to preempt at that point. Falls back to an
/// owned, non-autofocusing node when none is supplied, for this pane's
/// small inline preview instances that have no need for any of this.
class _SwitchToLinkedChannelButton extends StatefulWidget {
  const _SwitchToLinkedChannelButton(
      {required this.label, required this.onPressed, this.focusNode});

  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  State<_SwitchToLinkedChannelButton> createState() =>
      _SwitchToLinkedChannelButtonState();
}

class _SwitchToLinkedChannelButtonState
    extends State<_SwitchToLinkedChannelButton> {
  FocusNode? _ownedFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'switch-to-linked-channel'));

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => widget.focusNode!.requestFocus());
    }
  }

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      focusNode: _focusNode,
      icon: const Icon(Icons.swap_horiz),
      label: Text(widget.label),
      onPressed: widget.onPressed,
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
  if (isDecoderPlaybackError(raw)) {
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
    this.onActivity,
    this.linkedChannel,
    this.channel,
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

  /// Called on every skip-button seek tick (a tap, or each tick of a
  /// held fast-seek) — reported directly: this bar's own auto-hide timer
  /// keeps counting down completely untouched by an in-progress fast-
  /// seek, since nothing about pressing Select on the skip button was
  /// ever wired to reset it. A hold long enough to be worth doing at all
  /// (several seconds, easily past the 6s auto-hide) could have the bar
  /// disappear mid-seek, leaving the user to bring it back and start
  /// over. [PlayerScreen] wires this to the same reset its own Up/Down
  /// handling already calls.
  final VoidCallback? onActivity;

  /// Null hides the button entirely — see [Channel.epgIdOverride]'s
  /// sibling concept, `PlaylistManager.channelLinkFor`: a manually-linked
  /// equivalent channel on another playlist, always offered here
  /// (whether or not anything's currently wrong) as a one-press manual
  /// failover, requested directly for exactly the case a shared/rebranded
  /// provider outage takes one playlist down but not another. Deliberately
  /// not automatic — see [VideoPlayerPane]'s own error-state version of
  /// this same button for why the app can't yet tell a genuine outage
  /// apart from an ordinary rebuffer on its own.
  final Channel? linkedChannel;

  /// The live channel actually playing — only used to exclude it from its
  /// own Recall history below. Null hides that button entirely, same
  /// convention as [onToggleFavorite]/[linkedChannel] — the shared inline
  /// preview panes don't pass it.
  final Channel? channel;

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
                  _QualityBadge(controller: controller),
                  const SizedBox(width: 8),
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
                  // Recall goes furthest left, ahead of even favorites/
                  // pause — placed there deliberately, per direct
                  // feedback: recall means *backward*, so left is where
                  // it reads correctly, mirroring how rewind conventionally
                  // sits left of a play head.
                  if (isLive && channel != null)
                    IconButton(
                      icon: const Icon(Icons.history, color: Colors.white),
                      tooltip: 'Recall — go back to a recent channel',
                      onPressed: () {
                        onActivity?.call();
                        showRecallPicker(context, channel!);
                      },
                    ),
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
                  // Manual recovery for a channel that's silently stalled
                  // (frozen frame, no spinner, no error) — see
                  // PlaybackService.reloadCurrentChannel's doc comment for
                  // why this is a manual button rather than an automatic
                  // watchdog. Live only, same gating as Recall above.
                  if (isLive && channel != null)
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      tooltip: 'Reload channel',
                      onPressed: () {
                        onActivity?.call();
                        context.read<PlaybackService>().reloadCurrentChannel();
                      },
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
                        onActivity?.call();
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
                        onActivity?.call();
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
                  if (linkedChannel != null)
                    _LinkedChannelButton(linkedChannel: linkedChannel!),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Opens the Recall picker — a bottom sheet listing the last few *live*
/// channels actually watched before this one (not a program guide, not
/// catchup/timeshift — a plain "go back to what I was just watching"
/// shortcut, the same concept as a cable remote's dedicated Recall/Last
/// button). Built entirely from [PlaybackService.recentlyPlayed], which
/// every [PlaybackService.play] call already records — no new tracking
/// needed. Filtered to live entries only ([Channel.isLiveId]) and deduped
/// by id, since the same underlying list also carries VOD/episode history
/// for the "Continue Watching" row.
Future<void> showRecallPicker(BuildContext context, Channel current) async {
  final playback = context.read<PlaybackService>();
  final seen = <String>{current.id};
  final history = <Channel>[];
  for (final c in playback.recentlyPlayed) {
    if (!Channel.isLiveId(c.rawId)) continue;
    if (!seen.add(c.id)) continue;
    history.add(c);
    if (history.length >= 4) break;
  }

  await showModalBottomSheet<void>(
    context: context,
    // Transparent sheet chrome + transparent barrier — the actual visible
    // panel is the translucent scrim inside _RecallPickerSheet, matching
    // the Live TV channel list's own floating-over-the-video look
    // (Colors.black.withValues(alpha: 0.62), see tv_home_screen.dart)
    // rather than the default opaque modal sheet dimming everything
    // behind it.
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    builder: (sheetContext) => _RecallPickerSheet(channels: history),
  );
}

class _RecallPickerSheet extends StatelessWidget {
  const _RecallPickerSheet({required this.channels});

  final List<Channel> channels;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Recall — recently watched',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
              ),
            ),
            if (channels.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No other live channels watched yet this session.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              )
            else
              ...channels.map((c) => ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading:
                        const Icon(Icons.tv, color: Colors.white54, size: 20),
                    title: Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14)),
                    onTap: () {
                      Navigator.of(context).pop();
                      context.read<PlaybackService>().play(c);
                    },
                  )),
          ],
        ),
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

/// Real decoded resolution/frame-rate tier, not the channel's (often
/// aspirational) name — see `video_quality.dart`'s own doc comment for
/// why this reads the actual selected video track instead. Polls rather
/// than reacting to an event: `video_player_hdr` doesn't publicly expose
/// its internal video-track-changed event stream, and polling every few
/// seconds is more than enough for a cosmetic badge — adaptive-bitrate
/// switches aren't frequent enough to need anything faster. Hidden
/// entirely below 1080p or whenever track info isn't available at all,
/// same "don't show something that can't be trusted" reasoning as
/// [_AudioTrackButton] hiding for a single-track stream.
class _QualityBadge extends StatefulWidget {
  const _QualityBadge({required this.controller});

  final VideoPlayerHdrController controller;

  @override
  State<_QualityBadge> createState() => _QualityBadgeState();
}

class _QualityBadgeState extends State<_QualityBadge> {
  String? _label;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void didUpdateWidget(_QualityBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _label = null;
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!widget.controller.isVideoTrackSupportAvailable()) return;
    try {
      final tracks = await widget.controller.getVideoTracks();
      VideoTrack? selected;
      for (final track in tracks) {
        if (track.isSelected) {
          selected = track;
          break;
        }
      }
      final height = selected?.height;
      if (!mounted || height == null) return;
      final label =
          qualityLabelForTrack(height: height, frameRate: selected?.frameRate);
      if (label != _label) setState(() => _label = label);
    } catch (_) {
      // Not every stream/platform combination reports track info — leave
      // the badge hidden rather than show something stale/wrong.
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    if (label == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Same blended duo-tone glow as poster_card.dart's own focus glow —
    // one shadow, not two, for the same compositing-cost reason
    // documented there.
    final glowColor = Color.lerp(scheme.primary, scheme.secondary, 0.5)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: glowColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: glowColor.withValues(alpha: 0.6),
            blurRadius: 10,
            spreadRadius: 0.5,
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
            color: glowColor,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5),
      ),
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

/// Manual one-press failover to a linked channel on another playlist —
/// see [PlayerControls.linkedChannel]'s doc comment. Always shown (not
/// conditional on anything actually being wrong right now), same
/// "there whether you need it or not" shape as the skip/next-episode
/// buttons either side of it.
///
/// The bare swap icon means nothing on its own — there's no established
/// icon convention for "cross-playlist failover" the way there is for
/// play/pause or skip, and unlike those, this button is entirely absent
/// for every channel that isn't paired, so it's easy to land on days
/// after setting one up with no memory of what it does. [IconButton]'s
/// own `tooltip` doesn't help on a D-pad remote — there's no hover, no
/// long-press-for-tooltip gesture, so that text was never actually
/// reaching anyone driving by remote, only screen readers. This shows
/// the same text as a real on-screen label instead, but only while the
/// button is actually focused, the same "explain it right where the
/// selector lands" shape requested directly for this exact button.
class _LinkedChannelButton extends StatefulWidget {
  const _LinkedChannelButton({required this.linkedChannel});

  final Channel linkedChannel;

  @override
  State<_LinkedChannelButton> createState() => _LinkedChannelButtonState();
}

class _LinkedChannelButtonState extends State<_LinkedChannelButton> {
  // IconButton has no onFocusChange of its own to hook — an explicit
  // FocusNode passed to it, listened to directly, is the reliable way to
  // track its real D-pad focus state regardless of that (a second, outer
  // Focus wrapper risks not being the node the D-pad actually lands on,
  // since IconButton manages its own internally when none is given).
  final FocusNode _focusNode = FocusNode(debugLabel: 'linked-channel-swap');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() => _focused = _focusNode.hasFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlistName = context
        .watch<PlaylistManager>()
        .playlistNameFor(widget.linkedChannel.playlistId);
    final label = 'Switch to $playlistName: ${widget.linkedChannel.name}';
    // Stack, not the Column this started as — reported directly on real
    // hardware: a Column made the label a real sibling of the icon, so
    // the whole row of controls grew taller and visibly shifted every
    // time it appeared. Clip.none plus Positioned here means only the
    // IconButton itself (the sole non-positioned child) sizes this
    // Stack — the label floats up over the video above the toolbar
    // without the toolbar's own layout ever knowing it's there.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        IconButton(
          focusNode: _focusNode,
          icon: const Icon(Icons.swap_horiz, color: Colors.white),
          tooltip: label,
          onPressed: () =>
              context.read<PlaybackService>().play(widget.linkedChannel),
        ),
        // A negative `bottom` (not just stacked above via normal flow)
        // is what actually lets this float free of the button's own
        // footprint — paired with the Stack's own Clip.none above, so it
        // renders over the video rather than being clipped at the
        // button's edge. Deliberately quieter than the request's first
        // pass at this (no border, lower opacity, smaller text) — a
        // "ghost" hint reads as unfocused decoration, not another solid
        // control competing with the real button underneath it.
        if (_focused)
          Positioned(
            bottom: 44,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                constraints: const BoxConstraints(maxWidth: 220),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
      ],
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

  // Reported directly, and confirmed by exactly how it was reproduced —
  // "even if you'd stop hold, hit stop or hit -10, it would never stop
  // the ticks": pressing *any other button* moves D-pad focus away from
  // this one, so the KeyUpEvent this relied on to call _endHold() lands
  // on whatever's focused now instead — never here. Nothing ever told
  // this widget's own Timer.periodic to stop, so it kept firing forever,
  // independent of anything the user did afterward. `_holdTimer` isn't
  // tied to the widget's own lifecycle either — it survives a rebuild,
  // and only Flutter calling dispose() (this widget actually being torn
  // down) would stop it on its own.
  //
  // Two backstops, not just one, since the trigger for the stuck state
  // wasn't really "no way to detect key-up" (that part already worked
  // for a clean single press) — it was "no *other* signal ever stops an
  // in-progress hold once focus moves." onFocusChange below closes the
  // actual gap (losing focus always means losing control over whether
  // this is still being held, regardless of why); _maxHoldTicks is a
  // hard ceiling regardless of cause, so a hold can never run away
  // indefinitely even if some other, not-yet-seen path has the same gap.
  static const _maxHoldTicks = 50; // 50 * 400ms = 20s of continuous hold

  void _startHold() {
    _tick = 0;
    _heldPastTap = false;
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(_holdInterval, (timer) {
      _heldPastTap = true;
      _tick++;
      if (_tick >= _maxHoldTicks) {
        timer.cancel();
        _holdTimer = null;
      }
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

  /// Same cleanup as [_endHold], minus the tap-fallback seek — losing
  /// focus mid-hold isn't a clean release to treat as "was actually just
  /// a tap," it's an interruption; the only thing that matters here is
  /// making sure nothing keeps running.
  void _stopHoldOnFocusLoss() {
    _holdTimer?.cancel();
    _holdTimer = null;
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
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (!f) _stopHoldOnFocusLoss();
      },
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
