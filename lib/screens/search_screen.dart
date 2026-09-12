import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/channel_list_tile.dart';
import '../widgets/hold_to_activate.dart';
import 'player_screen.dart';
import 'series_detail_screen.dart';

/// Full-screen search — a proper input and result list instead of the
/// cramped app-bar field. Defaults to searching whichever tab (Live TV /
/// Movies / TV Shows) was active when it was opened, with pills to switch
/// scope to a different one — "search in a different one if needed, like a
/// second layer" rather than always dumping every content type together.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.initialScope});

  /// One of 'TV', 'Movies', 'TV Shows' — matches [HomeScreen]'s tab names.
  final String initialScope;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late String _scope;
  final _controller = TextEditingController();
  String _query = '';
  List<String> _recentSearches = [];

  static const _scopes = ['TV', 'Movies', 'TV Shows'];
  static const _scopeLabels = {'TV': 'Live TV', 'Movies': 'Movies', 'TV Shows': 'TV Shows'};

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope == 'Favorites' ? 'TV' : widget.initialScope;
    _recentSearches = context.read<StorageService>().getRecentSearches();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Records a completed search (explicit submit, or picking a result) for
  /// the quick-access list shown while the field is empty — not on every
  /// keystroke, which would just fill history with partial fragments.
  void _recordSearch(String query) {
    if (query.trim().isEmpty) return;
    context.read<StorageService>().addRecentSearch(query).then((_) {
      if (mounted) setState(() => _recentSearches = context.read<StorageService>().getRecentSearches());
    });
  }

  void _runSearch(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    setState(() => _query = query);
  }

  Future<void> _openChannel(Channel channel) async {
    _recordSearch(_query);
    // Awaited so PlayerScreen's own initState (which also calls play(),
    // guarded to no-op once this channel is already current) doesn't
    // race this call — see TvHomeScreen._selectChannel for the full
    // explanation of the bug this avoids.
    await context.read<PlaybackService>().play(channel);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
  }

  void _openSeries(XtreamSeries series) {
    _recordSearch(_query);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  void _toggleSeriesFavorite(BuildContext context, XtreamSeries series) {
    context.read<PlaylistManager>().toggleSeriesFavorite(series);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(series.isFavorite ? 'Added to Favorites' : 'Removed from Favorites'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final q = _query.trim().toLowerCase();

    return withTvThemeIfNeeded(context, (context) => Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search ${_scopeLabels[_scope]}...',
            border: InputBorder.none,
            hintStyle: TextStyle(color: Theme.of(context).appBarTheme.foregroundColor?.withValues(alpha: 0.6)),
          ),
          style: TextStyle(
            color: Theme.of(context).appBarTheme.foregroundColor,
            fontSize: 18,
          ),
          onChanged: (value) => setState(() => _query = value),
          onSubmitted: _recordSearch,
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _controller.clear();
                _query = '';
              }),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final scope in _scopes) ...[
                  ChoiceChip(
                    label: Text(_scopeLabels[scope]!),
                    selected: _scope == scope,
                    onSelected: (_) => setState(() => _scope = scope),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          if (playlist.isXtream && playlist.isWarmingCatalog && _scope != 'TV')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Still loading the full catalog in the background '
                      '(${playlist.warmCatalogDone}/${playlist.warmCatalogTotal} categories) — '
                      'some results may not show up yet.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _buildResults(context, playlist, q)),
        ],
      ),
    ));
  }

  Widget _buildResults(BuildContext context, PlaylistManager playlist, String q) {
    if (q.isEmpty) {
      if (_recentSearches.isEmpty) {
        return Center(child: Text('Search ${_scopeLabels[_scope]}'));
      }
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Recent searches', style: Theme.of(context).textTheme.labelLarge),
                ),
                TextButton(
                  onPressed: () {
                    context.read<StorageService>().clearRecentSearches();
                    setState(() => _recentSearches = []);
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          for (final term in _recentSearches)
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(term),
              onTap: () => _runSearch(term),
            ),
        ],
      );
    }

    if (_scope == 'TV') {
      final matches = playlist.channels.where((c) => c.name.toLowerCase().contains(q)).toList();
      if (matches.isEmpty) return const _NothingFound();
      return ListView.builder(
        itemCount: matches.length,
        itemBuilder: (context, i) => ChannelListTile(
          channel: matches[i],
          selected: false,
          onTap: () => _openChannel(matches[i]),
        ),
      );
    }

    if (_scope == 'Movies') {
      final source = playlist.isXtream ? playlist.allCachedVod : playlist.visibleChannels(category: 'vod');
      final matches = source.where((c) => c.name.toLowerCase().contains(q)).toList();
      if (matches.isEmpty) return const _NothingFound();
      return ListView.builder(
        itemCount: matches.length,
        itemBuilder: (context, i) => ChannelListTile(
          channel: matches[i],
          selected: false,
          showEpg: false,
          onTap: () => _openChannel(matches[i]),
        ),
      );
    }

    // TV Shows
    if (playlist.isXtream) {
      final matches = playlist.allCachedSeries.where((s) => s.name.toLowerCase().contains(q)).toList();
      if (matches.isEmpty) return const _NothingFound();
      return ListView.builder(
        itemCount: matches.length,
        itemBuilder: (context, i) {
          final s = matches[i];
          return HoldToActivate(
            onTap: () => _openSeries(s),
            onHold: () => _toggleSeriesFavorite(context, s),
            child: ListTile(
              leading: SizedBox(
                width: 48,
                height: 48,
                child: (s.coverUrl != null && s.coverUrl!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: s.coverUrl!,
                        fit: BoxFit.contain,
                        errorWidget: (_, __, ___) => const Icon(Icons.video_library),
                      )
                    : const Icon(Icons.video_library),
              ),
              title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: s.isFavorite
                  ? const Icon(Icons.star, color: Colors.amber)
                  : const Icon(Icons.chevron_right),
              onTap: () => _openSeries(s),
            ),
          );
        },
      );
    }

    final matches = playlist.visibleChannels(category: 'series').where((c) => c.name.toLowerCase().contains(q)).toList();
    if (matches.isEmpty) return const _NothingFound();
    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, i) => ChannelListTile(
        channel: matches[i],
        selected: false,
        showEpg: false,
        onTap: () => _openChannel(matches[i]),
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  const _NothingFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            const Text('Nothing found'),
          ],
        ),
      ),
    );
  }
}
