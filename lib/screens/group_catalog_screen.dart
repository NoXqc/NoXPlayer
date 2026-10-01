import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/poster_card.dart';
import '../widgets/settings_scaffold.dart';
import 'movie_detail_screen.dart';
import 'series_detail_screen.dart';

/// A single movies/TV-shows group expanded into its own full poster grid —
/// "Expand catalog" on a group's hold-Select menu (see
/// `TvHomeScreen._showGroupOptions`). Previously the only way to see a
/// group laid out this way (rather than one horizontal row in the normal
/// browse view) was to favorite it and go find it under the Favorites tab
/// — reported directly as a roundabout way to do something that should
/// just be available on any group directly. A real pushed route rather
/// than new state folded into `TvHomeScreen` — the physical Back button
/// popping back to the normal browse view is then just how `Navigator`
/// already behaves, no new link needed in that screen's own, already
/// intricate content → groups → tabs back-handling chain.
class GroupCatalogScreen extends StatelessWidget {
  const GroupCatalogScreen({
    super.key,
    required this.category,
    required this.playlistId,
    required this.title,
  });

  /// 'vod' or 'series'.
  final String category;
  final String playlistId;
  final String title;

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
        context,
        (context) => Stack(
              children: [
                const Positioned.fill(child: SettingsGradientBackground()),
                Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    title:
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  body: category == 'vod'
                      ? _buildVodGrid(context)
                      : _buildSeriesGrid(context),
                ),
              ],
            ));
  }

  Widget _buildVodGrid(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final storage = context.read<StorageService>();
    final group = playlist.vodGroups.firstWhere(
      (g) => g.title == title && g.playlistId == playlistId,
      orElse: () =>
          M3uGroup(title: title, playlistId: playlistId, channels: const []),
    );
    return _posterGrid(
      group.channels,
      (c) => PosterCard(
        title: c.name,
        imageUrl: c.logoUrl,
        rating: c.rating,
        watched: storage.isFullyWatched(c.id),
        progressFraction: storage.getWatchedFraction(c.id),
        isFavorite: c.isFavorite,
        onToggleFavorite: () => _toggleFavoriteWithFeedback(context, playlist, c),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => MovieDetailScreen(channel: c))),
        onFocusGained: () {},
      ),
    );
  }

  Widget _buildSeriesGrid(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final series = playlist.visibleSeries(
        playlistId: playlistId, categoryName: title);
    return _posterGrid(
      series,
      (s) => PosterCard(
        title: s.name,
        imageUrl: s.coverUrl,
        rating: s.rating,
        isFavorite: s.isFavorite,
        onToggleFavorite: () => playlist.toggleSeriesFavorite(s),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: s))),
        onFocusGained: () {},
      ),
    );
  }

  void _toggleFavoriteWithFeedback(
      BuildContext context, PlaylistManager playlist, Channel channel) {
    playlist.toggleFavorite(channel);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          channel.isFavorite ? 'Added to Favorites' : 'Removed from Favorites'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Same shape as `TvHomeScreen._posterGrid` — a plain rectangular grid
  /// (not a row-per-category layout), which default D-pad traversal
  /// handles reliably on its own; the unbounded-search failure mode this
  /// app has repeatedly hit elsewhere is specifically about *many rows of
  /// differing length*, not a single regular grid like this one.
  Widget _posterGrid<T>(List<T> items, Widget Function(T) posterBuilder) {
    if (items.isEmpty) {
      return const Center(child: Text('No items in this group.'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: PosterCard.width + 12,
        mainAxisExtent: PosterCard.height + 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => posterBuilder(items[i]),
    );
  }
}
