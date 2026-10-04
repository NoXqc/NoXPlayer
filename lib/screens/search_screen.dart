import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/catalog_database.dart';
import '../services/desktop_mini_player.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/poster_card.dart';
import '../widgets/settings_scaffold.dart';
import 'desktop_player_screen.dart';
import 'player_screen.dart';
import 'series_detail_screen.dart';

/// Full-screen search — a search bar plus every matching result grouped
/// into its own horizontally-scrolling poster row (Live TV, Movies, TV
/// Shows — in that order, each shown only when it actually has matches),
/// instead of the old single flat list gated behind a scope switch. Every
/// content type is visible at once now, the same way a modern TV app's
/// search results page reads.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.initialScope});

  /// Kept for call-site compatibility (callers still pass the tab the user
  /// was on) but no longer used to gate results — every type now shows
  /// together regardless of where search was opened from.
  final String initialScope;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// One row's worth of built poster cards plus its first card's focus node
/// — the latter is what [_SearchScreenState._moveRowFocus] jumps to
/// explicitly, the same "never rely on default directional search across
/// an arbitrary number of posters" principle `tv_home_screen.dart`'s own
/// browse rows already established (see that file's `_browseRowKeys` doc
/// comment) — this screen builds the same shape of problem (an unknown,
/// potentially large number of focusable tiles across several rows) and
/// gets the same fix.
class _ResultRow {
  _ResultRow(this.label, this.rowKey, this.firstFocusNode, this.children);
  final String label;
  /// Wraps this row's header + horizontal list — see
  /// [_SearchScreenState._ensureRowVisible]'s doc comment for why this
  /// needs to be the whole row, not just whichever card is focused. Built
  /// before the row's children (not inside this constructor) since the
  /// children's own `onFocusGained` closures need to reference it too.
  final GlobalKey rowKey;
  final FocusNode firstFocusNode;
  final List<Widget> children;
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _searchFieldFocus = FocusNode();
  String _query = '';
  List<String> _recentSearches = [];

  /// Xtream Movies/TV Shows results, queried from [CatalogDatabase]
  /// directly rather than `PlaylistManager.allCachedVod`/`allCachedSeries`
  /// — those only ever reflect whatever's paged into memory this session,
  /// capped at 300 items per category even then, so a title anywhere past
  /// that cap in a large category was invisible to search even though it
  /// was fully synced to disk. Null means "no query run yet for the
  /// current text" (shows a brief loading spinner), distinct from an
  /// empty list (a real "nothing found").
  List<Channel>? _dbVodResults;
  List<XtreamSeries>? _dbSeriesResults;
  Timer? _searchDebounce;

  /// -1 means the search field/suggestion pills, otherwise an index into
  /// whichever `_ResultRow` list [build] most recently produced — see
  /// [_moveRowFocus].
  int _focusedZone = -1;

  @override
  void initState() {
    super.initState();
    _recentSearches = context.read<StorageService>().getRecentSearches();
    // Needed for a live-channel search to find anything at all — see
    // PlaylistManager.ensureLiveChannelsLoaded's doc comment.
    unawaited(context.read<PlaylistManager>().ensureLiveChannelsLoaded());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    _searchFieldFocus.dispose();
    super.dispose();
  }

  /// Debounced so a real database query (SQL `LIKE` scan over a
  /// potentially 100k+ row table) doesn't fire on every single keystroke
  /// — only once typing actually pauses. Selecting a recent search
  /// ([_runSearch]) is a deliberate one-shot action instead, so that path
  /// searches immediately with no debounce.
  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _searchDebounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty || !context.read<PlaylistManager>().isXtream) {
      setState(() {
        _dbVodResults = null;
        _dbSeriesResults = null;
      });
      return;
    }
    _searchDebounce =
        Timer(const Duration(milliseconds: 250), () => _runDbSearch(trimmed));
  }

  Future<void> _runDbSearch(String query) async {
    final playlist = context.read<PlaylistManager>();
    // Restricted to enabled playlists — a disabled playlist's stale
    // cached rows shouldn't surface in search results.
    final playlistIds = playlist.profiles
        .where((p) => p.enabled && p.isXtream)
        .map((p) => p.id)
        .toList();
    // Goes through PlaylistManager, not CatalogDatabase directly — see
    // PlaylistManager.searchVisibleVod's doc comment for why a direct DB
    // search has no hidden-group awareness at all.
    final vod = await playlist.searchVisibleVod(query, playlistIds);
    final series = await playlist.searchVisibleSeries(query, playlistIds);
    // The query field may have moved on to something else (or been
    // cleared) by the time this actually returns — a stale result
    // overwriting a newer/empty one would flash wrong results on screen.
    if (!mounted || _query.trim() != query) return;
    setState(() {
      _dbVodResults = vod;
      _dbSeriesResults = series;
    });
  }

  /// Records a completed search (explicit submit, or picking a result) for
  /// the quick-access pills shown while the field is empty — not on every
  /// keystroke, which would just fill history with partial fragments.
  void _recordSearch(String query) {
    if (query.trim().isEmpty) return;
    context.read<StorageService>().addRecentSearch(query).then((_) {
      if (mounted)
        setState(() => _recentSearches =
            context.read<StorageService>().getRecentSearches());
    });
  }

  void _runSearch(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    setState(() => _query = query);
    _searchDebounce?.cancel();
    if (context.read<PlaylistManager>().isXtream) {
      unawaited(_runDbSearch(query.trim()));
    }
  }

  Future<void> _openChannel(Channel channel) async {
    _recordSearch(_query);
    // See TvHomeScreen._selectChannel's matching comment — Windows has no
    // PlaybackService-compatible player at all (video_player_hdr has no
    // Windows implementation), so PlayerScreen below fails outright there.
    // Every other entry point (TvHomeScreen, movie/series detail) already
    // branches here; this one was missed, reported directly as "picking a
    // channel from search gives a playback error" on Windows specifically.
    if (Platform.isWindows) {
      DesktopMiniPlayer.instance.clear();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DesktopPlayerScreen(channel: channel)));
      return;
    }
    // Awaited so PlayerScreen's own initState (which also calls play(),
    // guarded to no-op once this channel is already current) doesn't
    // race this call — see TvHomeScreen._selectChannel for the full
    // explanation of the bug this avoids.
    await context.read<PlaybackService>().play(channel);
    if (!mounted) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
  }

  void _openSeries(XtreamSeries series) {
    _recordSearch(_query);
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  void _toggleSeriesFavorite(XtreamSeries series) {
    context.read<PlaylistManager>().toggleSeriesFavorite(series);
  }

  /// Explicit Up/Down between the search field and each result row — see
  /// [_ResultRow]'s doc comment for why this can't be left to default
  /// traversal. `-1` (the search field) is one end of the range, the last
  /// built row is the other; a plain `setState`-free field assignment
  /// (`_focusedZone`) tracks whichever currently has focus, updated by
  /// every row's first poster *and* the search field's own focus change.
  void _moveRowFocus(int delta, List<_ResultRow> rows) {
    final target = _focusedZone + delta;
    if (target < -1 || target >= rows.length) return;
    // Set directly rather than relying on a focus-change callback to do
    // it as a side effect — `TextField` only exposes `onTap`, which never
    // fires for a `requestFocus()` triggered programmatically from here,
    // so without this the search field's zone would never actually
    // update and the very next Down press would skip row 0 entirely.
    _focusedZone = target;
    if (target == -1) {
      _searchFieldFocus.requestFocus();
    } else {
      rows[target].firstFocusNode.requestFocus();
    }
  }

  /// Keeps a whole row's header visible when D-pad focus lands on (or
  /// moves within) one of its cards — Flutter's own default "scroll the
  /// focused widget into view" only guarantees the *card* is visible,
  /// which for a row near the bottom of the viewport means it can scroll
  /// just far enough to reveal that one card while pushing an earlier
  /// row's header out of frame above. Reported directly: reaching TV
  /// Shows didn't "roll up" to show it properly, and moving right within
  /// a row made Live TV disappear. Same fix `tv_home_screen.dart`'s own
  /// browse rows already use for this exact problem — `addPostFrameCallback`
  /// so this runs *after* Flutter's own minimal scroll, overriding it
  /// rather than racing it.
  void _ensureRowVisible(GlobalKey rowKey) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = rowKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final rows = q.isEmpty ? const <_ResultRow>[] : _buildRows(playlist, q);

    // Missed in the original Settings-family gradient redesign — Search
    // isn't a Settings screen, it's reached straight from the main tabs,
    // so it wasn't in that pass at all. Same Stack-behind-a-transparent-
    // Scaffold approach as SettingsScaffold itself (not that widget
    // directly: this AppBar's title is a live TextField, not a plain
    // string, which SettingsScaffold's API doesn't have a slot for).
    return withTvThemeIfNeeded(
        context,
        (context) => Stack(
              children: [
                const Positioned.fill(child: SettingsGradientBackground()),
                // A subtle purple wash distinct from whichever palette is
                // active elsewhere — this screen gets its own quiet
                // identity (per direct feedback wanting it to look more
                // like a modern TV search page) without touching the
                // app-wide theme system every other screen relies on.
                // Low alpha + a soft radial falloff keeps it a hint, not
                // a takeover.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.topRight,
                          radius: 1.4,
                          colors: [
                            Colors.deepPurple.withValues(alpha: 0.16),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    title: TextField(
                      controller: _controller,
                      focusNode: _searchFieldFocus,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search everything...',
                        border: InputBorder.none,
                        hintStyle: TextStyle(
                            color: Theme.of(context)
                                .appBarTheme
                                .foregroundColor
                                ?.withValues(alpha: 0.6)),
                      ),
                      style: TextStyle(
                        color: Theme.of(context).appBarTheme.foregroundColor,
                        fontSize: 18,
                      ),
                      onChanged: _onQueryChanged,
                      onSubmitted: _recordSearch,
                      onTap: () => _focusedZone = -1,
                    ),
                    actions: [
                      if (_query.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchDebounce?.cancel();
                            setState(() {
                              _controller.clear();
                              _query = '';
                              _dbVodResults = null;
                              _dbSeriesResults = null;
                            });
                          },
                        ),
                    ],
                  ),
                  body: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                          _moveRowFocus(-1, rows),
                      const SingleActivator(LogicalKeyboardKey.arrowDown):
                          () => _moveRowFocus(1, rows),
                    },
                    child: Column(
                      children: [
                        if (q.isEmpty) _buildSuggestionPills(scheme),
                        if (playlist.isXtream && playlist.isWarmingCatalog)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            child: Row(
                              children: [
                                const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Still loading the full catalog in the background '
                                    '(${playlist.warmCatalogDone}/${playlist.warmCatalogTotal} categories) — '
                                    'some results may not show up yet.',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: q.isEmpty
                              ? (_recentSearches.isEmpty
                                  ? const Center(
                                      child: Text(
                                          'Search Live TV, Movies & TV Shows'))
                                  : const SizedBox())
                              : _buildResultRows(rows),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ));
  }

  Widget _buildSuggestionPills(ColorScheme scheme) {
    if (_recentSearches.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Recent searches',
                    style: Theme.of(context).textTheme.labelLarge),
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
          const SizedBox(height: 4),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _recentSearches.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final term = _recentSearches[i];
                return ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: Text(term),
                  onPressed: () => _runSearch(term),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Builds every non-empty result row, Live TV first then Movies then TV
  /// Shows — per direct feedback: channels read better smaller than a
  /// movie/show poster, and should lead since that's most often what's
  /// being looked for.
  List<_ResultRow> _buildRows(PlaylistManager playlist, String q) {
    final rows = <_ResultRow>[];

    // visibleChannels, not the raw `channels` getter — that one bypasses
    // hidden-group/hidden-channel filtering entirely, which would otherwise
    // let a restricted viewer search their way straight to a hidden
    // channel without ever un-hiding its group.
    final channelMatches = playlist
        .visibleChannels(category: 'tv')
        .where((c) => c.name.toLowerCase().contains(q))
        .toList();
    if (channelMatches.isNotEmpty) {
      rows.add(_buildChannelRow(rows.length, 'Live TV', channelMatches));
    }

    final vodMatches = playlist.isXtream
        ? _dbVodResults
        : playlist
            .visibleChannels(category: 'vod')
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();
    if (vodMatches != null && vodMatches.isNotEmpty) {
      rows.add(_buildChannelRow(rows.length, 'Movies', vodMatches,
          isPoster: true));
    }

    if (playlist.isXtream) {
      final seriesMatches = _dbSeriesResults;
      if (seriesMatches != null && seriesMatches.isNotEmpty) {
        rows.add(_buildSeriesRow(rows.length, 'TV Shows', seriesMatches));
      }
    } else {
      final seriesMatches = playlist
          .visibleChannels(category: 'series')
          .where((c) => c.name.toLowerCase().contains(q))
          .toList();
      if (seriesMatches.isNotEmpty) {
        rows.add(_buildChannelRow(rows.length, 'TV Shows', seriesMatches,
            isPoster: true));
      }
    }

    return rows;
  }

  /// [rowIndex] is this row's final position in the list [_buildRows] is
  /// assembling — known at build time (`rows.length` right before this
  /// row is appended), so every poster's `onFocusGained` can close over
  /// the correct, stable index directly instead of inferring it from
  /// whatever `ListView.builder` happened to lay out most recently (which
  /// doesn't reliably match the focused widget's actual row once lazy
  /// building and scrolling are involved).
  _ResultRow _buildChannelRow(
      int rowIndex, String label, List<Channel> items,
      {bool isPoster = false}) {
    final rowKey = GlobalKey();
    final firstFocusNode = FocusNode();
    final children = <Widget>[
      for (var i = 0; i < items.length; i++)
        PosterCard(
          key: ValueKey('${label}_${items[i].id}'),
          focusNode: i == 0 ? firstFocusNode : null,
          title: items[i].name,
          imageUrl: items[i].logoUrl,
          rating: isPoster ? items[i].rating : null,
          cardWidth: isPoster ? PosterCard.width : 64,
          cardPosterHeight: isPoster ? PosterCard.posterHeight : 64,
          fit: isPoster ? BoxFit.cover : BoxFit.contain,
          onTap: () => _openChannel(items[i]),
          onFocusGained: () {
            _focusedZone = rowIndex;
            _ensureRowVisible(rowKey);
          },
        ),
    ];
    return _ResultRow(label, rowKey, firstFocusNode, children);
  }

  _ResultRow _buildSeriesRow(
      int rowIndex, String label, List<XtreamSeries> items) {
    final rowKey = GlobalKey();
    final firstFocusNode = FocusNode();
    final children = <Widget>[
      for (var i = 0; i < items.length; i++)
        PosterCard(
          key: ValueKey('series_${items[i].id}'),
          focusNode: i == 0 ? firstFocusNode : null,
          title: items[i].name,
          imageUrl: items[i].coverUrl,
          isFavorite: items[i].isFavorite,
          onToggleFavorite: () => _toggleSeriesFavorite(items[i]),
          onTap: () => _openSeries(items[i]),
          onFocusGained: () {
            _focusedZone = rowIndex;
            _ensureRowVisible(rowKey);
          },
        ),
    ];
    return _ResultRow(label, rowKey, firstFocusNode, children);
  }

  Widget _buildResultRows(List<_ResultRow> rows) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off,
                  size: 48, color: Theme.of(context).disabledColor),
              const SizedBox(height: 12),
              const Text('Nothing found'),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: rows.length,
      itemBuilder: (context, rowIndex) {
        final row = rows[rowIndex];
        return Padding(
          key: row.rowKey,
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(row.label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: PosterCard.height + 12,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: row.children,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
