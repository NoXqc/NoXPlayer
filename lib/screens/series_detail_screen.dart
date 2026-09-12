import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/poster_card.dart';
import '../widgets/section_label.dart';
import 'player_screen.dart';

/// Shows a series' seasons as stacked horizontally-scrolling rows of
/// episode cards — the same catalog pattern as the Movies/TV Shows browse
/// screens ([PosterCard]/its row-of-cards usage in `TvHomeScreen`), reused
/// here rather than the old plain tabs-of-`ListTile`s layout. Episodes are
/// fetched on demand. Xtream mode only; the series container itself isn't
/// playable.
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({super.key, required this.series});

  final XtreamSeries series;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  late Future<({Map<int, List<Channel>> episodes, String? plot})> _episodesFuture;

  /// First episode card of each season row — without an explicit target,
  /// the screen's default initial focus (and default directional focus
  /// landing on a freshly-built row) could settle on whichever card
  /// happened to be nearest some stale reference rect, which read as the
  /// selector opening "a few clicks to the right" of episode 1 instead of
  /// on it. Same fix as `TvHomeScreen`'s `_firstPosterFocusNodeForGroup`.
  final Map<int, FocusNode> _seasonFirstFocusNodes = {};

  FocusNode _firstFocusNodeForSeason(int season) =>
      _seasonFirstFocusNodes.putIfAbsent(season, () => FocusNode(debugLabel: 'season-$season-first'));

  @override
  void initState() {
    super.initState();
    _episodesFuture = context.read<PlaylistManager>().loadSeriesEpisodes(widget.series).then((result) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final seasons = result.episodes.keys.toList()..sort();
        if (seasons.isNotEmpty && (result.episodes[seasons.first]?.isNotEmpty ?? false)) {
          _firstFocusNodeForSeason(seasons.first).requestFocus();
        }
      });
      return result;
    });
  }

  @override
  void dispose() {
    for (final node in _seasonFirstFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// [queue] is every episode across all seasons, in order — lets playback
  /// auto-advance into the next episode near the end (see
  /// `PlaybackService._nextInQueue`), including across a season boundary.
  void _openEpisode(Channel episode, List<Channel> queue) {
    context.read<PlaybackService>().setUpNextQueue(queue);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(channel: episode)));
  }

  @override
  Widget build(BuildContext context) {
    final storage = context.read<StorageService>();

    return withTvThemeIfNeeded(context, (context) => Scaffold(
      appBar: AppBar(
        title: Text(widget.series.name),
        // A plain default back button left the D-pad's Select key-up
        // landing on whatever tile now sits under the popped route (e.g.
        // the search result that opened this screen) — reported as that
        // tile's onTap firing again right after Back, reopening this same
        // screen. Unfocusing before the pop actually happens means there's
        // nothing "armed" underneath for a stray key event to land on.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: FutureBuilder<({Map<int, List<Channel>> episodes, String? plot})>(
        future: _episodesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('Failed to load episodes.'));
          }

          final episodesBySeason = snapshot.data?.episodes ?? {};
          final plot = snapshot.data?.plot;
          final seasons = episodesBySeason.keys.toList()..sort();

          if (seasons.isEmpty) {
            return const Center(child: Text('No episodes found.'));
          }

          final allEpisodesInOrder = [
            for (final s in seasons) ...episodesBySeason[s]!,
          ];

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: seasons.length + (plot != null ? 1 : 0),
            itemBuilder: (context, i) {
              if (plot != null) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                    child: Text(plot, style: Theme.of(context).textTheme.bodyMedium),
                  );
                }
                i -= 1;
              }
              final season = seasons[i];
              final episodes = episodesBySeason[season]!;
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: SectionLabel('Season $season'),
                    ),
                    SizedBox(
                      // Was a stale 210 left over from before PosterCard
                      // shrank to 168 — the extra slack didn't clip
                      // anything (Row cross-axis just left it blank), but
                      // padded every season row with dead space for no
                      // reason.
                      height: PosterCard.height,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        itemCount: episodes.length,
                        itemBuilder: (context, j) {
                          final episode = episodes[j];
                          return PosterCard(
                            title: episode.name,
                            // Falls back to the series' own cover art when
                            // a provider doesn't supply a per-episode
                            // still (see XtreamApiService.getSeriesEpisodes)
                            // — never a blank card.
                            imageUrl: (episode.logoUrl != null && episode.logoUrl!.isNotEmpty)
                                ? episode.logoUrl
                                : widget.series.coverUrl,
                            watched: storage.isFullyWatched(episode.id),
                            progressFraction: storage.getWatchedFraction(episode.id),
                            alwaysShowTitle: true,
                            focusNode: j == 0 ? _firstFocusNodeForSeason(season) : null,
                            onTap: () => _openEpisode(episode, allEpisodesInOrder),
                            onFocusGained: () {},
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    ));
  }
}
