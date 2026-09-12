import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/tv_theme.dart';
import 'player_screen.dart';

/// A stop between "tap a movie" and "it starts playing" — a poster, rating,
/// plot, and an explicit Play/Resume choice, rather than autoplaying the
/// instant something is tapped. The plot is a separate on-demand call
/// ([PlaylistManager.getVodDescription]) — Xtream's list endpoint used for
/// the whole category doesn't carry it, and fetching it for every movie in
/// a 150k-title catalog just to populate a browse grid isn't worth the
/// request; this only fetches it for the one title actually opened here.
class MovieDetailScreen extends StatefulWidget {
  const MovieDetailScreen({super.key, required this.channel});

  final Channel channel;

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  late Future<String?> _descriptionFuture;

  @override
  void initState() {
    super.initState();
    final rawId = widget.channel.id.replaceFirst('xt_vod_', '');
    _descriptionFuture = context.read<PlaylistManager>().getVodDescription(rawId);
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final storage = context.read<StorageService>();
    final resumeMs = storage.getLastPosition(channel.id);
    final watchedFraction = storage.getWatchedFraction(channel.id);
    final playlist = context.watch<PlaylistManager>();
    // Re-read the live copy so the favorite star reflects toggles made here.
    final current = playlist.allCachedVod.firstWhere(
      (c) => c.id == channel.id,
      orElse: () => channel,
    );

    Future<void> play({bool resume = true}) async {
      if (!resume) storage.setLastPosition(channel.id, 0);
      // Awaited so PlayerScreen's own initState (which also calls
      // play(), guarded to no-op once this channel is already current)
      // doesn't race this call — see TvHomeScreen._selectChannel for the
      // full explanation of the bug this avoids.
      await context.read<PlaybackService>().play(channel);
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
    }

    return withTvThemeIfNeeded(context, (context) => Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
            CachedNetworkImage(
              imageUrl: channel.logoUrl!,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(color: Colors.grey.shade900),
            )
          else
            Container(color: Colors.grey.shade900),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.2), Colors.black.withValues(alpha: 0.95)],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    channel.name,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (channel.rating != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '★ ${channel.rating}',
                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  FutureBuilder<String?>(
                    future: _descriptionFuture,
                    builder: (context, snapshot) {
                      final plot = snapshot.data;
                      if (plot == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          plot,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      );
                    },
                  ),
                  if (watchedFraction != null && !storage.isFullyWatched(channel.id))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: watchedFraction,
                                minHeight: 5,
                                backgroundColor: Colors.white24,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(watchedFraction * 100).round()}% watched',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (resumeMs > 0)
                        FilledButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Resume'),
                          onPressed: () => play(resume: true),
                        )
                      else
                        FilledButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                          onPressed: () => play(resume: true),
                        ),
                      const SizedBox(width: 12),
                      if (resumeMs > 0)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.replay),
                          label: const Text('Restart'),
                          onPressed: () => play(resume: false),
                        ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: Icon(
                          current.isFavorite ? Icons.star : Icons.star_border,
                          color: current.isFavorite ? Colors.amber : Colors.white,
                        ),
                        onPressed: () => context.read<PlaylistManager>().toggleFavorite(current),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ));
  }
}
