import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/playlist_profile.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';
import '../utils/constants.dart';
import 'catalog_database.dart';
import 'm3u_parser.dart';
import 'storage_service.dart';
import 'xtream_api_service.dart';

/// One playlist's own load/cache state — extracted from what used to be
/// `PlaylistManager`'s entire body, back when only one playlist could
/// exist. `PlaylistManager` now holds a `List<PlaylistSession>` (one per
/// `PlaylistProfile`) and is a thin merge/dispatch layer over these; every
/// doc comment on the methods below explaining a hard-won real-hardware
/// bug fix (worker-pool starvation, failure backoff, throttled warm-up
/// notifications, the debug-mode-assertion-caught notifyListeners-during-
/// build bug, ...) is unchanged from the original single-playlist code —
/// none of that logic changed, it just now runs once per playlist instead
/// of once globally.
class PlaylistSession {
  PlaylistSession({
    required this.profile,
    required this.storage,
    required this.catalogDb,
    required this.favoriteIds,
    required this.favoriteSeriesIds,
    required this.onNotify,
  });

  PlaylistProfile profile;
  final StorageService storage;
  final CatalogDatabase catalogDb;

  /// Read-only access to `PlaylistManager`'s global favorite id sets —
  /// favorites stay shared across every playlist (unlike hidden/favorited
  /// *groups*, which are per-playlist), so this session only ever reads
  /// them (to stamp `isFavorite` while loading), never owns or writes them.
  final Set<String> Function() favoriteIds;
  final Set<String> Function() favoriteSeriesIds;

  /// Forwards to the owning `PlaylistManager`'s own `notifyListeners()` —
  /// screens listen to that single `ChangeNotifier`, not to this session
  /// directly.
  final VoidCallback onNotify;

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

  Set<String> hiddenGroups = {};
  Set<String> favoritedGroups = {};

  // --- M3U-mode state ---------------------------------------------------
  List<Channel> channels = [];

  // --- Xtream-mode state --------------------------------------------------
  XtreamApiService? xtreamApi;
  List<Channel> liveChannels = [];
  List<XtreamCategory> liveCategories = [];
  List<XtreamCategory> vodCategories = [];
  List<XtreamCategory> seriesCategories = [];
  final Map<String, String> vodCategoryIdByName = {};
  final Map<String, String> seriesCategoryIdByName = {};
  final Map<String, List<Channel>> vodByCategoryName = {};
  final Map<String, List<XtreamSeries>> seriesByCategoryName = {};
  // A category's true item count, independent of _maxItemsPerCategory's
  // display cap — the full set is always fetched from the network and
  // saved to the database (see _persistVodCategory/_persistSeriesCategory)
  // regardless of the cap, but vodByCategoryName/seriesByCategoryName
  // themselves only ever hold up to the cap, so there was previously no
  // way for the UI to show a category's real size. See
  // vodCategoryTotalCount/seriesCategoryTotalCount.
  final Map<String, int> vodCategoryTotalCount = {};
  final Map<String, int> seriesCategoryTotalCount = {};
  final Set<String> loadingCategoryNames = {};
  // Which tab category ('vod'/'series') currently has a self-sustaining
  // ensureCategoriesLoaded worker pool running — see that method's doc
  // comment for the bug this exists to fix (a rebuild-dependent design
  // that could silently stall for minutes once the browse screen simply
  // stopped being rebuilt).
  final Set<String> categoriesLoadingActive = {};

  /// How many times each category (keyed the same way as
  /// [loadingCategoryNames]) has failed to load this session. Confirmed
  /// on real hardware as a genuine, previously-missing safety net: without
  /// this, a category that fails (e.g. HTTP 403 from exceeding the
  /// account's own connection limit — see [_categoryConcurrency]) got
  /// retried again on every single widget rebuild forever, hammering the
  /// server with rejected requests indefinitely for the rest of the
  /// session. [_maxCategoryFailures] failures and it's left alone until
  /// an explicit force refresh (manual "Update Content") clears this.
  final Map<String, int> categoryFailureCounts = {};
  static const int _maxCategoryFailures = 2;

  /// Caps how many items of a single category are held in memory/rendered
  /// at once — even with a real on-disk database, a single oversized
  /// category (some providers bundle thousands of items under one
  /// "24/7"-style category) can still be enough to strain a
  /// memory-constrained device by itself, since the whole category is
  /// still materialized into Dart objects the moment it's opened. This is
  /// a blunt cap (silently truncates), not real pagination (load-more-on-
  /// scroll) — a full pagination UI is a bigger follow-up; this at least
  /// puts a ceiling on the worst case. The *database* still stores the
  /// full category, so raising this cap later doesn't need a re-fetch
  /// from the network.
  static const int _maxItemsPerCategory = 300;

  bool get isXtream => profile.isXtream;

  /// How many categories to fetch concurrently — capped at the account's
  /// own `max_connections` (from [XtreamApiService.authenticate]) when
  /// known, since firing more concurrent requests than an account allows
  /// gets the extras rejected outright rather than queued. Falls back to
  /// 3 (the concurrency level already confirmed safe/fast on accounts
  /// without a tight limit) when the account didn't report one.
  int get _categoryConcurrency {
    final accountLimit = xtreamApi?.maxConnections;
    return accountLimit == null ? 3 : accountLimit.clamp(1, 3);
  }

  /// The in-flight (or completed) [ensureLiveChannelsLoaded] load, shared
  /// across every caller — see that method's doc comment for why this
  /// needs to be a shared Future rather than a plain boolean guard.
  Future<void>? liveChannelsFuture;

  bool isGroupFavorited(String title) => favoritedGroups.contains(title);

  /// Every cache file this playlist owns is namespaced by its profile id
  /// — the whole reason a second playlist's cache can't collide with the
  /// first's (or, on upgrade, why a pre-multi-playlist cache file is never
  /// looked up again under its new suffixed name — see
  /// `Channel.fromJson`'s doc comment).
  String _cacheName(String base) => '${base}_${profile.id}';

  List<Channel> get allCachedVod =>
      vodByCategoryName.values.expand((l) => l).toList();
  List<XtreamSeries> get allCachedSeries =>
      seriesByCategoryName.values.expand((l) => l).toList();

  int? vodCategoryTotalCountFor(String categoryName) =>
      vodCategoryTotalCount[categoryName];
  int? seriesCategoryTotalCountFor(String categoryName) =>
      seriesCategoryTotalCount[categoryName];

  // --- Startup: restore from cache, or do a fresh load ---------------------

  /// Restores this playlist from its on-disk cache, or does a fresh
  /// network load if there's no cache yet. Returns once *something* is
  /// showable (cache hit or fresh load finished/failed).
  Future<void> restoreOrLoad() async {
    hiddenGroups = storage.getHiddenGroups(profile.id);
    favoritedGroups = storage.getFavoritedGroups(profile.id);

    if (isXtream) {
      final username = profile.xtreamUsername;
      final password = profile.xtreamPassword;
      // Whatever answered last time, not necessarily the configured
      // primary — a cache hit skips the authenticating connect below
      // entirely, so this is the server every on-demand category fetch
      // for the rest of the session would otherwise be pointed at.
      final server = profile.serverCandidates.firstOrNull;
      if (server == null ||
          server.isEmpty ||
          username == null ||
          password == null) return;
      xtreamApi = XtreamApiService(
          server: server,
          username: username,
          password: password,
          playlistId: profile.id);
      if (await _restoreXtreamCache()) return;
      await loadFromXtream();
      return;
    }

    final url = profile.m3uUrl;
    if (url == null || url.isEmpty) return;
    if (await _restoreM3uCache()) return;
    await loadFromUrl(url);
  }

  // --- M3U mode -----------------------------------------------------------

  Future<bool> _restoreM3uCache() async {
    // Read, decode and parse all on a background isolate — this used to do
    // the lot on the main thread, for a list that can run to tens of
    // thousands of channels. See StorageService.cacheFilePath.
    final path = await storage
        .cacheFilePath(_cacheName(AppConstants.cacheFileM3uChannels));
    if (path == null) return false;
    try {
      final loaded = await compute(_readChannelsFile, path);
      for (final channel in loaded) {
        channel.isFavorite = favoriteIds().contains(channel.id);
      }
      channels = loaded;
      return true;
    } catch (e) {
      debugPrint(
          'PlaylistSession[${profile.id}]: failed to restore M3U cache: $e');
      return false;
    }
  }

  Future<void> loadFromUrl(String url) async {
    isLoading = true;
    error = null;
    lastLoadSummary = null;
    loadingPhase = 'Connecting to server...';
    onNotify();

    try {
      final parsed = await M3uParser.fetchAndParse(url, playlistId: profile.id);
      for (final channel in parsed) {
        channel.isFavorite = favoriteIds().contains(channel.id);
      }

      final counts = <String, int>{'tv': 0, 'vod': 0, 'series': 0};
      for (final channel in parsed) {
        final category = _classifyGroup(channel.group);
        counts[category] = (counts[category] ?? 0) + 1;
      }

      // Brief staged reveal so the counts are readable, rather than flashing
      // by instantly — the parsing above is already done at this point.
      loadingPhase = 'Finding live channels... (${counts['tv']} found)';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding movies... (${counts['vod']} found)';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding TV shows... (${counts['series']} found)';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 400));

      channels = parsed;
      lastLoadSummary = counts;
      lastLoaded = DateTime.now();
      profile = profile.copyWith(m3uUrl: url);
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileM3uChannels),
        await compute(_encodeJsonList, parsed.map((c) => c.toJson()).toList()),
      );

      loadingPhase = 'Playlist added';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistSession[${profile.id}] error: $e');
    } finally {
      isLoading = false;
      loadingPhase = null;
      onNotify();
    }
  }

  /// All groups, in first-seen order, including hidden ones (used by the
  /// Group Management screen). M3U mode only.
  List<M3uGroup> get allGroups {
    final order = <String>[];
    final byTitle = <String, List<Channel>>{};
    for (final channel in channels) {
      byTitle.putIfAbsent(channel.group, () => []).add(channel);
      if (!order.contains(channel.group)) order.add(channel.group);
    }
    return order
        .map((title) => M3uGroup(
              title: title,
              playlistId: profile.id,
              channels: byTitle[title]!,
              isHidden: hiddenGroups.contains(title),
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

  Future<void> _persistVodCategory(String categoryName, List<Channel> items) =>
      catalogDb.upsertVodCategory(profile.id, categoryName, items);

  Future<void> _persistSeriesCategory(
          String categoryName, List<XtreamSeries> items) =>
      catalogDb.upsertSeriesCategory(profile.id, categoryName, items);

  Future<bool> _restoreXtreamCache() async {
    try {
      final liveCatRaw = await storage
          .readCacheFile(_cacheName(AppConstants.cacheFileLiveCategories));
      final vodCatRaw = await storage
          .readCacheFile(_cacheName(AppConstants.cacheFileVodCategories));
      final seriesCatRaw = await storage
          .readCacheFile(_cacheName(AppConstants.cacheFileSeriesCategories));
      if (liveCatRaw == null || vodCatRaw == null || seriesCatRaw == null) {
        return false;
      }

      final decoded = await compute(
        _decodeXtreamCategoriesBatch,
        _XtreamCategoriesRaw(
            liveCatRaw: liveCatRaw,
            vodCatRaw: vodCatRaw,
            seriesCatRaw: seriesCatRaw),
      );
      liveCategories = decoded.liveCategories;
      vodCategories = decoded.vodCategories;
      seriesCategories = decoded.seriesCategories;

      vodCategoryIdByName
        ..clear()
        ..addEntries(vodCategories.map((c) => MapEntry(c.name, c.id)));
      seriesCategoryIdByName
        ..clear()
        ..addEntries(seriesCategories.map((c) => MapEntry(c.name, c.id)));

      // Deliberately NOT restoring every cached category's items into
      // memory here — vodByCategoryName/seriesByCategoryName simply start
      // empty every launch, exactly like a fresh install;
      // ensureCategoryLoaded queries the local catalog database on demand
      // the moment a category is actually opened. See CatalogDatabase's
      // doc comment for the memory-capacity problem this avoids.

      lastLoadSummary = {
        'tv': liveChannels.length,
        'vod': vodCategories.length,
        'series': seriesCategories.length,
      };
      return true;
    } catch (e) {
      debugPrint(
          'PlaylistSession[${profile.id}]: failed to restore Xtream cache: $e');
      return false;
    }
  }

  /// Loads the live channel list on first need instead of eagerly on every
  /// launch. Callers: `TvHomeScreen`/`HomeScreen`'s Live TV and Favorites
  /// views, `SearchScreen`, and `main.dart`'s auto-resume-last-channel
  /// (which awaits this directly, since it needs the list before it can
  /// look anything up). No-ops once loaded — safe to call unconditionally
  /// from any of them on every build.
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
    if (!isXtream || liveChannels.isNotEmpty) return Future<void>.value();
    return liveChannelsFuture ??= _loadLiveChannelsOnce();
  }

  Future<void> _loadLiveChannelsOnce() async {
    // Deliberately doesn't touch the shared `isLoading` above (used to,
    // see git history — removed for a real, reported bug). This method
    // runs completely independently of `loadFromXtream`/`loadFromUrl` —
    // it's triggered by `ensureLiveChannelsLoaded`'s callers (TvHomeScreen/
    // HomeScreen/SearchScreen), which run on *every* enabled session any
    // time PlaylistManager notifies, not just whichever one is currently
    // the foreground add/edit/sync. Since AddPlaylistScreen is pushed *on
    // top of* TvHomeScreen (which stays mounted underneath, not disposed),
    // adding a playlist made `addPlaylist`'s own notifyListeners() trigger
    // TvHomeScreen's build-time `ensureLiveChannelsLoaded()` call for the
    // brand-new session too — racing this method against the real
    // `loadFromXtream()` on the very same session object. This method's
    // own early-return below (`xtreamApi` isn't set yet this early)
    // finished in milliseconds, and its `finally` stomped the shared
    // `isLoading` back to false while the real connect was still several
    // seconds from done — which is exactly what made the Add Playlist
    // status box "flash once, then show nothing" even though
    // `loadingPhase` (only ever written by the real load) kept updating
    // correctly the whole time underneath it.
    //
    // See TvHomeScreen._buildLiveRegion / PlaylistManager's original
    // single-playlist history: deferring a frame before the first
    // notifyListeners avoids firing one synchronously during a caller's
    // own build.
    await Future<void>.delayed(Duration.zero);
    onNotify();
    try {
      List<Channel> loaded;
      // Path, not contents — see StorageService.cacheFilePath.
      final path = await storage
          .cacheFilePath(_cacheName(AppConstants.cacheFileLiveChannels));
      if (path != null) {
        loaded = await compute(_readChannelsFile, path);
      } else {
        final api = xtreamApi;
        if (api == null) return;
        final categoryNames = {for (final c in liveCategories) c.id: c.name};
        loaded = await api.getLiveStreams(categoryNames: categoryNames);
        await storage.writeCacheFile(
          _cacheName(AppConstants.cacheFileLiveChannels),
          await compute(
              _encodeJsonList, loaded.map((c) => c.toJson()).toList()),
        );
      }
      for (final channel in loaded) {
        channel.isFavorite = favoriteIds().contains(channel.id);
      }
      liveChannels = loaded;
      lastLoadSummary = {...?lastLoadSummary, 'tv': liveChannels.length};
    } catch (e) {
      debugPrint(
          'PlaylistSession[${profile.id}]: failed to load live channels: $e');
      liveChannelsFuture = null; // allow a retry on the next access
    } finally {
      onNotify();
    }
  }

  /// How long to wait before trying the next server in the list. Only
  /// ever waited *between* attempts, never before the first or after the
  /// last — the point is to not machine-gun a provider's whole set of
  /// hostnames in the same instant, not to add latency for its own sake.
  static const _backupServerDelay = Duration(seconds: 3);

  /// Authenticates against [PlaylistProfile.serverCandidates] in order,
  /// returning the first one that answers. With no backups configured
  /// this is exactly the old single-server behaviour, message for
  /// message; the per-attempt reporting only appears once there's
  /// actually more than one server to talk about.
  ///
  /// A server that answers and *rejects* the account (bad credentials,
  /// expired/disabled subscription) stops the walk immediately instead of
  /// cycling through every backup — that server was reachable, so the
  /// problem follows the account to every other hostname too, and
  /// burying "your subscription expired" under a minute of fallback
  /// attempts helps nobody.
  Future<XtreamApiService> _connectWithFallback() async {
    final candidates = profile.serverCandidates;
    final username = profile.xtreamUsername!;
    final password = profile.xtreamPassword!;
    Object? lastError;

    for (var i = 0; i < candidates.length; i++) {
      final server = candidates[i];
      final label = _hostLabel(server);
      if (candidates.length > 1) {
        loadingPhase = 'Connecting to $label (${i + 1}/${candidates.length})...';
        onNotify();
      }
      final api = XtreamApiService(
          server: server,
          username: username,
          password: password,
          playlistId: profile.id);
      try {
        await api.authenticate();
        if (candidates.length > 1) {
          loadingPhase = 'Connected to $label';
          onNotify();
        }
        await _rememberWorkingServer(server);
        return api;
      } catch (e) {
        lastError = e;
        if (_isAccountRejection(e)) rethrow;
        if (candidates.length > 1) {
          loadingPhase = 'Connecting to $label (${i + 1}/'
              '${candidates.length})... failed';
          onNotify();
        }
        final hasMore = i < candidates.length - 1;
        if (hasMore) await Future<void>.delayed(_backupServerDelay);
      }
    }
    throw lastError ?? Exception('No server configured for this playlist');
  }

  /// Persisted so the next launch starts from whatever actually answered
  /// rather than re-walking a primary that's been down for days. Direct
  /// field assignment for the same reason [PlaylistProfile.expiresAt] uses
  /// one — see that field's doc comment.
  Future<void> _rememberWorkingServer(String server) async {
    if (profile.lastWorkingServer == server) return;
    profile.lastWorkingServer = server;
    final updated = storage
        .getPlaylists()
        .map((p) => p.id == profile.id ? profile : p)
        .toList();
    await storage.setPlaylists(updated);
  }

  Future<void> loadFromXtream() async {
    isLoading = true;
    error = null;
    lastLoadSummary = null;
    loadingPhase = 'Connecting to server...';
    onNotify();

    try {
      final api = await _connectWithFallback();
      xtreamApi = api;
      // Refreshed on every successful connect, not just once at add time —
      // a provider extending/changing an account's expiry should show
      // the current value on the next connect, not whatever it was when
      // this playlist was first added. See PlaylistProfile.expiresAt's
      // doc comment for why this can legitimately stay null.
      if (api.expiryDate != profile.expiresAt) {
        // Direct field assignment, not copyWith — expiresAt is mutable
        // for exactly this (like enabled/sortOrder elsewhere on this
        // class), and copyWith's `expiresAt ?? this.expiresAt` can't
        // distinguish "not specified" from "a provider stopped
        // reporting one," so it could never actually clear a stale value.
        profile.expiresAt = api.expiryDate;
        final updated = storage
            .getPlaylists()
            .map((p) => p.id == profile.id ? profile : p)
            .toList();
        await storage.setPlaylists(updated);
      }

      liveCategories = await api.getLiveCategories();
      final liveCategoryNames = {for (final c in liveCategories) c.id: c.name};
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileLiveCategories),
        await compute(
            _encodeJsonList, liveCategories.map((c) => c.toJson()).toList()),
      );

      loadingPhase = 'Finding live channels...';
      onNotify();
      final loadedLive =
          await api.getLiveStreams(categoryNames: liveCategoryNames);
      for (final channel in loadedLive) {
        channel.isFavorite = favoriteIds().contains(channel.id);
      }
      liveChannels = loadedLive;
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileLiveChannels),
        await compute(
            _encodeJsonList, loadedLive.map((c) => c.toJson()).toList()),
      );
      loadingPhase = 'Finding live channels... (${loadedLive.length} found)';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding movie categories...';
      onNotify();
      vodCategories = await api.getVodCategories();
      vodCategoryIdByName
        ..clear()
        ..addEntries(vodCategories.map((c) => MapEntry(c.name, c.id)));
      vodByCategoryName
          .removeWhere((name, _) => !vodCategoryIdByName.containsKey(name));
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileVodCategories),
        await compute(
            _encodeJsonList, vodCategories.map((c) => c.toJson()).toList()),
      );
      loadingPhase =
          'Finding movies... (${vodCategories.length} categories found)';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 400));

      loadingPhase = 'Finding TV show categories...';
      onNotify();
      seriesCategories = await api.getSeriesCategories();
      seriesCategoryIdByName
        ..clear()
        ..addEntries(seriesCategories.map((c) => MapEntry(c.name, c.id)));
      seriesByCategoryName
          .removeWhere((name, _) => !seriesCategoryIdByName.containsKey(name));
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileSeriesCategories),
        await compute(
            _encodeJsonList, seriesCategories.map((c) => c.toJson()).toList()),
      );
      loadingPhase =
          'Finding TV shows... (${seriesCategories.length} categories found)';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 400));

      lastLoadSummary = {
        'tv': loadedLive.length,
        'vod': vodCategories.length,
        'series': seriesCategories.length,
      };
      lastLoaded = DateTime.now();

      loadingPhase = 'Playlist added';
      onNotify();
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistSession[${profile.id}] error: $e');
    } finally {
      isLoading = false;
      loadingPhase = null;
      onNotify();
    }

    // Deliberately NOT auto-starting the catalog warm-up here — the caller
    // (AddPlaylistScreen) asks the user "download everything, or choose
    // groups first?" and starts it explicitly via [warmAllCategories] once
    // that's settled, so a "choose groups" pick actually takes effect
    // before any fetching begins rather than racing it.
  }

  /// Fetches a VOD or series category's items the first time it's opened,
  /// then caches them (in memory for the rest of the session, and to the
  /// local catalog database). No-ops for live (already loaded whole) and
  /// for categories already cached in memory this session.
  Future<void> ensureCategoryLoaded(
      String categoryName, String tabCategory) async {
    if (tabCategory == 'tv') return;
    if (tabCategory == 'vod' && vodByCategoryName.containsKey(categoryName))
      return;
    if (tabCategory == 'series' &&
        seriesByCategoryName.containsKey(categoryName)) return;
    final key = _loadKey(tabCategory, categoryName);
    if (loadingCategoryNames.contains(key)) return;
    if ((categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) return;

    loadingCategoryNames.add(key);
    isLoading = true;
    onNotify();

    try {
      if (tabCategory == 'vod') {
        final cached = await catalogDb.getVodCategory(profile.id, categoryName,
            limit: _maxItemsPerCategory);
        if (cached.isNotEmpty) {
          vodByCategoryName[categoryName] = cached;
          vodCategoryTotalCount[categoryName] =
              await catalogDb.getVodCategoryCount(profile.id, categoryName);
          return;
        }
        final api = xtreamApi;
        final categoryId = vodCategoryIdByName[categoryName];
        if (!isXtream || api == null || categoryId == null) return;
        final items = await api.getVodStreams(categoryId, categoryName);
        for (final channel in items) {
          channel.isFavorite = favoriteIds().contains(channel.id);
        }
        await _persistVodCategory(categoryName, items);
        vodByCategoryName[categoryName] =
            items.take(_maxItemsPerCategory).toList();
        vodCategoryTotalCount[categoryName] = items.length;
      } else {
        final cached = await catalogDb.getSeriesCategory(
            profile.id, categoryName,
            limit: _maxItemsPerCategory);
        if (cached.isNotEmpty) {
          seriesByCategoryName[categoryName] = cached;
          seriesCategoryTotalCount[categoryName] =
              await catalogDb.getSeriesCategoryCount(profile.id, categoryName);
          return;
        }
        final api = xtreamApi;
        final categoryId = seriesCategoryIdByName[categoryName];
        if (!isXtream || api == null || categoryId == null) return;
        final items = await api.getSeriesForCategory(categoryId);
        for (final series in items) {
          series.isFavorite = favoriteSeriesIds().contains(series.id);
        }
        await _persistSeriesCategory(categoryName, items);
        seriesByCategoryName[categoryName] =
            items.take(_maxItemsPerCategory).toList();
        seriesCategoryTotalCount[categoryName] = items.length;
      }
    } catch (e) {
      error = e.toString();
      debugPrint(
          'PlaylistSession[${profile.id}] CatLoad[$tabCategory] "$categoryName" FAILED: $e');
      categoryFailureCounts[key] = (categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      loadingCategoryNames.remove(key);
      isLoading = false;
      onNotify();
    }
  }

  String _loadKey(String tabCategory, String categoryName) =>
      '$tabCategory:$categoryName';

  /// Same first-load-on-demand behavior as [ensureCategoryLoaded], but for
  /// a whole browse screen's worth of categories at once, with a hard cap
  /// on how many load concurrently. A genuine self-sustaining worker pool
  /// ([categoriesLoadingActive] guards against starting a second one per
  /// tab while one's already running) — see the original single-playlist
  /// `PlaylistManager`'s history for why a rebuild-dependent "top up on
  /// each build" design isn't safe here (confirmed on real hardware: it
  /// could silently stall for 10+ seconds once nothing else happened to
  /// rebuild the screen).
  Future<void> ensureCategoriesLoaded(
      Iterable<String> categoryNames, String tabCategory) async {
    if (categoriesLoadingActive.contains(tabCategory)) return;
    final namesList = categoryNames.toList();
    if (namesList.isEmpty) return;

    categoriesLoadingActive.add(tabCategory);
    final maxConcurrent = _categoryConcurrency;
    try {
      final loadedMap =
          tabCategory == 'vod' ? vodByCategoryName : seriesByCategoryName;
      var index = 0;
      Future<void> worker() async {
        while (index < namesList.length) {
          final name = namesList[index++];
          final key = _loadKey(tabCategory, name);
          if (loadedMap.containsKey(name) ||
              (categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
            continue;
          }
          await ensureCategoryLoaded(name, tabCategory);
        }
      }

      await Future.wait(List.generate(
          maxConcurrent.clamp(1, namesList.length), (_) => worker()));
    } finally {
      categoriesLoadingActive.remove(tabCategory);
    }
  }

  Future<void> _loadOneVodCategory(XtreamApiService api, XtreamCategory cat,
      {bool force = false}) async {
    final key = _loadKey('vod', cat.name);
    if ((!force && vodByCategoryName.containsKey(cat.name)) ||
        loadingCategoryNames.contains(key) ||
        (categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
      return;
    }
    loadingCategoryNames.add(key);
    try {
      final items = await api.getVodStreams(cat.id, cat.name);
      for (final channel in items) {
        channel.isFavorite = favoriteIds().contains(channel.id);
      }
      await _persistVodCategory(cat.name, items);
      vodByCategoryName[cat.name] = items.take(_maxItemsPerCategory).toList();
      vodCategoryTotalCount[cat.name] = items.length;
    } catch (e) {
      debugPrint(
          'PlaylistSession[${profile.id}]: background load failed for movies "${cat.name}": $e');
      categoryFailureCounts[key] = (categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      loadingCategoryNames.remove(key);
    }
  }

  Future<void> _loadOneSeriesCategory(XtreamApiService api, XtreamCategory cat,
      {bool force = false}) async {
    final key = _loadKey('series', cat.name);
    if ((!force && seriesByCategoryName.containsKey(cat.name)) ||
        loadingCategoryNames.contains(key) ||
        (categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
      return;
    }
    loadingCategoryNames.add(key);
    try {
      final items = await api.getSeriesForCategory(cat.id);
      for (final series in items) {
        series.isFavorite = favoriteSeriesIds().contains(series.id);
      }
      await _persistSeriesCategory(cat.name, items);
      seriesByCategoryName[cat.name] =
          items.take(_maxItemsPerCategory).toList();
      seriesCategoryTotalCount[cat.name] = items.length;
    } catch (e) {
      debugPrint(
          'PlaylistSession[${profile.id}]: background load failed for TV shows "${cat.name}": $e');
      categoryFailureCounts[key] = (categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      loadingCategoryNames.remove(key);
    }
  }

  DateTime? _lastWarmupNotify;

  /// Notifying on every single category (up to 200+ times in a row) forces
  /// a full rebuild of whatever's on screen that many times in rapid
  /// succession — on weaker TV-box hardware that's enough rebuild pressure
  /// to make the UI thread choke badly enough to get killed. Progress at
  /// a few updates per second is visually indistinguishable from every
  /// single one, so throttle it; [force] still always notifies.
  void _notifyWarmupProgress({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastWarmupNotify != null &&
        now.difference(_lastWarmupNotify!) <
            const Duration(milliseconds: 400)) {
      return;
    }
    _lastWarmupNotify = now;
    onNotify();
  }

  /// Walks every VOD/series category that isn't cached yet and isn't
  /// hidden, one at a time, fetching its items in the background.
  Future<void> warmAllCategories() => _warmCategories(force: false);

  /// Re-fetches every non-hidden VOD/series category's items, including
  /// ones already cached — the "Update content" action.
  Future<void> refreshAllCategories() => _warmCategories(force: true);

  /// True when this playlist hasn't had a *full* sync (every non-hidden
  /// category's items, not just category names/live channels) recently
  /// enough.
  bool needsFullSync() {
    if (!isXtream) return false;
    final last = storage.getLastFullSyncAt(profile.id);
    if (last == null) return true;
    return DateTime.now().difference(last) >
        Duration(days: profile.syncFrequencyDays);
  }

  /// The blocking "Updating..." pass established players like TiviMate and
  /// MyTVOnline3 do a few times a week rather than on every launch.
  Future<void> runFullCatalogSync() async {
    if (!isXtream) return;
    await loadFromXtream();
    await refreshAllCategories();
  }

  Future<void> _warmCategories({required bool force}) async {
    if (isWarmingCatalog) return;

    final api = xtreamApi;
    if (api == null) return;

    if (force) categoryFailureCounts.clear();

    try {
      final vodTodo = vodCategories
          .where((c) =>
              (force || !vodByCategoryName.containsKey(c.name)) &&
              !hiddenGroups.contains(c.name))
          .toList();
      final seriesTodo = seriesCategories
          .where((c) =>
              (force || !seriesByCategoryName.containsKey(c.name)) &&
              !hiddenGroups.contains(c.name))
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
              vodTodo.isEmpty ? 0 : maxConcurrent.clamp(1, vodTodo.length),
              (_) => vodWorker()),
          ...List.generate(
              seriesTodo.isEmpty
                  ? 0
                  : maxConcurrent.clamp(1, seriesTodo.length),
              (_) => seriesWorker()),
        ]);
      }
      await storage.setLastFullSyncAt(profile.id, DateTime.now());
    } catch (e) {
      debugPrint('PlaylistSession[${profile.id}]: catalog warm-up failed: $e');
    } finally {
      isWarmingCatalog = false;
      _notifyWarmupProgress(force: true);
    }
  }

  /// Fetches episodes for one series, grouped by season number.
  Future<({Map<int, List<Channel>> episodes, String? plot})> loadSeriesEpisodes(
      XtreamSeries series) async {
    final api = xtreamApi;
    if (api == null) return (episodes: <int, List<Channel>>{}, plot: null);
    final result = await api.getSeriesEpisodes(series.seriesId, series.name);
    for (final list in result.episodes.values) {
      for (final channel in list) {
        channel.isFavorite = favoriteIds().contains(channel.id);
        channel.seriesId = series.seriesId;
        channel.seriesName = series.name;
        channel.seriesCoverUrl = series.coverUrl;
      }
    }
    return result;
  }

  /// Movie plot/description — [rawStreamId] is `Channel.rawId` with its
  /// `xt_vod_` prefix already stripped by the caller (`PlaylistManager
  /// .getVodDescription`).
  Future<String?> getVodDescription(String rawStreamId) async {
    final api = xtreamApi;
    if (api == null) return null;
    return api.getVodDescription(rawStreamId);
  }

  List<M3uGroup> get tvGroups {
    if (isXtream) {
      return liveCategories
          .map((c) => M3uGroup(
                title: c.name,
                playlistId: profile.id,
                channels: const [],
                isHidden: hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups.where((g) => _classifyGroup(g.title) == 'tv').toList();
  }

  List<M3uGroup> get vodGroups {
    if (isXtream) {
      return vodCategories
          .map((c) => M3uGroup(
                title: c.name,
                playlistId: profile.id,
                channels: vodByCategoryName[c.name] ?? const [],
                isHidden: hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups.where((g) => _classifyGroup(g.title) == 'vod').toList();
  }

  List<M3uGroup> get seriesGroups {
    if (isXtream) {
      return seriesCategories
          .map((c) => M3uGroup(
                title: c.name,
                playlistId: profile.id,
                channels: const [],
                isHidden: hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups.where((g) => _classifyGroup(g.title) == 'series').toList();
  }

  List<Channel> visibleChannels(
      {String? groupTitle, required String category}) {
    if (isXtream) {
      switch (category) {
        case 'tv':
          return groupTitle != null
              ? liveChannels.where((c) => c.group == groupTitle).toList()
              : liveChannels
                  .where((c) => !hiddenGroups.contains(c.group))
                  .toList();
        case 'vod':
          return groupTitle != null
              ? (vodByCategoryName[groupTitle] ?? const [])
              : vodByCategoryName.entries
                  .where((e) => !hiddenGroups.contains(e.key))
                  .expand((e) => e.value)
                  .toList();
        default:
          return const [];
      }
    }

    if (groupTitle != null) {
      return channels.where((c) => c.group == groupTitle).toList();
    }
    return channels
        .where((c) =>
            _classifyGroup(c.group) == category &&
            !hiddenGroups.contains(c.group))
        .toList();
  }

  List<XtreamSeries> visibleSeries(String? categoryName) {
    if (categoryName != null)
      return seriesByCategoryName[categoryName] ?? const [];
    return seriesByCategoryName.entries
        .where((e) => !hiddenGroups.contains(e.key))
        .expand((e) => e.value)
        .toList();
  }

  Future<void> setGroupFavorited(String title, bool favorited) async {
    if (favorited) {
      favoritedGroups.add(title);
    } else {
      favoritedGroups.remove(title);
    }
    await storage.setFavoritedGroups(profile.id, favoritedGroups);
    onNotify();
  }

  Future<void> toggleGroupHidden(String groupTitle) async {
    if (hiddenGroups.contains(groupTitle)) {
      hiddenGroups.remove(groupTitle);
    } else {
      hiddenGroups.add(groupTitle);
    }
    await storage.setHiddenGroups(profile.id, hiddenGroups);
    onNotify();
  }

  Future<void> setGroupHidden(String groupTitle, bool hidden,
      {bool loadImmediately = true}) async {
    if (hidden) {
      hiddenGroups.add(groupTitle);
    } else {
      hiddenGroups.remove(groupTitle);
    }
    await storage.setHiddenGroups(profile.id, hiddenGroups);
    onNotify();
    if (!hidden && loadImmediately) unawaited(_loadIfNewlyShown(groupTitle));
  }

  Future<void> setGroupsHidden(Iterable<String> groupTitles, bool hidden,
      {bool loadImmediately = true}) async {
    for (final title in groupTitles) {
      if (hidden) {
        hiddenGroups.add(title);
      } else {
        hiddenGroups.remove(title);
      }
    }
    await storage.setHiddenGroups(profile.id, hiddenGroups);
    onNotify();
    if (!hidden && loadImmediately) {
      for (final title in groupTitles) {
        unawaited(_loadIfNewlyShown(title));
      }
    }
  }

  Future<void> _loadIfNewlyShown(String groupTitle) async {
    if (!isXtream) return;
    if (vodCategoryIdByName.containsKey(groupTitle)) {
      await ensureCategoryLoaded(groupTitle, 'vod');
    } else if (seriesCategoryIdByName.containsKey(groupTitle)) {
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

_XtreamCategoriesDecoded _decodeXtreamCategoriesBatch(
    _XtreamCategoriesRaw raw) {
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

/// Isolate entry point: reads a cached channel list straight from disk, so
/// the file read and its UTF-8 decode happen off the main thread as well as
/// the JSON parse. See StorageService.cacheFilePath for why that matters.
List<Channel> _readChannelsFile(String path) =>
    _decodeLiveChannelsBatch(File(path).readAsStringSync());

List<Channel> _decodeLiveChannelsBatch(String raw) => (jsonDecode(raw) as List)
    .map((e) => Channel.fromJson(e as Map<String, dynamic>))
    .toList();

/// Off the main isolate, matching the read-side decode path above and
/// `XtreamApiService._getJson`'s own `compute(_decodeJsonBody, ...)`.
/// Reported directly, live: a large account's live-channel cache write
/// (confirmed on one real test account: 28,388 channels) froze the UI
/// thread long enough that the Add Playlist status box appeared to
/// "flash and go blank" for several real seconds — traced via timestamped
/// logging to a gap between `getLiveStreams()` returning (already
/// isolate-backgrounded) and the next status update, which is exactly
/// where the un-computed `jsonEncode(...)` for this cache write sat,
/// synchronously serializing the whole list on the UI isolate before the
/// file write itself could even start.
String _encodeJsonList(List<Map<String, dynamic>> maps) => jsonEncode(maps);

/// Just the hostname for status messages — a full `http://host:8080` in
/// "Connecting to ..." reads as noise on a TV across the room.
String _hostLabel(String server) {
  final host = Uri.tryParse(server)?.host ?? '';
  return host.isEmpty ? server : host;
}

/// True when a server answered and turned the *account* away, as opposed
/// to not answering at all. See `PlaylistSession._connectWithFallback`
/// for why those two cases can't be treated the same way: matched on
/// `XtreamApiService.authenticate`'s own thrown messages, which are the
/// only place these two states are distinguishable by the time they
/// reach here.
bool _isAccountRejection(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('invalid xtream username') ||
      text.contains('account is not active');
}
