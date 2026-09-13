import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';
import '../utils/constants.dart';
import 'catalog_database.dart';
import 'm3u_parser.dart';
import 'storage_service.dart';
import 'xtream_api_service.dart';

/// Holds the parsed playlist, group visibility, favorites, and search state.
///
/// Two independent source modes:
/// - **M3U** ([loadFromUrl]): a flat [Channel] list parsed from a plain M3U
///   URL, grouped into tabs by keyword-matching the `group-title`.
/// - **Xtream** ([loadFromXtream]): talks to the real Xtream Codes API.
///   Live channels are small enough to fetch whole. VOD/series categories
///   are fetched eagerly (cheap — just names). Category *items* start out
///   lazy ([ensureCategoryLoaded], when a category is opened) but a
///   background pass ([warmAllCategories]) also walks every remaining
///   category on its own afterwards, one at a time, so the whole catalog
///   becomes browsable/searchable without the user needing to open every
///   category by hand — while still never fetching it as one bulk request,
///   which is what caused an OutOfMemoryError on a 28k-live/158k-VOD/
///   50k-series account. Each category is cached to its own small disk
///   file (see [_persistVodCategory]/[_persistSeriesCategory]) rather than
///   one combined blob, for the same reason: re-encoding a single JSON
///   blob for the entire catalog on every update is itself a
///   multi-hundred-MB allocation.
class PlaylistManager extends ChangeNotifier {
  PlaylistManager(this._storage, this._catalogDb);

  final StorageService _storage;
  final CatalogDatabase _catalogDb;

  bool isLoading = false;
  String? error;
  DateTime? lastLoaded;
  String? loadingPhase;
  Map<String, int>? lastLoadSummary;

  /// Background catalog warm-up progress (Xtream mode only) — walks every
  /// VOD/series category that hasn't been loaded yet so nothing requires
  /// manually opening every category to populate it. Tracked per content
  /// type (not just combined) so the UI can show "Movies: 45/159" and
  /// "TV Shows: 22/80" separately, matching how the user actually thinks
  /// about the three content types.
  bool isWarmingCatalog = false;
  int warmCatalogDone = 0;
  int warmCatalogTotal = 0;
  int vodCatalogDone = 0;
  int vodCatalogTotal = 0;
  int seriesCatalogDone = 0;
  int seriesCatalogTotal = 0;

  Set<String> _favoriteIds = {};
  Set<String> _favoriteSeriesIds = {};
  Set<String> _hiddenGroups = {};
  Set<String> _favoritedGroups = {};

  // --- M3U-mode state ---------------------------------------------------
  List<Channel> _channels = [];

  // --- Xtream-mode state --------------------------------------------------
  bool isXtream = false;
  XtreamApiService? _xtreamApi;
  List<Channel> _liveChannels = [];
  List<XtreamCategory> _liveCategories = [];
  List<XtreamCategory> _vodCategories = [];
  List<XtreamCategory> _seriesCategories = [];
  final Map<String, String> _vodCategoryIdByName = {};
  final Map<String, String> _seriesCategoryIdByName = {};
  final Map<String, List<Channel>> _vodByCategoryName = {};
  final Map<String, List<XtreamSeries>> _seriesByCategoryName = {};
  final Set<String> _loadingCategoryNames = {};

  /// How many times each category (keyed the same way as
  /// [_loadingCategoryNames]) has failed to load this session. Confirmed
  /// on real hardware as a genuine, previously-missing safety net: without
  /// this, a category that fails (e.g. HTTP 403 from exceeding the
  /// account's own connection limit — see [_categoryConcurrency]) got
  /// retried again on every single widget rebuild forever, hammering the
  /// server with rejected requests indefinitely for the rest of the
  /// session. [_maxCategoryFailures] failures and it's left alone until
  /// an explicit force refresh (manual "Update Content") clears this.
  final Map<String, int> _categoryFailureCounts = {};
  static const int _maxCategoryFailures = 2;

  /// How many categories to fetch concurrently — capped at the account's
  /// own `max_connections` (from [XtreamApiService.authenticate]) when
  /// known, since firing more concurrent requests than an account allows
  /// gets the extras rejected outright rather than queued. Falls back to
  /// 3 (the concurrency level already confirmed safe/fast on accounts
  /// without a tight limit) when the account didn't report one.
  int get _categoryConcurrency {
    final accountLimit = _xtreamApi?.maxConnections;
    return accountLimit == null ? 3 : accountLimit.clamp(1, 3);
  }

  /// The in-flight (or completed) [ensureLiveChannelsLoaded] load, shared
  /// across every caller — see that method's doc comment for why this
  /// needs to be a shared Future rather than a plain boolean guard.
  Future<void>? _liveChannelsFuture;

  Set<String> get hiddenGroups => _hiddenGroups;
  Set<String> get favoritedGroups => _favoritedGroups;
  bool isGroupFavorited(String title) => _favoritedGroups.contains(title);

  /// "Has anything loaded yet" signal for the empty/loading-state check in
  /// [HomeScreen] — in Xtream mode this is empty until
  /// [ensureLiveChannelsLoaded] actually runs (see its doc comment for why
  /// live channels are no longer fetched eagerly), so callers checking for
  /// "nothing loaded at all yet" should prefer [lastLoadSummary] instead,
  /// which is set as soon as categories restore regardless of live-channel
  /// lazy-load state.
  List<Channel> get channels => isXtream ? _liveChannels : _channels;

  /// Every VOD item cached so far (grows over time via [ensureCategoryLoaded]
  /// and the background warm-up) — used for search.
  List<Channel> get allCachedVod => _vodByCategoryName.values.expand((l) => l).toList();

  /// Every series cached so far — used for search.
  List<XtreamSeries> get allCachedSeries => _seriesByCategoryName.values.expand((l) => l).toList();

  Future<void> init() async {
    // Set synchronously, before the first `await` — main.dart no longer
    // awaits this whole method before showing the home screen (matching
    // how other IPTV players open straight into the UI instead of a
    // blocking splash), so whatever's on screen the instant it renders
    // needs to already read "loading", not a flash of "no channels found"
    // from a still-default, not-yet-started PlaylistManager.
    isLoading = true;
    notifyListeners();
    try {
      _favoriteIds = _storage.getFavorites();
      _favoriteSeriesIds = _storage.getFavoriteSeries();
      _hiddenGroups = _storage.getHiddenGroups();
      _favoritedGroups = _storage.getFavoritedGroups();

      if (_storage.getPlaylistMode() == 'xtream') {
        final server = _storage.getXtreamServer();
        final username = _storage.getXtreamUsername();
        final password = _storage.getXtreamPassword();
        if (server != null && server.isNotEmpty && username != null && password != null) {
          isXtream = true;
          _xtreamApi = XtreamApiService(server: server, username: username, password: password);

          if (await _restoreXtreamCache()) {
            // Was `unawaited(warmAllCategories())` — proactively
            // pre-fetching every selected category in the background on
            // every single launch, competing with whatever the user is
            // actually doing (confirmed on real hardware: this is what
            // was making Movies/TV Shows sluggish/crash-prone on a large
            // catalog, since it ran the whole time the user browsed).
            // `ensureCategoryLoaded`'s on-demand loading (a category
            // fetches once actually scrolled into view) already covers
            // the real need — this eager pass only ever saved a brief
            // loading state the first time you reach a category, which
            // isn't worth the background contention on weak hardware.
            return;
          }
          await loadFromXtream(server: server, username: username, password: password);
          return;
        }
      }

      final url = _storage.getM3uUrl();
      if (url != null && url.isNotEmpty) {
        if (await _restoreM3uCache()) return;
        await loadFromUrl(url);
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // --- M3U mode -----------------------------------------------------------

  Future<bool> _restoreM3uCache() async {
    final raw = await _storage.readCacheFile(AppConstants.cacheFileM3uChannels);
    if (raw == null) return false;
    try {
      final channels = (jsonDecode(raw) as List)
          .map((e) => Channel.fromJson(e as Map<String, dynamic>))
          .toList();
      for (final channel in channels) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }
      isXtream = false;
      _channels = channels;
      return true;
    } catch (e) {
      debugPrint('PlaylistManager: failed to restore M3U cache: $e');
      return false;
    }
  }

  Future<void> loadFromUrl(String url) async {
    isXtream = false;
    isLoading = true;
    error = null;
    lastLoadSummary = null;
    loadingPhase = 'Connecting to server...';
    notifyListeners();

    try {
      final parsed = await M3uParser.fetchAndParse(url);
      for (final channel in parsed) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }

      final counts = <String, int>{'tv': 0, 'vod': 0, 'series': 0};
      for (final channel in parsed) {
        final category = _classifyGroup(channel.group);
        counts[category] = (counts[category] ?? 0) + 1;
      }

      // Brief staged reveal so the counts are readable, rather than flashing
      // by instantly — the parsing above is already done at this point.
      loadingPhase = 'Finding live channels... (${counts['tv']} found)';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding movies... (${counts['vod']} found)';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding TV shows... (${counts['series']} found)';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 400));

      _channels = parsed;
      lastLoadSummary = counts;
      lastLoaded = DateTime.now();
      await _storage.setM3uUrl(url);
      await _storage.writeCacheFile(
        AppConstants.cacheFileM3uChannels,
        jsonEncode(parsed.map((c) => c.toJson()).toList()),
      );

      loadingPhase = 'Playlist added';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistManager error: $e');
    } finally {
      isLoading = false;
      loadingPhase = null;
      notifyListeners();
    }
  }

  /// All groups, in first-seen order, including hidden ones (used by the
  /// Group Management screen). M3U mode only.
  List<M3uGroup> get allGroups {
    final order = <String>[];
    final byTitle = <String, List<Channel>>{};
    for (final channel in _channels) {
      byTitle.putIfAbsent(channel.group, () => []).add(channel);
      if (!order.contains(channel.group)) order.add(channel.group);
    }
    return order
        .map((title) => M3uGroup(
              title: title,
              channels: byTitle[title]!,
              isHidden: _hiddenGroups.contains(title),
            ))
        .toList();
  }

  /// Classifies an M3U group into one of the three content tabs based on
  /// its `group-title`. Series is checked before VOD/movie so "TV Series"
  /// style group names land in the Series tab rather than Movies. Xtream
  /// mode doesn't need this — it gets live/VOD/series as separate API
  /// categories directly.
  String _classifyGroup(String title) {
    final lower = title.toLowerCase();
    if (lower.contains('series') || lower.contains('show')) return 'series';
    if (lower.contains('vod') || lower.contains('movie')) return 'vod';
    return 'tv';
  }

  // --- Xtream mode ----------------------------------------------------------

  // Persisted to the local catalog database now, keyed by category *name*
  // (matching `_vodByCategoryName`/`_seriesByCategoryName`'s in-memory key)
  // rather than one JSON file per category id — see `CatalogDatabase`'s
  // doc comment for why: fully deserializing every cached category into
  // memory on every launch was a genuine memory-capacity problem on a
  // large provider catalog (confirmed via `lowmemorykiller`/thrashing on
  // real hardware), not just the CPU-bound JSON-encode/decode cost the
  // `compute()` isolate approach here used to (and still partially does,
  // for the network-fetch side — see XtreamApiService) address.
  Future<void> _persistVodCategory(String categoryName, List<Channel> items) =>
      _catalogDb.upsertVodCategory(categoryName, items);

  Future<void> _persistSeriesCategory(String categoryName, List<XtreamSeries> items) =>
      _catalogDb.upsertSeriesCategory(categoryName, items);

  Future<bool> _restoreXtreamCache() async {
    try {
      final liveCatRaw = await _storage.readCacheFile(AppConstants.cacheFileLiveCategories);
      final vodCatRaw = await _storage.readCacheFile(AppConstants.cacheFileVodCategories);
      final seriesCatRaw = await _storage.readCacheFile(AppConstants.cacheFileSeriesCategories);
      if (liveCatRaw == null || vodCatRaw == null || seriesCatRaw == null) {
        return false;
      }

      // Batched into one compute() call — same reasoning as
      // XtreamApiService's network-fetch path. Live *channels* themselves
      // are deliberately NOT read/decoded here at all anymore — see
      // ensureLiveChannelsLoaded's doc comment for why eagerly restoring
      // that list (which can run into the tens of thousands of items for a
      // large provider) on every single launch was still a real,
      // measurable relaunch-speed cost even off the main isolate. Category
      // lists are small regardless of catalog size, so they stay eager.
      final decoded = await compute(
        _decodeXtreamCategoriesBatch,
        _XtreamCategoriesRaw(liveCatRaw: liveCatRaw, vodCatRaw: vodCatRaw, seriesCatRaw: seriesCatRaw),
      );
      _liveCategories = decoded.liveCategories;
      _vodCategories = decoded.vodCategories;
      _seriesCategories = decoded.seriesCategories;

      _vodCategoryIdByName
        ..clear()
        ..addEntries(_vodCategories.map((c) => MapEntry(c.name, c.id)));
      _seriesCategoryIdByName
        ..clear()
        ..addEntries(_seriesCategories.map((c) => MapEntry(c.name, c.id)));

      // Deliberately NOT restoring every cached category's items into
      // memory here anymore — that used to fully deserialize the whole
      // catalog on every single launch (first via one JSON file read+
      // decode per category, later via a batched compute() call), which
      // was a genuine memory-capacity problem on a large provider catalog
      // (confirmed via lowmemorykiller/thrashing on real hardware, not
      // just a CPU-bound freeze). `_vodByCategoryName`/
      // `_seriesByCategoryName` simply start empty every launch now,
      // exactly like a fresh install — `ensureCategoryLoaded` queries the
      // local catalog database on demand the moment a category is
      // actually opened, so nothing is loaded into memory until it's
      // genuinely being viewed.

      lastLoadSummary = {
        'tv': _liveChannels.length,
        'vod': _vodCategories.length,
        'series': _seriesCategories.length,
      };
      return true;
    } catch (e) {
      debugPrint('PlaylistManager: failed to restore Xtream cache: $e');
      return false;
    }
  }

  /// Loads the live channel list on first need instead of eagerly on every
  /// launch — the same on-demand shape [ensureCategoryLoaded] already uses
  /// for VOD/series. Confirmed on real hardware: this provider's live
  /// channel list alone can run into the tens of thousands of items, and
  /// even decoding/constructing that off the main isolate (see
  /// `_restoreXtreamCache`'s old approach) still took real wall-clock time
  /// on *every single launch* — the compute() call there stopped it from
  /// freezing the UI, but didn't make the underlying work fast, so it was
  /// still felt as slow relaunches even when going straight to Movies/TV
  /// Shows, which never needed this list at all.
  ///
  /// Callers: `TvHomeScreen`/`HomeScreen`'s Live TV and Favorites views,
  /// `SearchScreen`, and `main.dart`'s auto-resume-last-channel (which
  /// awaits this directly, since it needs the list before it can look
  /// anything up). No-ops once loaded — safe to call unconditionally from
  /// any of them on every build.
  ///
  /// Returns the *same in-flight Future* to every caller while a load is
  /// already running, rather than just checking a boolean and returning
  /// immediately — main.dart's auto-resume awaits this specifically to
  /// wait for the list to exist, and if it lost a race to start the load
  /// against one of the fire-and-forget UI callers, a plain "already
  /// requested, return now" guard would let it fall through to searching
  /// a still-empty list instead of actually waiting for that other
  /// caller's load to finish.
  Future<void> ensureLiveChannelsLoaded() {
    if (!isXtream || _liveChannels.isNotEmpty) return Future<void>.value();
    return _liveChannelsFuture ??= _loadLiveChannelsOnce();
  }

  Future<void> _loadLiveChannelsOnce() async {
    isLoading = true;
    notifyListeners();
    try {
      List<Channel> channels;
      final raw = await _storage.readCacheFile(AppConstants.cacheFileLiveChannels);
      if (raw != null) {
        channels = await compute(_decodeLiveChannelsBatch, raw);
      } else {
        // No cache yet (e.g. a category cache existed but this file
        // somehow didn't) — fall back to a real fetch, same as
        // ensureCategoryLoaded does for a VOD/series cache miss.
        final api = _xtreamApi;
        if (api == null) return;
        final categoryNames = {for (final c in _liveCategories) c.id: c.name};
        channels = await api.getLiveStreams(categoryNames: categoryNames);
        await _storage.writeCacheFile(
          AppConstants.cacheFileLiveChannels,
          jsonEncode(channels.map((c) => c.toJson()).toList()),
        );
      }
      for (final channel in channels) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }
      _liveChannels = channels;
      lastLoadSummary = {...?lastLoadSummary, 'tv': _liveChannels.length};
    } catch (e) {
      debugPrint('PlaylistManager: failed to load live channels: $e');
      _liveChannelsFuture = null; // allow a retry on the next access
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadFromXtream({
    required String server,
    required String username,
    required String password,
  }) async {
    isXtream = true;
    isLoading = true;
    error = null;
    lastLoadSummary = null;
    loadingPhase = 'Connecting to server...';
    notifyListeners();

    try {
      final api = XtreamApiService(server: server, username: username, password: password);
      await api.authenticate();
      _xtreamApi = api;

      // Deliberately NOT clearing _vodByCategoryName/_seriesByCategoryName
      // here — this runs on every "Update content" refresh too, and wiping
      // them upfront meant the Movies/TV Shows tabs went empty the instant
      // you hit refresh, only refilling once warmAllCategories worked back
      // through the whole catalog. [refreshAllCategories] now handles
      // picking up new/changed items itself, category by category, so each
      // one's existing items stay visible until its own refetch completes.
      _liveCategories = await api.getLiveCategories();
      final liveCategoryNames = {for (final c in _liveCategories) c.id: c.name};
      await _storage.writeCacheFile(
        AppConstants.cacheFileLiveCategories,
        jsonEncode(_liveCategories.map((c) => c.toJson()).toList()),
      );

      loadingPhase = 'Finding live channels...';
      notifyListeners();
      final liveChannels = await api.getLiveStreams(categoryNames: liveCategoryNames);
      for (final channel in liveChannels) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }
      _liveChannels = liveChannels;
      await _storage.writeCacheFile(
        AppConstants.cacheFileLiveChannels,
        jsonEncode(liveChannels.map((c) => c.toJson()).toList()),
      );
      loadingPhase = 'Finding live channels... (${liveChannels.length} found)';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding movie categories...';
      notifyListeners();
      _vodCategories = await api.getVodCategories();
      _vodCategoryIdByName
        ..clear()
        ..addEntries(_vodCategories.map((c) => MapEntry(c.name, c.id)));
      // Prune cached items for categories the provider no longer lists,
      // but otherwise leave existing category caches alone (see comment
      // above _liveCategories) — refreshAllCategories decides what to
      // refetch, not this clear.
      _vodByCategoryName.removeWhere((name, _) => !_vodCategoryIdByName.containsKey(name));
      await _storage.writeCacheFile(
        AppConstants.cacheFileVodCategories,
        jsonEncode(_vodCategories.map((c) => c.toJson()).toList()),
      );
      loadingPhase = 'Finding movies... (${_vodCategories.length} categories found)';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding TV show categories...';
      notifyListeners();
      _seriesCategories = await api.getSeriesCategories();
      _seriesCategoryIdByName
        ..clear()
        ..addEntries(_seriesCategories.map((c) => MapEntry(c.name, c.id)));
      _seriesByCategoryName.removeWhere((name, _) => !_seriesCategoryIdByName.containsKey(name));
      await _storage.writeCacheFile(
        AppConstants.cacheFileSeriesCategories,
        jsonEncode(_seriesCategories.map((c) => c.toJson()).toList()),
      );
      loadingPhase = 'Finding TV shows... (${_seriesCategories.length} categories found)';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 400));

      lastLoadSummary = {
        'tv': liveChannels.length,
        'vod': _vodCategories.length,
        'series': _seriesCategories.length,
      };
      lastLoaded = DateTime.now();

      await _storage.setPlaylistMode('xtream');
      await _storage.setXtreamServer(server);
      await _storage.setXtreamUsername(username);
      await _storage.setXtreamPassword(password);

      loadingPhase = 'Playlist added';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistManager error: $e');
    } finally {
      isLoading = false;
      loadingPhase = null;
      notifyListeners();
    }

    // Deliberately NOT auto-starting the catalog warm-up here — the caller
    // (AddPlaylistScreen) asks the user "download everything, or choose
    // groups first?" and starts it explicitly via [warmAllCategories] once
    // that's settled, so a "choose groups" pick actually takes effect
    // before any fetching begins rather than racing it.
  }

  /// Caps how many items of a single category are held in memory/rendered
  /// at once — even after tonight's move to a real database, a single
  /// oversized category (some providers bundle thousands of items under
  /// one "24/7"-style category) can still be enough to strain a
  /// memory-constrained device by itself, since the whole category is
  /// still materialized into Dart objects the moment it's opened. This is
  /// a blunt cap (silently truncates), not real pagination (load-more-on-
  /// scroll) — a full pagination UI is a bigger follow-up; this at least
  /// puts a ceiling on the worst case. The *database* still stores the
  /// full category (see `_persistVodCategory`/`_persistSeriesCategory`),
  /// so raising this cap later doesn't need a re-fetch from the network.
  static const int _maxItemsPerCategory = 300;

  /// Fetches a VOD or series category's items the first time it's opened,
  /// then caches them (in memory for the rest of the session, and to the
  /// local catalog database so they don't need re-fetching from the
  /// network next launch either — but also aren't fully reloaded into
  /// memory on every launch the way the old per-category JSON files were;
  /// they stay queryable-on-demand, same as this on-demand shape already
  /// was for the network fetch). No-ops for live (already loaded whole)
  /// and for categories already cached in memory this session.
  Future<void> ensureCategoryLoaded(String categoryName, String tabCategory) async {
    if (tabCategory == 'tv') return;
    if (tabCategory == 'vod' && _vodByCategoryName.containsKey(categoryName)) return;
    if (tabCategory == 'series' && _seriesByCategoryName.containsKey(categoryName)) return;
    // Keyed by type, not just name — a bare category name is only unique
    // *within* VOD or series, not across both, and this same set also
    // backs ensureCategoriesLoaded's per-tab concurrency count (see its
    // doc comment: sharing raw names let one tab's in-flight fetches
    // starve the other's budget, confirmed on real hardware as Movies
    // appearing stuck while TV Shows' own fetches were still using up
    // the whole shared cap).
    final key = _loadKey(tabCategory, categoryName);
    if (_loadingCategoryNames.contains(key)) return;
    // Confirmed on real hardware: without this, a category that keeps
    // failing (e.g. HTTP 403 from exceeding the account's connection
    // limit) got retried on every single rebuild forever — this is the
    // give-up. force=true full syncs clear these counts first, so a
    // manual "Update Content" always gets a fresh attempt regardless.
    if ((_categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) return;

    _loadingCategoryNames.add(key);
    isLoading = true;
    notifyListeners();

    try {
      if (tabCategory == 'vod') {
        final cached = await _catalogDb.getVodCategory(categoryName, limit: _maxItemsPerCategory);
        if (cached.isNotEmpty) {
          _vodByCategoryName[categoryName] = cached;
          return;
        }
        final api = _xtreamApi;
        final categoryId = _vodCategoryIdByName[categoryName];
        if (!isXtream || api == null || categoryId == null) return;
        final items = await api.getVodStreams(categoryId, categoryName);
        for (final channel in items) {
          channel.isFavorite = _favoriteIds.contains(channel.id);
        }
        await _persistVodCategory(categoryName, items);
        _vodByCategoryName[categoryName] = items.take(_maxItemsPerCategory).toList();
      } else {
        final cached = await _catalogDb.getSeriesCategory(categoryName, limit: _maxItemsPerCategory);
        if (cached.isNotEmpty) {
          _seriesByCategoryName[categoryName] = cached;
          return;
        }
        final api = _xtreamApi;
        final categoryId = _seriesCategoryIdByName[categoryName];
        if (!isXtream || api == null || categoryId == null) return;
        final items = await api.getSeriesForCategory(categoryId);
        for (final series in items) {
          series.isFavorite = _favoriteSeriesIds.contains(series.seriesId.toString());
        }
        await _persistSeriesCategory(categoryName, items);
        _seriesByCategoryName[categoryName] = items.take(_maxItemsPerCategory).toList();
      }
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistManager error: $e');
      _categoryFailureCounts[key] = (_categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      _loadingCategoryNames.remove(key);
      isLoading = false;
      notifyListeners();
    }
  }

  String _loadKey(String tabCategory, String categoryName) => '$tabCategory:$categoryName';

  /// Same first-load-on-demand behavior as [ensureCategoryLoaded], but for
  /// a whole browse screen's worth of categories at once, with a hard cap
  /// on how many load concurrently.
  ///
  /// [_buildMoviesBrowse]/[_buildShowsBrowse] call this on every build for
  /// every visible-but-empty category — necessary so a category ever gets
  /// its first load at all now that the old always-on background warm-up
  /// is disabled (see that comment for why), but calling
  /// [ensureCategoryLoaded] directly in a loop there fired one *unawaited*
  /// network fetch per category with no limit. That's invisible on a
  /// provider where most categories are already cached from earlier
  /// testing, but confirmed on real hardware (137% CPU, a 25s+ ANR) the
  /// moment a *brand-new* provider with hundreds of categories was added —
  /// every single one is empty on the very first render, so all of them
  /// fired their network fetch + compute() isolate at once.
  ///
  /// This must check the *live* [_loadingCategoryNames] count for this
  /// specific [tabCategory], not a count local to one call — a first
  /// attempt spawned a fixed pool of 3 workers *per call*, but every
  /// category starting or finishing calls `notifyListeners()`, which
  /// triggers a screen rebuild, which calls this again — so a fresh trio
  /// of workers kept stacking on top of whatever was already in flight
  /// instead of actually staying capped at 3 (confirmed on real hardware:
  /// no longer crashing, but not meaningfully faster either, since the
  /// throttle wasn't really holding). Checking the live count directly
  /// means every call — however often it's re-entered — only ever tops up
  /// to the real ceiling, never past it.
  ///
  /// Scoped *per tab category* (vod vs. series each get their own budget
  /// of 3, not a shared 3 between them) — confirmed on real hardware that
  /// sharing one counter let one tab's in-flight fetches starve the
  /// other's: switching to Movies while TV Shows' 3 were still loading
  /// left Movies' own kick-off unable to start anything at all until one
  /// of those unrelated series fetches finished.
  ///
  /// The concurrency budget itself ([_categoryConcurrency]) is capped at
  /// the account's own `max_connections` when known — confirmed on real
  /// hardware that firing more concurrent requests than an account allows
  /// gets the extras rejected with HTTP 403, not queued.
  Future<void> ensureCategoriesLoaded(Iterable<String> categoryNames, String tabCategory) async {
    final maxConcurrent = _categoryConcurrency;
    final loadedMap = tabCategory == 'vod' ? _vodByCategoryName : _seriesByCategoryName;
    final prefix = '$tabCategory:';
    for (final name in categoryNames) {
      if (_loadingCategoryNames.where((k) => k.startsWith(prefix)).length >= maxConcurrent) return;
      final key = _loadKey(tabCategory, name);
      if (loadedMap.containsKey(name) ||
          _loadingCategoryNames.contains(key) ||
          (_categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
        continue;
      }
      unawaited(ensureCategoryLoaded(name, tabCategory));
    }
  }

  /// Fetches one VOD category's items, so the whole catalog eventually
  /// becomes available without the user having to open each category by
  /// hand. Runs in the background — safe to browse/search/play while it's
  /// going. Skips a category already cached unless [force] (used by
  /// [refreshAllCategories] to pick up new/changed items in a category
  /// that was fetched before) — the new items simply overwrite the old
  /// entry once they arrive, so the category stays populated with its
  /// (possibly stale) old items the whole time it's being refetched
  /// instead of going empty first.
  Future<void> _loadOneVodCategory(XtreamApiService api, XtreamCategory cat, {bool force = false}) async {
    final key = _loadKey('vod', cat.name);
    if ((!force && _vodByCategoryName.containsKey(cat.name)) ||
        _loadingCategoryNames.contains(key) ||
        (_categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
      return;
    }
    _loadingCategoryNames.add(key);
    try {
      final items = await api.getVodStreams(cat.id, cat.name);
      for (final channel in items) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }
      await _persistVodCategory(cat.name, items);
      _vodByCategoryName[cat.name] = items.take(_maxItemsPerCategory).toList();
    } catch (e) {
      debugPrint('PlaylistManager: background load failed for movies "${cat.name}": $e');
      _categoryFailureCounts[key] = (_categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      _loadingCategoryNames.remove(key);
    }
  }

  Future<void> _loadOneSeriesCategory(XtreamApiService api, XtreamCategory cat, {bool force = false}) async {
    final key = _loadKey('series', cat.name);
    if ((!force && _seriesByCategoryName.containsKey(cat.name)) ||
        _loadingCategoryNames.contains(key) ||
        (_categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
      return;
    }
    _loadingCategoryNames.add(key);
    try {
      final items = await api.getSeriesForCategory(cat.id);
      for (final series in items) {
        series.isFavorite = _favoriteSeriesIds.contains(series.seriesId.toString());
      }
      await _persistSeriesCategory(cat.name, items);
      _seriesByCategoryName[cat.name] = items.take(_maxItemsPerCategory).toList();
    } catch (e) {
      debugPrint('PlaylistManager: background load failed for TV shows "${cat.name}": $e');
      _categoryFailureCounts[key] = (_categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      _loadingCategoryNames.remove(key);
    }
  }

  /// Walks every VOD/series category that isn't cached yet — alternating
  /// one movie category with one TV show category rather than doing all
  /// 100+ movie categories before starting on a single show, which left
  /// TV Shows looking un-loaded for however long the movies pass took.
  DateTime? _lastWarmupNotify;

  /// Notifying on every single category (up to 200+ times in a row) forces
  /// a full rebuild of whatever's on screen that many times in rapid
  /// succession — on weaker TV-box hardware that's enough rebuild pressure
  /// to make the UI thread choke badly enough to get killed. Progress at
  /// a few updates per second is visually indistinguishable from every
  /// single one, so throttle it; [force] still always notifies (start/end
  /// of the pass, so the UI never shows a stale "0%" or gets stuck short
  /// of "100%").
  void _notifyWarmupProgress({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastWarmupNotify != null &&
        now.difference(_lastWarmupNotify!) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastWarmupNotify = now;
    notifyListeners();
  }

  /// Walks every VOD/series category that isn't cached yet and isn't
  /// hidden, one at a time, fetching its items in the background. Hidden
  /// categories are skipped entirely — the content filter ("download
  /// everything" vs "choose groups") works by hiding everything not
  /// chosen *before* calling this, so unwanted categories are genuinely
  /// never fetched, not just filtered from display.
  Future<void> warmAllCategories() => _warmCategories(force: false);

  /// Re-fetches every non-hidden VOD/series category's items, including
  /// ones already cached — the "Update content" action. A plain
  /// [warmAllCategories] pass only ever fills in categories that have
  /// never been fetched, so it can't pick up new items a provider added to
  /// a category that was already loaded, and it won't recover a category
  /// that was filtered out at add-playlist time and later un-hidden in
  /// Group Management without the user re-opening every one of them by
  /// hand. This does the same background walk but with `force: true`, so
  /// nothing is skipped just because it's already cached.
  Future<void> refreshAllCategories() => _warmCategories(force: true);

  /// True when the catalog hasn't had a *full* sync (every non-hidden
  /// category's items, not just category names/live channels) recently
  /// enough — main.dart checks this right after [init] to decide whether
  /// to block behind [runFullCatalogSync] before showing the main UI, or
  /// open straight into an already-populated catalog.
  ///
  /// This is deliberately infrequent (days, not every launch) — the whole
  /// point of [runFullCatalogSync] is a TiviMate/MyTVOnline3-style
  /// "Updating..." pass that happens a couple of times a week, not
  /// something that reintroduces a long wait on every single open. The
  /// actual number of days is user-configurable (Content Manager), not
  /// hardcoded — [maxAge] is only an override for callers that genuinely
  /// want a different window (none currently do; it defaults to reading
  /// the user's own setting).
  bool needsFullSync({Duration? maxAge}) {
    if (!isXtream) return false;
    final effectiveMaxAge = maxAge ?? Duration(days: _storage.getSyncFrequencyDays());
    final last = _storage.getLastFullSyncAt();
    if (last == null) return true;
    return DateTime.now().difference(last) > effectiveMaxAge;
  }

  /// The blocking "Updating..." pass established players like TiviMate and
  /// MyTVOnline3 do a few times a week rather than on every launch: re-
  /// fetches category lists + live channels, then every non-hidden VOD/
  /// series category's items, then marks the catalog fresh.
  ///
  /// Deliberately reuses [loadFromXtream] + [refreshAllCategories] — this
  /// is the exact same work "Update Content" already does; what's new is
  /// running it automatically when stale and awaiting it fully behind a
  /// dedicated screen (see main.dart), instead of firing it in the
  /// background while the user is already looking at a possibly-empty or
  /// stale catalog.
  ///
  /// Hidden groups are untouched by any of this — [_hiddenGroups] is a
  /// separate persisted set, keyed by category name, that only ever
  /// changes via an explicit user action (the hold-to-hide gesture). A
  /// category re-appearing in a fresh fetch doesn't un-hide it; only a
  /// genuinely *new* category name (never seen, so never added to that
  /// set) shows up unhidden, exactly like the very first time it appeared.
  Future<void> runFullCatalogSync() async {
    if (!isXtream) return;
    final server = _storage.getXtreamServer();
    final username = _storage.getXtreamUsername();
    final password = _storage.getXtreamPassword();
    if (server == null || username == null || password == null) return;
    await loadFromXtream(server: server, username: username, password: password);
    await refreshAllCategories();
  }

  /// Marks the catalog fresh whenever a warm-up pass actually ran to
  /// completion — whether that's the initial post-Add-Playlist pass, a
  /// manual "Update Content", or [runFullCatalogSync]'s automatic version.
  /// Centralized here (rather than at each call site) so every path that
  /// does a real full pass resets the "couple times a week" clock the same
  /// way, and a call that no-ops (already warming, or no Xtream session)
  /// correctly does *not* claim credit for a sync that didn't happen.
  Future<void> _warmCategories({required bool force}) async {
    // Two overlapping passes (e.g. the playlist add flow triggering a
    // second warm-up before the first finished) each reset and then
    // increment these same shared counters independently — that's how the
    // progress banner ended up showing over 100%. A pass already running
    // just absorbs whatever this call would have done; nothing is lost,
    // since the running pass covers the same "not yet cached, not hidden"
    // categories this one would have computed anyway.
    if (isWarmingCatalog) return;

    final api = _xtreamApi;
    if (api == null) return;

    // A manual "Update Content" (force: true) is a deliberate request to
    // re-check everything — give every category that previously hit
    // _maxCategoryFailures a fresh set of attempts rather than leaving it
    // silently skipped forever because of an earlier session's failures
    // (e.g. a transient rejection, since fixed elsewhere by capping
    // concurrency to the account's own limit).
    if (force) _categoryFailureCounts.clear();

    try {
      final vodTodo = _vodCategories
          .where((c) =>
              (force || !_vodByCategoryName.containsKey(c.name)) && !_hiddenGroups.contains(c.name))
          .toList();
      final seriesTodo = _seriesCategories
          .where((c) =>
              (force || !_seriesByCategoryName.containsKey(c.name)) && !_hiddenGroups.contains(c.name))
          .toList();
      final total = vodTodo.length + seriesTodo.length;
      if (total > 0) {
        isWarmingCatalog = true;
        warmCatalogDone = 0;
        warmCatalogTotal = total;
        vodCatalogDone = 0;
        vodCatalogTotal = vodTodo.length;
        seriesCatalogDone = 0;
        seriesCatalogTotal = seriesTodo.length;
        _notifyWarmupProgress(force: true);

        // Was fully sequential (one category, awaited, at a time,
        // alternating VOD/series) — confirmed on real hardware as the
        // reason a full sync could still be running after 2+ minutes on
        // a catalog with any real number of categories: total time
        // scaled linearly with category count, with zero parallelism.
        // This isn't the same re-entrancy-prone spot ensureCategoriesLoaded
        // had to guard against (that gets called on every widget rebuild;
        // this runs once per _warmCategories call, guarded by
        // isWarmingCatalog above), so a plain fixed worker pool is safe
        // here — no need for the live-count-based cap that method needed.
        // Capped at the account's own connection limit, same reasoning as
        // ensureCategoriesLoaded — see _categoryConcurrency.
        final maxConcurrent = _categoryConcurrency;
        var vodIndex = 0;
        Future<void> vodWorker() async {
          while (vodIndex < vodTodo.length) {
            final cat = vodTodo[vodIndex++];
            await _loadOneVodCategory(api, cat, force: force);
            vodCatalogDone++;
            warmCatalogDone++;
            _notifyWarmupProgress();
          }
        }

        var seriesIndex = 0;
        Future<void> seriesWorker() async {
          while (seriesIndex < seriesTodo.length) {
            final cat = seriesTodo[seriesIndex++];
            await _loadOneSeriesCategory(api, cat, force: force);
            seriesCatalogDone++;
            warmCatalogDone++;
            _notifyWarmupProgress();
          }
        }

        await Future.wait([
          ...List.generate(
              vodTodo.isEmpty ? 0 : maxConcurrent.clamp(1, vodTodo.length), (_) => vodWorker()),
          ...List.generate(
              seriesTodo.isEmpty ? 0 : maxConcurrent.clamp(1, seriesTodo.length), (_) => seriesWorker()),
        ]);
      }
      await _storage.setLastFullSyncAt(DateTime.now());
    } catch (e) {
      // This runs fire-and-forget in the background — an uncaught error
      // here must never escape as an unhandled Future error.
      debugPrint('PlaylistManager: catalog warm-up failed: $e');
    } finally {
      isWarmingCatalog = false;
      _notifyWarmupProgress(force: true);
    }
  }

  /// Fetches episodes for one series, grouped by season number.
  Future<({Map<int, List<Channel>> episodes, String? plot})> loadSeriesEpisodes(XtreamSeries series) async {
    final api = _xtreamApi;
    if (api == null) return (episodes: <int, List<Channel>>{}, plot: null);
    final result = await api.getSeriesEpisodes(series.seriesId, series.name);
    for (final list in result.episodes.values) {
      for (final channel in list) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
        // Lets "Continue Watching" show/reopen the actual show rather
        // than just this one episode — see TvHomeScreen._buildContinueWatchingRow.
        channel.seriesId = series.seriesId;
        channel.seriesName = series.name;
        channel.seriesCoverUrl = series.coverUrl;
      }
    }
    return result;
  }

  /// Movie plot/description, fetched on demand when [MovieDetailScreen]
  /// opens for one title — see [XtreamApiService.getVodDescription] for
  /// why this isn't part of the bulk category fetch.
  Future<String?> getVodDescription(String vodStreamId) async {
    final api = _xtreamApi;
    if (api == null) return null;
    return api.getVodDescription(vodStreamId);
  }

  List<M3uGroup> get tvGroups {
    if (isXtream) {
      return _liveCategories
          .map((c) => M3uGroup(
                title: c.name,
                channels: const [],
                isHidden: _hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups.where((g) => _classifyGroup(g.title) == 'tv').toList();
  }

  List<M3uGroup> get vodGroups {
    if (isXtream) {
      return _vodCategories
          .map((c) => M3uGroup(
                title: c.name,
                channels: _vodByCategoryName[c.name] ?? const [],
                isHidden: _hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups.where((g) => _classifyGroup(g.title) == 'vod').toList();
  }

  List<M3uGroup> get seriesGroups {
    if (isXtream) {
      return _seriesCategories
          .map((c) => M3uGroup(
                title: c.name,
                channels: const [],
                isHidden: _hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups.where((g) => _classifyGroup(g.title) == 'series').toList();
  }

  /// Individually-starred channels, plus every channel belonging to a
  /// group favorited as a whole (see [setGroupFavorited]) — the two are
  /// just different ways of getting into the same list, not separate
  /// concepts to reconcile.
  List<Channel> get favoriteChannels {
    if (!isXtream) {
      return _channels.where((c) => c.isFavorite || _favoritedGroups.contains(c.group)).toList();
    }
    final all = <Channel>[..._liveChannels, ...allCachedVod];
    return all.where((c) => c.isFavorite || _favoritedGroups.contains(c.group)).toList();
  }

  /// Individually-favorited *live* channels only — narrower than
  /// [favoriteChannels] (which also folds in whole-favorited-group members
  /// of any kind). Backs the TV tab's own pinned "Favourites" entry, which
  /// is meant to be channels-only. [channels] is already live-only for
  /// Xtream, but for M3U it's the full flat list (no separate live/vod/
  /// series storage split there) — so a classification guard is needed on
  /// that side or a favorited movie would leak into a "channels only" view.
  List<Channel> get favoriteLiveChannels {
    if (!isXtream) {
      return channels.where((c) => c.isFavorite && _classifyGroup(c.group) == 'tv').toList();
    }
    return channels.where((c) => c.isFavorite).toList();
  }

  /// Individually-favorited movies only — feeds the Favorites tab's
  /// "Movies" section. Whole-favorited-group VOD members are reached
  /// separately via that tab's group list, same as today.
  List<Channel> get favoriteMovies {
    final source = isXtream ? allCachedVod : _channels.where((c) => _classifyGroup(c.group) == 'vod');
    return source.where((c) => c.isFavorite).toList();
  }

  /// Individually-favorited TV shows — Xtream only, since `XtreamSeries`
  /// doesn't exist in M3U mode. See [favoriteShowChannels] for that case.
  List<XtreamSeries> get favoriteSeries =>
      isXtream ? allCachedSeries.where((s) => s.isFavorite).toList() : const [];

  /// M3U counterpart to [favoriteSeries] — M3U mode has no `XtreamSeries`
  /// concept; its "series-like" content is already plain [Channel]s
  /// (individually favoritable the normal way), so this filters those by
  /// classification instead of returning empty the way [favoriteSeries]
  /// does for M3U.
  List<Channel> get favoriteShowChannels => isXtream
      ? const []
      : _channels.where((c) => c.isFavorite && _classifyGroup(c.group) == 'series').toList();

  /// Favorites a whole category at once — every channel in it shows up
  /// under Favorites without needing to star each one individually. Also
  /// tracked for TV Shows categories (series don't have their own
  /// favorite flag, so this is the only favoriting concept that applies
  /// there), though the Favorites tab itself doesn't render series cards
  /// yet — group-level TV Shows favorites are recorded but not yet
  /// surfaced anywhere beyond the star shown on the group row itself.
  Future<void> setGroupFavorited(String title, bool favorited) async {
    if (favorited) {
      _favoritedGroups.add(title);
    } else {
      _favoritedGroups.remove(title);
    }
    await _storage.setFavoritedGroups(_favoritedGroups);
    notifyListeners();
  }

  /// Channels for [groupTitle] (or, when null, every non-hidden group in the
  /// tab indicated by [category] — one of 'tv', 'vod', 'series'). In Xtream
  /// mode, 'series' always returns empty — series aren't directly playable,
  /// use [visibleSeries] instead.
  List<Channel> visibleChannels({String? groupTitle, required String category}) {
    if (isXtream) {
      switch (category) {
        case 'tv':
          return groupTitle != null
              ? _liveChannels.where((c) => c.group == groupTitle).toList()
              : _liveChannels.where((c) => !_hiddenGroups.contains(c.group)).toList();
        case 'vod':
          return groupTitle != null
              ? (_vodByCategoryName[groupTitle] ?? const [])
              : _vodByCategoryName.entries
                  .where((e) => !_hiddenGroups.contains(e.key))
                  .expand((e) => e.value)
                  .toList();
        default:
          return const [];
      }
    }

    if (groupTitle != null) {
      return _channels.where((c) => c.group == groupTitle).toList();
    }
    return _channels
        .where((c) => _classifyGroup(c.group) == category && !_hiddenGroups.contains(c.group))
        .toList();
  }

  /// Series for [categoryName] (or every cached category when null). Xtream
  /// mode only — plain M3U playlists have no separate series concept, so
  /// M3U-mode series-like groups are just regular [Channel]s already
  /// reachable via [visibleChannels].
  List<XtreamSeries> visibleSeries(String? categoryName) {
    if (categoryName != null) return _seriesByCategoryName[categoryName] ?? const [];
    return _seriesByCategoryName.entries
        .where((e) => !_hiddenGroups.contains(e.key))
        .expand((e) => e.value)
        .toList();
  }

  Future<void> toggleFavorite(Channel channel) async {
    channel.isFavorite = !channel.isFavorite;
    if (channel.isFavorite) {
      _favoriteIds.add(channel.id);
    } else {
      _favoriteIds.remove(channel.id);
    }
    await _storage.setFavorites(_favoriteIds);
    // Harmless no-op for a live/M3U channel (no matching row in the
    // catalog database) — only actually updates a row for a VOD channel.
    await _catalogDb.setVodFavorite(channel.id, channel.isFavorite);
    notifyListeners();
  }

  bool isSeriesFavorited(int seriesId) => _favoriteSeriesIds.contains(seriesId.toString());

  Future<void> toggleSeriesFavorite(XtreamSeries series) async {
    series.isFavorite = !series.isFavorite;
    if (series.isFavorite) {
      _favoriteSeriesIds.add(series.seriesId.toString());
    } else {
      _favoriteSeriesIds.remove(series.seriesId.toString());
    }
    await _storage.setFavoriteSeries(_favoriteSeriesIds);
    await _catalogDb.setSeriesFavorite(series.seriesId, series.isFavorite);
    notifyListeners();
  }

  Future<void> toggleGroupHidden(String groupTitle) async {
    if (_hiddenGroups.contains(groupTitle)) {
      _hiddenGroups.remove(groupTitle);
    } else {
      _hiddenGroups.add(groupTitle);
    }
    await _storage.setHiddenGroups(_hiddenGroups);
    notifyListeners();
  }

  /// Explicitly sets one group's visibility (used by the checkbox-style
  /// Group Management screen, where "checked" unambiguously means "shown"
  /// rather than toggling relative to unknown current state).
  ///
  /// [loadImmediately] fires off a fetch for that one category the moment
  /// it's un-hidden — right for the *ongoing* Group Management screen
  /// (Content Manager), wrong for the "choose groups first" step during
  /// initial playlist setup: checking boxes there one after another was
  /// each kicking off its own network fetch immediately, which is what
  /// caused rapid-fire loading/jank while picking groups instead of one
  /// batched pass once the choice is actually finalized (that pass is
  /// [warmAllCategories], called right after this screen closes). Set to
  /// false from that flow.
  Future<void> setGroupHidden(String groupTitle, bool hidden, {bool loadImmediately = true}) async {
    if (hidden) {
      _hiddenGroups.add(groupTitle);
    } else {
      _hiddenGroups.remove(groupTitle);
    }
    await _storage.setHiddenGroups(_hiddenGroups);
    notifyListeners();
    if (!hidden && loadImmediately) unawaited(_loadIfNewlyShown(groupTitle));
  }

  /// Bulk hide/show — the "Hide All" / "Show All" buttons in Group
  /// Management. See [setGroupHidden] for [loadImmediately].
  Future<void> setGroupsHidden(Iterable<String> groupTitles, bool hidden, {bool loadImmediately = true}) async {
    for (final title in groupTitles) {
      if (hidden) {
        _hiddenGroups.add(title);
      } else {
        _hiddenGroups.remove(title);
      }
    }
    await _storage.setHiddenGroups(_hiddenGroups);
    notifyListeners();
    if (!hidden && loadImmediately) {
      for (final title in groupTitles) {
        unawaited(_loadIfNewlyShown(title));
      }
    }
  }

  /// A category filtered out at add-playlist time (or hidden later) was
  /// never fetched, so un-hiding it alone left it visible-but-empty until
  /// something happened to trigger a fetch — [ensureCategoryLoaded] is a
  /// no-op for anything already cached, so it's safe to call unconditionally
  /// whenever a group's visibility flips on, rather than waiting for the
  /// next full "Update content" pass.
  Future<void> _loadIfNewlyShown(String groupTitle) async {
    if (!isXtream) return;
    if (_vodCategoryIdByName.containsKey(groupTitle)) {
      await ensureCategoryLoaded(groupTitle, 'vod');
    } else if (_seriesCategoryIdByName.containsKey(groupTitle)) {
      await ensureCategoryLoaded(groupTitle, 'series');
    }
  }
}

// Top-level — required by `compute`, which runs this on a separate isolate
// with no access to instance state.
class _XtreamCategoriesRaw {
  const _XtreamCategoriesRaw({
    required this.liveCatRaw,
    required this.vodCatRaw,
    required this.seriesCatRaw,
  });
  final String liveCatRaw;
  final String vodCatRaw;
  final String seriesCatRaw;
}

class _XtreamCategoriesDecoded {
  const _XtreamCategoriesDecoded({
    required this.liveCategories,
    required this.vodCategories,
    required this.seriesCategories,
  });
  final List<XtreamCategory> liveCategories;
  final List<XtreamCategory> vodCategories;
  final List<XtreamCategory> seriesCategories;
}

_XtreamCategoriesDecoded _decodeXtreamCategoriesBatch(_XtreamCategoriesRaw raw) {
  final liveCategories = (jsonDecode(raw.liveCatRaw) as List)
      .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
      .toList();
  final vodCategories = (jsonDecode(raw.vodCatRaw) as List)
      .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
      .toList();
  final seriesCategories = (jsonDecode(raw.seriesCatRaw) as List)
      .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
      .toList();
  return _XtreamCategoriesDecoded(
    liveCategories: liveCategories,
    vodCategories: vodCategories,
    seriesCategories: seriesCategories,
  );
}

// Separate from the categories batch above — deliberately NOT decoded
// eagerly on every launch anymore, see ensureLiveChannelsLoaded.
List<Channel> _decodeLiveChannelsBatch(String raw) =>
    (jsonDecode(raw) as List).map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();
