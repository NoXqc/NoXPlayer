import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../services/playback_service.dart';

/// Persistent bottom bar showing whatever [PlaybackService] is currently
/// playing, so browsing other groups on a phone (where there's no room for
/// a permanent inline video pane) doesn't stop playback — tapping it
/// re-opens the fullscreen view onto the same, still-running controller.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackService>();
    final channel = playback.currentChannel;
    final controller = playback.controller;

    if (channel == null || controller == null) return const SizedBox.shrink();

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: ValueListenableBuilder<VideoPlayerHdrValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              return Row(
                children: [
                  SizedBox(
                    width: 84,
                    height: 56,
                    child: value.isInitialized
                        ? ClipRect(
                            child: FittedBox(
                              fit: BoxFit.cover,
                              // FittedBox needs a child with a definite,
                              // non-zero "natural" size to compute its scale
                              // matrix from. Handing it VideoPlayer directly
                              // can report a zero size before the first
                              // frame decodes, which produces a divide-by-
                              // zero transform — wrapping it in AspectRatio
                              // (same pattern the main player uses) always
                              // gives FittedBox a well-defined size, video
                              // frame available or not.
                              child: AspectRatio(
                                aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
                                // See VideoPlayerPane's identical fix for
                                // why this is keyed — without it, a
                                // channel switch can leave the previous
                                // channel's last frame frozen here on
                                // hardware where an in-place platform-view
                                // rebind doesn't fully take.
                                child: VideoPlayerHdr(controller, key: ObjectKey(controller)),
                              ),
                            ),
                          )
                        : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () => value.isPlaying ? controller.pause() : controller.play(),
                  ),
                  IconButton(icon: const Icon(Icons.fullscreen), onPressed: onTap),
                  const SizedBox(width: 4),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
