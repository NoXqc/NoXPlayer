import 'package:flutter/foundation.dart';

import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/playlist_profile.dart';
import '../models/xtream_series.dart';
import 'catalog_database.dart';
import 'playlist_session.dart';
import 'storage_service.dart';

/// Holds every playlist's parsed catalog, group visibility, and the
/// (globally shared) favorites — a thin merge/dispatch layer over a
/// `List<PlaylistSession>`, one per `PlaylistProfile`. Until this version,
/// exactly one playlist could exist at all, and this class *was* the
/// single playlist's whole state; see `PlaylistSession` for where all of
/// that per-playlist logic (and its hard-won real-hardware bug-fix history)
/// actually lives now.
///
/// Two independent source modes per playlist:
/// - **M3U**: a flat [Channel] list parsed from a plain M3U URL, grouped
///   into tabs by keyword-matching the `group-title`.
/// - **Xtream**: talks to the real Xtream Codes API. See `PlaylistSession`
///   for the lazy-category-loading/background-warm-up shape both share.
class PlaylistManager extends ChangeNotifier {
  PlaylistManager(this._storage, this._catalogDb);

  final StorageService _storage;
  final CatalogDatabase _catalogDb;

  Set<String> _favoriteIds = {};
  Set<String> _favoriteSeriesIds = {};

  final List<PlaylistSession> _sessions = [];

  /// Whichever session a foreground operation (adding/editing/syncing one
  /// playlist) is currently running against — `CatalogSyncBody` and the
  /// back-compat single-session-shaped getters below all reflect this one
  /// session, not a merge across every playlist. Multiple playlists never
  /// load in the foreground simultaneously — the blocking "Updating
  /// Content" screen is mandatory for every playlist add/sync, first or
  /// not (see `AddPlaylistScreen`) — so there's only ever one meaningful
  /// answer to "what's loading right now" at the UI layer.
  PlaylistSession? _foregroundSession;

  /// True only during [init]'s very first pass, before any session exists
  /// yet to forward `isLoading` from — screens that check
  /// `playlist.isLoading` immediately after construction (e.g. the
  /// launch-time empty/loading-state check in `HomeScreen`) need this to
  /// read true from the very first frame, matching the old single-playlist
  /// behavior where `isLoading` was set synchronously before `init`'s
  /// first `await`.
  bool _initializing = false;

  // --- Back-compat single-session-shaped getters ----------------------------
  // Used by CatalogSyncBody/CatalogSyncScreen and anywhere else that shows
  // "the operation currently in the foreground", not a merge across every
  // playlist.
  bool get isLoading =>
      _initializing || (_foregroundSession?.isLoading ?? false);
  String? get error => _foregroundSession?.error;
  DateTime? get lastLoaded => _foregroundSession?.lastLoaded;
  String? get loadingPhase => _foregroundSession?.loadingPhase;
  Map<String, int>? get lastLoadSummary => _foregroundSession?.lastLoadSummary;
  bool get isWarmingCatalog => _foregroundSession?.isWarmingCatalog ?? false;
  int get warmCatalogDone => _foregroundSession?.warmCatalogDone ?? 0;
  int get warmCatalogTotal => _foregroundSession?.warmCatalogTotal ?? 0;
  int get vodCatalogDone => _foregroundSession?.vodCatalogDone ?? 0;
  int get vodCatalogTotal => _foregroundSession?.vodCatalogTotal ?? 0;
  int get seriesCatalogDone => _foregroundSession?.seriesCatalogDone ?? 0;
  int get seriesCatalogTotal => _foregroundSession?.seriesCatalogTotal ?? 0;

  List<PlaylistProfile> get profiles => _sessions.map((s) => s.profile).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<PlaylistSession> get _enabledSessionsSorted =>
      _sessions.where((s) => s.profile.enabled).toList()
        ..sort((a, b) => a.profile.sortOrder.compareTo(b.profile.sortOrder));

  PlaylistSession? _sessionFor(String playlistId) {
    for (final s in _sessions) {
      if (s.profile.id == playlistId) return s;
    }
    return null;
  }

  /// Whether this specific playlist is enabled — used by `PlaybackService`
  /// to block playback for a disabled playlist's channels, the per-channel
  /// replacement for what used to be one global "playlist enabled" toggle
  /// (`AppPreferences.playlistEnabled`) before multi-playlist support.
  bool isPlaylistEnabled(String playlistId) =>
      _sessionFor(playlistId)?.profile.enabled ?? false;

  /// True if any *enabled* playlist is Xtream mode — gates Xtream-only UI
  /// (the TV Shows tab, Full Catalog Sync, etc.). With a mixed M3U +
  /// Xtream setup, that UI shows up because at least one playlist can use
  /// it; per-playlist screens (Group Management, Playlist Manager's detail
  /// panel) check `PlaylistProfile.isXtream` directly instead.
  bool get isXtream => _enabledSessionsSorted.any((s) => s.isXtream);

  // --- Init / migration -----------------------------------------------------

  Future<void> init() async {
    // Set synchronously, before the first `await` — matches the old
    // single-playlist behavior where whatever's on screen the instant it
    // renders needs to already read "loading", not a flash of "no
    // channels found" from a still-empty, not-yet-started PlaylistManager.
    _initializing = true;
    notifyListeners();
    try {
      await _migrateLegacySinglePlaylist();

      _sessions
        ..clear()
        ..addAll(_storage.getPlaylists().map((profile) => PlaylistSession(
              profile: profile,
              storage: _storage,
              catalogDb: _catalogDb,
              favoriteIds: () => _favoriteIds,
              favoriteSeriesIds: () => _favoriteSeriesIds,
              onNotify: notifyListeners,
            )));

      _favoriteIds = _storage.getFavorites();
      _favoriteSeriesIds = _storage.getFavoriteSeries();

      notifyListeners();
      // Every enabled playlist restores (from its own cache, or a fresh
      // network load if there's none yet) in parallel — each one notifies
      // independently via its own `onNotify`, so the UI fills in
      // playlist-by-playlist rather than waiting for the slowest one.
      await Future.wait(_enabledSessionsSorted.map((s) => s.restoreOrLoad()));
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  /// Manual "Retry" action for the connection-failed empty state (Live TV,
  /// Movies/TV Shows). Only re-runs sessions that are actually in an error
  /// state — not every enabled playlist — so this can't turn into the same
  /// "hammer the server with more requests than it wants" problem
  /// `XtreamApiService.maxConnections` was added to prevent for the
  /// concurrent-category-fetch path; a manual, user-initiated single retry
  /// is a different, much smaller thing than that was.
  Future<void> retryFailedConnections() => Future.wait(_enabledSessionsSorted
      .where((s) => s.error != null)
      .map((s) => s.restoreOrLoad()));

  /// Upgrading from the pre-multi-playlist version: the old single set of
  /// global scalar prefs (server/username/password, hidden/favorited
  /// groups, sync frequency) becomes one `PlaylistProfile` under a fixed,
  /// traceable id (`'migrated_default'`) rather than a random one — so
  /// support/logs can recognize it. Guarded so this only ever runs once.
  Future<void> _migrateLegacySinglePlaylist() async {
    if (_storage.getMigratedToMultiPlaylist()) return;
    if (_storage.getPlaylists().isNotEmpty) {
      // Fresh install of a version that already has multi-playlist
      // support — nothing to migrate, but still guard so this check
      // itself doesn't run on every future launch.
      await _storage.setMigratedToMultiPlaylist(true);
      return;
    }

    const migratedId = 'migrated_default';
    final mode = _storage.getLegacyPlaylistMode();
    final m3uUrl = _storage.getLegacyM3uUrl();
    final xtreamServer = _storage.getLegacyXtreamServer();
    final hasLegacyPlaylist =
        (mode == 'xtream' && xtreamServer != null && xtreamServer.isNotEmpty) ||
            (mode == 'm3u' && m3uUrl != null && m3uUrl.isNotEmpty);

    if (hasLegacyPlaylist) {
      final profile = PlaylistProfile(
        id: migratedId,
        name: 'My Playlist',
        mode: mode,
        m3uUrl: m3uUrl,
        epgUrl: _storage.getLegacyEpgUrl(),
        xtreamServer: xtreamServer,
        xtreamUsername: _storage.getLegacyXtreamUsername(),
        xtreamPassword: _storage.getLegacyXtreamPassword(),
        enabled: _storage.getLegacyPlaylistEnabled(),
        sortOrder: 0,
        syncFrequencyDays: _storage.getLegacySyncFrequencyDays(),
        createdAt: DateTime.now(),
      );
      await _storage.setPlaylists([profile]);
      await _storage.setHiddenGroups(
          migratedId, _storage.getLegacyHiddenGroups());
      await _storage.setFavoritedGroups(
          migratedId, _storage.getLegacyFavoritedGroups());
      final legacyLastSync = _storage.getLegacyLastFullSyncAt();
      if (legacyLastSync != null) {
        await _storage.setLastFullSyncAt(migratedId, legacyLastSync);
      }

      // Existing favorite ids were saved before id-prefixing existed —
      // rewrite them to the new '$playlistId::$rawId' shape (see
      // Channel.playlistId's doc comment) or they'd silently stop
      // matching anything post-migration. This is the single most
      // failure-prone step in the whole migration; a bug here would
      // silently drop a user's favorites with no visible error.
      final oldFavorites = _storage.getFavorites();
      await _storage
          .setFavorites(oldFavorites.map((id) => '$migratedId::$id').toSet());
      final oldSeriesFavorites = _storage.getFavoriteSeries();
      await _storage.setFavoriteSeries(
          oldSeriesFavorites.map((id) => '$migratedId::series_$id').toSet());
    }

    await _storage.setMigratedToMultiPlaylist(true);
  }

  // --- Add / update / remove / enable ---------------------------------------

  Future<void> addPlaylist(PlaylistProfile profile) async {
    final updated = [..._storage.getPlaylists(), profile];
    await _storage.setPlaylists(updated);
    _sessions.add(PlaylistSession(
      profile: profile,
      storage: _storage,
      catalogDb: _catalogDb,
      favoriteIds: () => _favoriteIds,
      favoriteSeriesIds: () => _favoriteSeriesIds,
      onNotify: notifyListeners,
    ));
    notifyListeners();
  }

  Future<void> updatePlaylist(PlaylistProfile profile) async {
    final updated = _storage
        .getPlaylists()
        .map((p) => p.id == profile.id ? profile : p)
        .toList();
    await _storage.setPlaylists(updated);
    final session = _sessionFor(profile.id);
    if (session != null) session.profile = profile;
    notifyListeners();
  }

  Future<void> removePlaylist(String playlistId) async {
    final updated =
        _storage.getPlaylists().where((p) => p.id != playlistId).toList();
    await _storage.setPlaylists(updated);
    _sessions.removeWhere((s) => s.profile.id == playlistId);
    await _catalogDb.clearForPlaylist(playlistId);
    if (_foregroundSession?.profile.id == playlistId) _foregroundSession = null;
    notifyListeners();
  }

  Future<void> setPlaylistEnabled(String playlistId, bool enabled) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    session.profile = session.profile.copyWith(enabled: enabled);
    await updatePlaylist(session.profile);
    if (enabled && session.channels.isEmpty && session.liveChannels.isEmpty) {
      await session.restoreOrLoad();
    }
    notifyListeners();
  }

  /// Runs this playlist's fresh network load (Xtream login or M3U fetch),
  /// showing the blocking "Updating Content" screen the whole time — used
  /// by both a brand-new playlist's first add and re-saving an existing
  /// one's edited login details. Sets [_foregroundSession] so
  /// `CatalogSyncBody`'s progress fields reflect this specific playlist.
  Future<void> loadPlaylist(String playlistId) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    _foregroundSession = session;
    if (session.isXtream) {
      await session.loadFromXtream();
    } else {
      final url = session.profile.m3uUrl;
      if (url != null && url.isNotEmpty) await session.loadFromUrl(url);
    }
    notifyListeners();
  }

  // --- Merged catalog getters ------------------------------------------------

  /// Live-browsable channels for every enabled playlist — `liveChannels`
  /// for an Xtream session, the flat M3U list for an M3U one (M3U mode has
  /// no separate live/VOD/series storage split, unlike Xtream).
  List<Channel> get channels => _enabledSessionsSorted
      .expand((s) => s.isXtream ? s.liveChannels : s.channels)
      .toList();

  List<Channel> get allCachedVod =>
      _enabledSessionsSorted.expand((s) => s.allCachedVod).toList();
  List<XtreamSeries> get allCachedSeries =>
      _enabledSessionsSorted.expand((s) => s.allCachedSeries).toList();

  List<M3uGroup> get tvGroups =>
      _enabledSessionsSorted.expand((s) => s.tvGroups).toList();
  List<M3uGroup> get vodGroups =>
      _enabledSessionsSorted.expand((s) => s.vodGroups).toList();
  List<M3uGroup> get seriesGroups =>
      _enabledSessionsSorted.expand((s) => s.seriesGroups).toList();

  int? vodCategoryTotalCount(String playlistId, String categoryName) =>
      _sessionFor(playlistId)?.vodCategoryTotalCountFor(categoryName);
  int? seriesCategoryTotalCount(String playlistId, String categoryName) =>
      _sessionFor(playlistId)?.seriesCategoryTotalCountFor(categoryName);

  /// The most recently-added movies across every enabled playlist — the TV
  /// layout's "What's New" carousel. Xtream-only by nature: an M3U playlist
  /// carries no "when did this show up" data at all (see `Channel.addedAt`),
  /// so its rows have nothing to sort by and are left out entirely rather
  /// than appearing in an arbitrary order.
  ///
  /// Reads whatever the catalog database already holds — the existing full
  /// sync/on-demand category loads are what put it there. Before any of
  /// that has run, this is simply empty (an empty carousel, never an error).
  Future<List<Channel>> whatsNewVod({int limit = 5}) =>
      _catalogDb.getRecentlyAddedVod(_enabledXtreamPlaylistIds, limit: limit);

  Future<List<XtreamSeries>> whatsNewSeries({int limit = 5}) =>
      _catalogDb.getRecentlyAddedSeries(_enabledXtreamPlaylistIds,
          limit: limit);

  List<String> get _enabledXtreamPlaylistIds => _enabledSessionsSorted
      .where((s) => s.isXtream)
      .map((s) => s.profile.id)
      .toList();

  Map<String, int>? summaryFor(String playlistId) =>
      _sessionFor(playlistId)?.lastLoadSummary;
  DateTime? lastLoadedFor(String playlistId) =>
      _sessionFor(playlistId)?.lastLoaded;

  /// This playlist's own display name — used by the merged group columns
  /// to label a divider row wherever two playlists' groups meet, so it's
  /// clear which playlist the groups below it belong to. Empty string
  /// (not null) if the playlist's since been removed out from under a
  /// still-rendering frame, so a stale divider reads as blank rather than
  /// throwing.
  String playlistNameFor(String playlistId) =>
      _sessionFor(playlistId)?.profile.name ?? '';

  bool isGroupFavorited(String playlistId, String title) =>
      _sessionFor(playlistId)?.isGroupFavorited(title) ?? false;

  Set<String> hiddenGroupsFor(String playlistId) =>
      _sessionFor(playlistId)?.hiddenGroups ?? {};
  Set<String> favoritedGroupsFor(String playlistId) =>
      _sessionFor(playlistId)?.favoritedGroups ?? {};

  /// Every whole-favorited group's title across every enabled playlist —
  /// used by the sidebar's own "Favourites" group-title list. Same-named
  /// groups from two different playlists collapse into one entry here;
  /// an accepted, minor edge case (this feeds a display-only title list,
  /// not the actual channel lookup, which stays correctly scoped per
  /// playlist via `visibleChannels`).
  Set<String> get allFavoritedGroupTitles =>
      _enabledSessionsSorted.expand((s) => s.favoritedGroups).toSet();

  Future<void> ensureCategoryLoaded(
          String playlistId, String categoryName, String tabCategory) =>
      _sessionFor(playlistId)
          ?.ensureCategoryLoaded(categoryName, tabCategory) ??
      Future.value();

  Future<void> ensureCategoriesLoaded(String playlistId,
          Iterable<String> categoryNames, String tabCategory) =>
      _sessionFor(playlistId)
          ?.ensureCategoriesLoaded(categoryNames, tabCategory) ??
      Future.value();

  List<Channel> visibleChannels(
      {String? playlistId, String? groupTitle, required String category}) {
    if (playlistId != null) {
      return _sessionFor(playlistId)
              ?.visibleChannels(groupTitle: groupTitle, category: category) ??
          const [];
    }
    return _enabledSessionsSorted
        .expand((s) =>
            s.visibleChannels(groupTitle: groupTitle, category: category))
        .toList();
  }

  List<XtreamSeries> visibleSeries({String? playlistId, String? categoryName}) {
    if (playlistId != null)
      return _sessionFor(playlistId)?.visibleSeries(categoryName) ?? const [];
    return _enabledSessionsSorted
        .expand((s) => s.visibleSeries(categoryName))
        .toList();
  }

  /// Every id this one playlist could plausibly have EPG data for — feeds
  /// `EpgService`'s per-playlist `knownChannelIds` filter (see that
  /// class's doc comment on why an unfiltered multi-provider EPG source
  /// is a real OOM risk). Same `isXtream ? liveChannels : channels` split
  /// as the merged [channels] getter above, just scoped to one session.
  ///
  /// Must be `rawId` (the real `tvg-id`/`epg_channel_id`), not the
  /// composite `id` — an XMLTV feed's own `<programme channel="...">`
  /// attribute is always that raw value, never `$playlistId::$rawId`.
  /// Confirmed as a real regression: with `id` here, this filter never
  /// matched a single `<programme>` while parsing, so every channel
  /// showed "No program data" regardless of a real, successful EPG
  /// refresh — see `EpgGuide`'s callers for the matching display-side fix.
  Set<String> knownChannelIdsFor(String playlistId) {
    final session = _sessionFor(playlistId);
    if (session == null) return const {};
    return (session.isXtream ? session.liveChannels : session.channels)
        .map((c) => c.rawId)
        .toSet();
  }

  /// Ensures every enabled Xtream playlist's live channel list is loaded —
  /// see `PlaylistSession.ensureLiveChannelsLoaded`'s doc comment for why
  /// this is lazy per playlist. Safe to call unconditionally on every
  /// build; no-ops for anything already loaded.
  Future<void> ensureLiveChannelsLoaded() => Future.wait(
      _enabledSessionsSorted.map((s) => s.ensureLiveChannelsLoaded()));

  // --- Favorites (global — shared across every playlist) --------------------

  List<Channel> get favoriteChannels => _enabledSessionsSorted
          .expand((s) =>
              s.isXtream ? [...s.liveChannels, ...s.allCachedVod] : s.channels)
          .where((c) {
        final favoritedGroups = _sessionFor(c.playlistId)?.favoritedGroups;
        return c.isFavorite || (favoritedGroups?.contains(c.group) ?? false);
      }).toList();

  List<Channel> get favoriteLiveChannels => _enabledSessionsSorted
      .expand((s) => s.isXtream
          ? s.liveChannels.where((c) => c.isFavorite)
          : s.channels.where(
              (c) => c.isFavorite && _classifyGroupPublic(c.group) == 'tv'))
      .toList();

  List<Channel> get favoriteMovies => _enabledSessionsSorted
      .expand((s) => (s.isXtream
          ? s.allCachedVod
          : s.channels.where((c) => _classifyGroupPublic(c.group) == 'vod')))
      .where((c) => c.isFavorite)
      .toList();

  List<XtreamSeries> get favoriteSeries => _enabledSessionsSorted
      .where((s) => s.isXtream)
      .expand((s) => s.allCachedSeries)
      .where((s) => s.isFavorite)
      .toList();

  List<Channel> get favoriteShowChannels => _enabledSessionsSorted
      .where((s) => !s.isXtream)
      .expand((s) => s.channels)
      .where((c) => c.isFavorite && _classifyGroupPublic(c.group) == 'series')
      .toList();

  /// Same classification `PlaylistSession._classifyGroup` uses — needed
  /// here too since the merged favorite getters above operate across
  /// sessions, not from inside one.
  String _classifyGroupPublic(String title) {
    final lower = title.toLowerCase();
    if (lower.contains('series') || lower.contains('show')) return 'series';
    if (lower.contains('vod') || lower.contains('movie')) return 'vod';
    return 'tv';
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

  bool isSeriesFavorited(String seriesId) =>
      _favoriteSeriesIds.contains(seriesId);

  Future<void> toggleSeriesFavorite(XtreamSeries series) async {
    series.isFavorite = !series.isFavorite;
    if (series.isFavorite) {
      _favoriteSeriesIds.add(series.id);
    } else {
      _favoriteSeriesIds.remove(series.id);
    }
    await _storage.setFavoriteSeries(_favoriteSeriesIds);
    await _catalogDb.setSeriesFavorite(series.id, series.isFavorite);
    notifyListeners();
  }

  Future<void> toggleGroupHidden(String playlistId, String groupTitle) =>
      _sessionFor(playlistId)?.toggleGroupHidden(groupTitle) ?? Future.value();

  Future<void> setGroupHidden(String playlistId, String groupTitle, bool hidden,
          {bool loadImmediately = true}) =>
      _sessionFor(playlistId)?.setGroupHidden(groupTitle, hidden,
          loadImmediately: loadImmediately) ??
      Future.value();

  Future<void> setGroupsHidden(
          String playlistId, Iterable<String> groupTitles, bool hidden,
          {bool loadImmediately = true}) =>
      _sessionFor(playlistId)?.setGroupsHidden(groupTitles, hidden,
          loadImmediately: loadImmediately) ??
      Future.value();

  Future<void> setGroupFavorited(
          String playlistId, String title, bool favorited) =>
      _sessionFor(playlistId)?.setGroupFavorited(title, favorited) ??
      Future.value();

  // --- Full catalog sync ------------------------------------------------

  /// True if *any* enabled Xtream playlist is due for a full sync — see
  /// `PlaylistSession.needsFullSync`. main.dart checks this once at
  /// startup to decide whether to block behind [runFullCatalogSync].
  bool needsFullSync() => _enabledSessionsSorted.any((s) => s.needsFullSync());

  /// Runs every enabled Xtream playlist's full sync in turn (not in
  /// parallel — the blocking "Updating Content" screen shows one
  /// playlist's progress at a time via [_foregroundSession], which would
  /// be meaningless if several ran concurrently). Used by both the
  /// automatic launch-time sync (main.dart, gated by [needsFullSync]) and
  /// every manual "Update Content" trigger, which always re-syncs
  /// everything unconditionally rather than only what's technically stale.
  Future<void> runFullCatalogSync() async {
    for (final session in _enabledSessionsSorted.where((s) => s.isXtream)) {
      _foregroundSession = session;
      notifyListeners();
      await session.runFullCatalogSync();
    }
  }

  Future<void> warmAllCategories(String playlistId) =>
      _sessionFor(playlistId)?.warmAllCategories() ?? Future.value();

  // --- Series / VOD detail --------------------------------------------------

  Future<({Map<int, List<Channel>> episodes, String? plot})> loadSeriesEpisodes(
      XtreamSeries series) {
    final session = _sessionFor(series.playlistId);
    if (session == null)
      return Future.value((episodes: <int, List<Channel>>{}, plot: null));
    return session.loadSeriesEpisodes(series);
  }

  /// Movie plot/description, fetched on demand when [MovieDetailScreen]
  /// opens for one title. [channel.rawId] still carries its `xt_vod_`
  /// prefix (see `Channel.rawId`'s doc comment) — stripped here before
  /// the raw stream id reaches the API call.
  Future<String?> getVodDescription(Channel channel) async {
    final session = _sessionFor(channel.playlistId);
    if (session == null) return null;
    final rawStreamId = channel.rawId.replaceFirst('xt_vod_', '');
    return session.getVodDescription(rawStreamId);
  }
}
