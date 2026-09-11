import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';
import '../utils/constants.dart';
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
  PlaylistManager(this._storage);

  final StorageService _storage;

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

  Set<String> get hiddenGroups => _hiddenGroups;
  Set<String> get favoritedGroups => _favoritedGroups;
  bool isGroupFavorited(String title) => _favoritedGroups.contains(title);

  /// "Has anything loaded yet" signal for the empty/loading-state check in
  /// [HomeScreen] — live channels stand in for the whole catalog in Xtream
  /// mode, since that's what's fetched eagerly.
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

  String _vodCategoryCacheKey(String categoryId) =>
      '${AppConstants.cacheFileVodCategoryPrefix}$categoryId';
  String _seriesCategoryCacheKey(String categoryId) =>
      '${AppConstants.cacheFileSeriesCategoryPrefix}$categoryId';

  // These run on a background isolate via `compute` — confirmed on real
  // hardware (pausing the Dart VM mid-freeze found the isolate stuck
  // inside a single uninterruptible native call the whole time, which
  // only happens for something like a big synchronous JSON encode/decode,
  // never a Dart-level loop) that this is exactly what was causing an ANR
  // just from scrolling Movies/TV Shows: `ensureCategoryLoaded` runs one
  // of these every time a newly-visible category is opened, and a large
  // provider's category payload is big enough to block the UI thread for
  // seconds. Must be top-level/static functions, not closures — `compute`
  // runs them on a different isolate with no access to `this`.
  Future<void> _persistVodCategory(String categoryId, List<Channel> items) =>
      compute(_encodeChannelsJson, items)
          .then((json) => _storage.writeCacheFile(_vodCategoryCacheKey(categoryId), json));

  Future<void> _persistSeriesCategory(String categoryId, List<XtreamSeries> items) =>
      compute(_encodeSeriesJson, items)
          .then((json) => _storage.writeCacheFile(_seriesCategoryCacheKey(categoryId), json));

  Future<bool> _restoreXtreamCache() async {
    try {
      final liveRaw = await _storage.readCacheFile(AppConstants.cacheFileLiveChannels);
      final liveCatRaw = await _storage.readCacheFile(AppConstants.cacheFileLiveCategories);
      final vodCatRaw = await _storage.readCacheFile(AppConstants.cacheFileVodCategories);
      final seriesCatRaw = await _storage.readCacheFile(AppConstants.cacheFileSeriesCategories);
      if (liveRaw == null || liveCatRaw == null || vodCatRaw == null || seriesCatRaw == null) {
        return false;
      }

      final liveChannels = (jsonDecode(liveRaw) as List)
          .map((e) => Channel.fromJson(e as Map<String, dynamic>))
          .toList();
      for (final channel in liveChannels) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }
      _liveChannels = liveChannels;

      _liveCategories = (jsonDecode(liveCatRaw) as List)
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList();
      _vodCategories = (jsonDecode(vodCatRaw) as List)
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList();
      _seriesCategories = (jsonDecode(seriesCatRaw) as List)
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList();

      _vodCategoryIdByName
        ..clear()
        ..addEntries(_vodCategories.map((c) => MapEntry(c.name, c.id)));
      _seriesCategoryIdByName
        ..clear()
        ..addEntries(_seriesCategories.map((c) => MapEntry(c.name, c.id)));

      // Reading each category's cache file (cheap file I/O) is still fired
      // concurrently — that was never the problem. What WAS a real
      // regression, confirmed on real hardware (crashed on launch itself
      // with 20+ cached categories): decoding used to spawn one
      // `compute()` background isolate PER category, all at once — every
      // single launch. Isolate spawning has real overhead; doing it 20+
      // times concurrently is itself expensive on weak hardware. Reading
      // stays concurrent (cheap); decoding is now ONE `compute()` call
      // for the whole batch instead of one per category.
      final vodRawByName = <String, String>{};
      await Future.wait(_vodCategories.map((cat) async {
        final raw = await _storage.readCacheFile(_vodCategoryCacheKey(cat.id));
        if (raw != null) vodRawByName[cat.name] = raw;
      }));
      final vodEntries = vodRawByName.isEmpty
          ? <MapEntry<String, List<Channel>>>[]
          : await compute(_decodeChannelsJsonBatch, (vodRawByName, _favoriteIds));
      _vodByCategoryName
        ..clear()
        ..addEntries(vodEntries);

      final seriesRawByName = <String, String>{};
      await Future.wait(_seriesCategories.map((cat) async {
        final raw = await _storage.readCacheFile(_seriesCategoryCacheKey(cat.id));
        if (raw != null) seriesRawByName[cat.name] = raw;
      }));
      final seriesEntries = seriesRawByName.isEmpty
          ? <MapEntry<String, List<XtreamSeries>>>[]
          : await compute(_decodeSeriesJsonBatch, (seriesRawByName, _favoriteSeriesIds));
      _seriesByCategoryName
        ..clear()
        ..addEntries(seriesEntries);

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

  /// Fetches a VOD or series category's items the first time it's opened,
  /// then caches them (in memory for the rest of the session, and to disk
  /// so they don't need re-fetching next launch either). No-ops for live
  /// (already loaded whole) and for categories already cached.
  Future<void> ensureCategoryLoaded(String categoryName, String tabCategory) async {
    final api = _xtreamApi;
    if (!isXtream || api == null) return;
    if (tabCategory == 'tv') return;
    if (tabCategory == 'vod' && _vodByCategoryName.containsKey(categoryName)) return;
    if (tabCategory == 'series' && _seriesByCategoryName.containsKey(categoryName)) return;
    if (_loadingCategoryNames.contains(categoryName)) return;

    final categoryId = tabCategory == 'vod'
        ? _vodCategoryIdByName[categoryName]
        : _seriesCategoryIdByName[categoryName];
    if (categoryId == null) return;

    _loadingCategoryNames.add(categoryName);
    isLoading = true;
    notifyListeners();

    try {
      if (tabCategory == 'vod') {
        final items = await api.getVodStreams(categoryId, categoryName);
        for (final channel in items) {
          channel.isFavorite = _favoriteIds.contains(channel.id);
        }
        _vodByCategoryName[categoryName] = items;
        await _persistVodCategory(categoryId, items);
      } else {
        final items = await api.getSeriesForCategory(categoryId);
        for (final series in items) {
          series.isFavorite = _favoriteSeriesIds.contains(series.seriesId.toString());
        }
        _seriesByCategoryName[categoryName] = items;
        await _persistSeriesCategory(categoryId, items);
      }
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistManager error: $e');
    } finally {
      _loadingCategoryNames.remove(categoryName);
      isLoading = false;
      notifyListeners();
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
    if ((!force && _vodByCategoryName.containsKey(cat.name)) ||
        _loadingCategoryNames.contains(cat.name)) {
      return;
    }
    _loadingCategoryNames.add(cat.name);
    try {
      final items = await api.getVodStreams(cat.id, cat.name);
      for (final channel in items) {
        channel.isFavorite = _favoriteIds.contains(channel.id);
      }
      _vodByCategoryName[cat.name] = items;
      await _persistVodCategory(cat.id, items);
    } catch (e) {
      debugPrint('PlaylistManager: background load failed for movies "${cat.name}": $e');
    } finally {
      _loadingCategoryNames.remove(cat.name);
    }
  }

  Future<void> _loadOneSeriesCategory(XtreamApiService api, XtreamCategory cat, {bool force = false}) async {
    if ((!force && _seriesByCategoryName.containsKey(cat.name)) ||
        _loadingCategoryNames.contains(cat.name)) {
      return;
    }
    _loadingCategoryNames.add(cat.name);
    try {
      final items = await api.getSeriesForCategory(cat.id);
      for (final series in items) {
        series.isFavorite = _favoriteSeriesIds.contains(series.seriesId.toString());
      }
      _seriesByCategoryName[cat.name] = items;
      await _persistSeriesCategory(cat.id, items);
    } catch (e) {
      debugPrint('PlaylistManager: background load failed for TV shows "${cat.name}": $e');
    } finally {
      _loadingCategoryNames.remove(cat.name);
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
      if (total == 0) return;

      isWarmingCatalog = true;
      warmCatalogDone = 0;
      warmCatalogTotal = total;
      vodCatalogDone = 0;
      vodCatalogTotal = vodTodo.length;
      seriesCatalogDone = 0;
      seriesCatalogTotal = seriesTodo.length;
      _notifyWarmupProgress(force: true);

      var vodIndex = 0;
      var seriesIndex = 0;
      while (vodIndex < vodTodo.length || seriesIndex < seriesTodo.length) {
        if (vodIndex < vodTodo.length) {
          await _loadOneVodCategory(api, vodTodo[vodIndex], force: force);
          vodIndex++;
          vodCatalogDone++;
          warmCatalogDone++;
          _notifyWarmupProgress();
        }
        if (seriesIndex < seriesTodo.length) {
          await _loadOneSeriesCategory(api, seriesTodo[seriesIndex], force: force);
          seriesIndex++;
          seriesCatalogDone++;
          warmCatalogDone++;
          _notifyWarmupProgress();
        }
      }
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

// Top-level (not instance methods) — required by `compute`, which runs
// these on a separate isolate with no access to `this`. See the doc
// comment on `_persistVodCategory`/`_restoreXtreamCache` for why these
// specific calls needed to move off the UI thread.
String _encodeChannelsJson(List<Channel> items) => jsonEncode(items.map((c) => c.toJson()).toList());

String _encodeSeriesJson(List<XtreamSeries> items) => jsonEncode(items.map((s) => s.toJson()).toList());

/// Decodes every cached VOD category's raw JSON in one isolate hop, rather
/// than one `compute()` call (one isolate spawn) per category — see
/// `_restoreXtreamCache`.
List<MapEntry<String, List<Channel>>> _decodeChannelsJsonBatch(
  (Map<String, String> rawByName, Set<String> favoriteIds) input,
) {
  final (rawByName, favoriteIds) = input;
  return rawByName.entries.map((entry) {
    final items =
        (jsonDecode(entry.value) as List).map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();
    for (final channel in items) {
      channel.isFavorite = favoriteIds.contains(channel.id);
    }
    return MapEntry(entry.key, items);
  }).toList();
}

/// Series counterpart to [_decodeChannelsJsonBatch].
List<MapEntry<String, List<XtreamSeries>>> _decodeSeriesJsonBatch(
  (Map<String, String> rawByName, Set<String> favoriteIds) input,
) {
  final (rawByName, favoriteIds) = input;
  return rawByName.entries.map((entry) {
    final items = (jsonDecode(entry.value) as List)
        .map((e) => XtreamSeries.fromJson(e as Map<String, dynamic>))
        .toList();
    for (final series in items) {
      series.isFavorite = favoriteIds.contains(series.seriesId.toString());
    }
    return MapEntry(entry.key, items);
  }).toList();
}
