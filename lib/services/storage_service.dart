import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/playlist_profile.dart';
import '../models/viewer_profile.dart';
import '../utils/constants.dart';

/// Wraps [SharedPreferences] for small settings values, and the OS temp
/// directory for larger cached payloads (parsed playlist/catalog JSON) —
/// multi-MB strings don't belong in SharedPreferences' XML-backed store,
/// and living under the temp dir means the OS can reclaim them under
/// storage pressure with no worse outcome than "re-fetch from network".
class StorageService {
  late SharedPreferences _prefs;
  Directory? _cacheDir;

  /// See the "Viewer-profile scoping" section below for what this drives.
  /// Loaded once at [init] and kept in memory rather than read from
  /// [_prefs] on every single per-viewer getter/setter — `ViewerProfileService
  /// .switchTo` updates this (via [setActiveViewerId]) and the persisted
  /// value together, in that order, before anything else reads a
  /// per-viewer key again, so there's never a window where the two disagree.
  String _activeViewerId = AppConstants.mainViewerId;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _activeViewerId = _prefs.getString(AppConstants.keyActiveViewerId) ??
        AppConstants.mainViewerId;
  }

  Future<Directory> _ensureCacheDir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/nox_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  // --- Generic on-disk JSON cache -----------------------------------------

  Future<void> writeCacheFile(String name, String content) async {
    final dir = await _ensureCacheDir();
    await File('${dir.path}/$name.json').writeAsString(content);
  }

  /// The path a cache file should be written to, creating the cache dir
  /// if needed — for a caller that streams its own content straight to
  /// disk (an [IOSink]) rather than building one full `String` and handing
  /// it to [writeCacheFile]. See `EpgService._persistCache`'s doc comment
  /// for why that distinction matters for a large payload.
  Future<String> cacheFilePathForWrite(String name) async {
    final dir = await _ensureCacheDir();
    return '${dir.path}/$name.json';
  }

  /// Path of a cache file if it exists, for callers that read *and*
  /// decode it on a background isolate. [readCacheFile] reads on the
  /// calling isolate, and `File.readAsString` does its whole UTF-8 decode
  /// there as one uninterrupted task — measured on real hardware as ~43%
  /// of the main thread's time across a cold start, because the big cache
  /// files (live channels, EPG) are tens of MB and channel names full of
  /// non-ASCII (superscript "ᴴᴰ", "ᴿᴬᵂ"...) force the slow two-byte decode
  /// path. With Dart now sharing Android's main thread, a remote key press
  /// that lands during one of those decodes can wait past Android's 5s
  /// input timeout and get the app killed as not responding. Handing the
  /// isolate a path instead also avoids copying the whole decoded string
  /// into it, which `compute(decode, rawString)` did on the main thread too.
  Future<String?> cacheFilePath(String name) async {
    final dir = await _ensureCacheDir();
    final file = File('${dir.path}/$name.json');
    return await file.exists() ? file.path : null;
  }

  Future<String?> readCacheFile(String name) async {
    final dir = await _ensureCacheDir();
    final file = File('${dir.path}/$name.json');
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteCacheFile(String name) async {
    final dir = await _ensureCacheDir();
    final file = File('${dir.path}/$name.json');
    if (await file.exists()) {
      await file.delete();
    }
  }

  // --- Multi-playlist list --------------------------------------------------

  List<PlaylistProfile> getPlaylists() {
    final raw = _prefs.getString(AppConstants.keyPlaylists);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => PlaylistProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setPlaylists(List<PlaylistProfile> playlists) =>
      _prefs.setString(AppConstants.keyPlaylists,
          jsonEncode(playlists.map((p) => p.toJson()).toList()));

  bool getMigratedToMultiPlaylist() =>
      _prefs.getBool(AppConstants.keyMigratedToMultiPlaylist) ?? false;
  Future<void> setMigratedToMultiPlaylist(bool value) =>
      _prefs.setBool(AppConstants.keyMigratedToMultiPlaylist, value);

  // --- Legacy single-playlist scalars — read-only, migration use only ------
  // See AppConstants' doc comment on these keys: nothing writes any of these
  // anymore, they only feed PlaylistManager._migrateLegacySinglePlaylist.

  String? getLegacyM3uUrl() => _prefs.getString(AppConstants.keyM3uUrl);
  String? getLegacyEpgUrl() => _prefs.getString(AppConstants.keyEpgUrl);
  String getLegacyPlaylistMode() =>
      _prefs.getString(AppConstants.keyPlaylistMode) ?? 'm3u';
  String? getLegacyXtreamServer() =>
      _prefs.getString(AppConstants.keyXtreamServer);
  String? getLegacyXtreamUsername() =>
      _prefs.getString(AppConstants.keyXtreamUsername);
  String? getLegacyXtreamPassword() =>
      _prefs.getString(AppConstants.keyXtreamPassword);
  bool getLegacyPlaylistEnabled() =>
      _prefs.getBool(AppConstants.keyPlaylistEnabled) ?? true;
  Set<String> getLegacyHiddenGroups() =>
      (_prefs.getStringList(AppConstants.keyHiddenGroups) ?? []).toSet();
  Set<String> getLegacyFavoritedGroups() =>
      (_prefs.getStringList(AppConstants.keyFavoritedGroups) ?? []).toSet();
  int getLegacySyncFrequencyDays() =>
      _prefs.getInt(AppConstants.keySyncFrequencyDays) ??
      AppConstants.defaultSyncFrequencyDays;
  DateTime? getLegacyLastFullSyncAt() {
    final raw = _prefs.getString(AppConstants.keyLastFullSyncAt);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  int getRefreshInterval() =>
      _prefs.getInt(AppConstants.keyRefreshInterval) ??
      AppConstants.defaultRefreshIntervalMinutes;
  Future<void> setRefreshInterval(int minutes) =>
      _prefs.setInt(AppConstants.keyRefreshInterval, minutes);

  String getThemeMode() =>
      _prefs.getString(AppConstants.keyThemeMode) ?? 'dark';

  /// Null/empty means "release-date sorting is off" — `TmdbEnrichmentService`
  /// treats a missing key as a no-op rather than erroring, so a user who
  /// never sets one just never sees that sort option do anything, instead
  /// of a hard failure.
  String? getTmdbApiKey() => _prefs.getString(AppConstants.keyTmdbApiKey);
  Future<void> setTmdbApiKey(String key) =>
      _prefs.setString(AppConstants.keyTmdbApiKey, key);

  /// When "What's New" was last TMDB-enriched — see
  /// `PlaylistManager.refreshWhatsNewTmdbIfDue`'s doc comment. Null means
  /// never (a freshly-added key, or TMDB sorting never used at all).
  DateTime? getWhatsNewTmdbLastRefreshed() {
    final raw = _prefs.getString(AppConstants.keyWhatsNewTmdbLastRefreshed);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setWhatsNewTmdbLastRefreshed(DateTime time) => _prefs.setString(
      AppConstants.keyWhatsNewTmdbLastRefreshed, time.toIso8601String());
  Future<void> setThemeMode(String mode) =>
      _prefs.setString(AppConstants.keyThemeMode, mode);

  bool getShowClock() => _prefs.getBool(AppConstants.keyShowClock) ?? true;
  Future<void> setShowClock(bool value) =>
      _prefs.setBool(AppConstants.keyShowClock, value);

  /// Falls back to the first entry (Minimalist) when unset or when the
  /// stored id doesn't match a known palette — no migration attempted from
  /// the old single-seed-color storage, a fresh sensible default is simpler
  /// than trying to map an arbitrary old color onto the closest palette.
  String getPaletteId() =>
      _prefs.getString(AppConstants.keyPaletteId) ??
      AppConstants.cyberpunkPalettes.first.id;
  Future<void> setPaletteId(String id) =>
      _prefs.setString(AppConstants.keyPaletteId, id);

  /// 'auto', 'phone', or 'tv'.
  String getLayoutMode() =>
      _prefs.getString(AppConstants.keyLayoutMode) ??
      AppConstants.defaultLayoutMode;
  Future<void> setLayoutMode(String mode) =>
      _prefs.setString(AppConstants.keyLayoutMode, mode);

  /// 'live' or 'timeline'.
  String getGuideViewMode() =>
      _prefs.getString(AppConstants.keyGuideViewMode) ??
      AppConstants.defaultGuideViewMode;
  Future<void> setGuideViewMode(String mode) =>
      _prefs.setString(AppConstants.keyGuideViewMode, mode);

  // --- Favorites (per viewer, shared across every playlist) -----------------
  // Favorites aren't namespaced by playlist (a favorited channel is just a
  // composite playlistId::rawId already, so there's no collision risk the
  // way group *names* have) but ARE namespaced per viewer — see
  // "Viewer-profile scoping" below.

  Set<String> getFavorites() =>
      (_prefs.getStringList(_vk(AppConstants.keyFavorites)) ?? []).toSet();
  Future<void> setFavorites(Set<String> ids) =>
      _prefs.setStringList(_vk(AppConstants.keyFavorites), ids.toList());

  Set<String> getFavoriteSeries() =>
      (_prefs.getStringList(_vk(AppConstants.keyFavoriteSeries)) ?? [])
          .toSet();
  Future<void> setFavoriteSeries(Set<String> ids) => _prefs.setStringList(
      _vk(AppConstants.keyFavoriteSeries), ids.toList());

  // --- Hidden / favorited groups (per playlist, per viewer) -----------------
  // Group identity is (playlistId, title), not just title — two different
  // providers can easily have a same-named category. Each playlist gets its
  // own namespaced key rather than one shared Set, so there's no collision;
  // each viewer gets its own copy of that on top, so a restricted viewer's
  // hidden groups are independent of what any other viewer hides.

  Set<String> getHiddenGroups(String playlistId) =>
      (_prefs.getStringList(_vkp(AppConstants.keyHiddenGroups, playlistId)) ??
              [])
          .toSet();
  Future<void> setHiddenGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyHiddenGroups, playlistId), groups.toList());

  /// Keyed by `Channel.rawId` (not the composite `id`) — this is already
  /// namespaced per playlist and per viewer via the key suffixes, same as
  /// [getHiddenGroups].
  Set<String> getHiddenChannels(String playlistId) =>
      (_prefs.getStringList(
                  _vkp(AppConstants.keyHiddenChannels, playlistId)) ??
              [])
          .toSet();
  Future<void> setHiddenChannels(String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyHiddenChannels, playlistId), rawIds.toList());

  /// Keyed by `Channel.rawId` -> the assigned EPG feed's own channel id —
  /// see [AppConstants.keyEpgIdOverrides]'s doc comment. A malformed/
  /// pre-Map value (there isn't one pre-existing, but a corrupt prefs
  /// entry isn't unheard of elsewhere in this file) reads back as empty
  /// rather than throwing.
  Map<String, String> getEpgIdOverrides(String playlistId) {
    final raw =
        _prefs.getString('${AppConstants.keyEpgIdOverrides}_$playlistId');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> setEpgIdOverrides(
          String playlistId, Map<String, String> overrides) =>
      _prefs.setString('${AppConstants.keyEpgIdOverrides}_$playlistId',
          jsonEncode(overrides));

  /// Keyed by `Channel.rawId` -> the linked channel's own (playlistId,
  /// rawId) — see [AppConstants.keyChannelLinks]'s doc comment. Same
  /// "corrupt/missing reads back empty" tolerance as [getEpgIdOverrides].
  Map<String, ChannelLink> getChannelLinks(String playlistId) {
    final raw = _prefs.getString('${AppConstants.keyChannelLinks}_$playlistId');
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) {
        final m = v as Map<String, dynamic>;
        return MapEntry(k, (
          playlistId: m['playlistId'] as String,
          rawId: m['rawId'] as String
        ));
      });
    } catch (_) {
      return {};
    }
  }

  Future<void> setChannelLinks(
          String playlistId, Map<String, ChannelLink> links) =>
      _prefs.setString(
          '${AppConstants.keyChannelLinks}_$playlistId',
          jsonEncode(links.map((k, v) =>
              MapEntry(k, {'playlistId': v.playlistId, 'rawId': v.rawId}))));

  /// See [AppConstants.keyAutoPairedChannelLinks]'s doc comment.
  Set<String> getAutoPairedChannelLinks(String playlistId) =>
      (_prefs.getStringList(
                  '${AppConstants.keyAutoPairedChannelLinks}_$playlistId') ??
              [])
          .toSet();
  Future<void> setAutoPairedChannelLinks(
          String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          '${AppConstants.keyAutoPairedChannelLinks}_$playlistId',
          rawIds.toList());

  /// See [AppConstants.keyAutoPairedEpgOverrides]'s doc comment.
  Set<String> getAutoPairedEpgOverrides(String playlistId) =>
      (_prefs.getStringList(
                  '${AppConstants.keyAutoPairedEpgOverrides}_$playlistId') ??
              [])
          .toSet();
  Future<void> setAutoPairedEpgOverrides(
          String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          '${AppConstants.keyAutoPairedEpgOverrides}_$playlistId',
          rawIds.toList());

  Set<String> getFavoritedGroups(String playlistId) =>
      (_prefs.getStringList(
                  _vkp(AppConstants.keyFavoritedGroups, playlistId)) ??
              [])
          .toSet();
  Future<void> setFavoritedGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyFavoritedGroups, playlistId), groups.toList());

  // --- Search history (per viewer) ------------------------------------------

  static const _maxRecentSearches = 10;

  /// Most-recent-first. Shared across Live TV/Movies/TV Shows scopes rather
  /// than kept separate per scope — simpler, and a remembered search is
  /// useful regardless of which scope tab happens to be selected right now.
  List<String> getRecentSearches() =>
      _prefs.getStringList(_vk(AppConstants.keyRecentSearches)) ?? [];

  Future<void> addRecentSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value();
    final list = getRecentSearches()
        .where((s) => s.toLowerCase() != trimmed.toLowerCase())
        .toList();
    list.insert(0, trimmed);
    if (list.length > _maxRecentSearches)
      list.removeRange(_maxRecentSearches, list.length);
    return _prefs.setStringList(_vk(AppConstants.keyRecentSearches), list);
  }

  Future<void> clearRecentSearches() =>
      _prefs.remove(_vk(AppConstants.keyRecentSearches));

  // --- EPG cache -------------------------------------------------------------
  // The programme data itself lives in the disk-file cache now (see
  // AppConstants.cacheFileEpgPrograms) — a full-catalog EPG blob can be
  // many MB, and SharedPreferences backs onto a single XML file the OS
  // loads whole, which made every cold start pay for parsing that giant
  // string on the main isolate. Only the last-updated timestamp stays here.

  DateTime? getEpgLastUpdated() {
    final raw = _prefs.getString(AppConstants.keyEpgLastUpdated);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setEpgLastUpdated(DateTime time) =>
      _prefs.setString(AppConstants.keyEpgLastUpdated, time.toIso8601String());

  // --- Full catalog sync (per playlist) -----------------------------------
  // Sync frequency itself lives directly on PlaylistProfile.syncFrequencyDays
  // now (see StorageService.setPlaylists) — only the "when did it last
  // actually run" timestamp needs its own namespaced key here.

  DateTime? getLastFullSyncAt(String playlistId) {
    final raw =
        _prefs.getString('${AppConstants.keyLastFullSyncAt}_$playlistId');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastFullSyncAt(String playlistId, DateTime time) =>
      _prefs.setString('${AppConstants.keyLastFullSyncAt}_$playlistId',
          time.toIso8601String());

  // --- Resume playback (per viewer) ---------------------------------------

  String? getLastChannelId() =>
      _prefs.getString(_vk(AppConstants.keyLastChannelId));
  Future<void> setLastChannelId(String id) =>
      _prefs.setString(_vk(AppConstants.keyLastChannelId), id);

  /// The viewer suffix goes at the *end*, after [channelId] — not
  /// immediately after the prefix — so every viewer's position/duration key
  /// still starts with [AppConstants.keyLastPositionPrefix]/
  /// [keyLastDurationPrefix] and [clearCache]'s existing `startsWith` sweep
  /// below keeps catching all of them, not just Main's.
  String _positionKey(String channelId) =>
      _vk('${AppConstants.keyLastPositionPrefix}$channelId');
  String _durationKey(String channelId) =>
      _vk('${AppConstants.keyLastDurationPrefix}$channelId');

  int getLastPosition(String channelId) =>
      _prefs.getInt(_positionKey(channelId)) ?? 0;
  Future<void> setLastPosition(String channelId, int milliseconds) =>
      _prefs.setInt(_positionKey(channelId), milliseconds);

  int getLastDuration(String channelId) =>
      _prefs.getInt(_durationKey(channelId)) ?? 0;
  Future<void> setLastDuration(String channelId, int milliseconds) =>
      _prefs.setInt(_durationKey(channelId), milliseconds);

  /// Fraction watched (0.0-1.0), or null when there's nothing to compute
  /// one from — no saved position, or duration was never recorded (e.g.
  /// playback never got far enough to report one).
  double? getWatchedFraction(String channelId) {
    final duration = getLastDuration(channelId);
    final position = getLastPosition(channelId);
    if (duration <= 0 || position <= 0) return null;
    return (position / duration).clamp(0.0, 1.0);
  }

  /// True once far enough into playback to call it done — not exactly 100%,
  /// since end credits/a few trailing seconds are routinely never watched.
  bool isFullyWatched(String channelId) {
    final fraction = getWatchedFraction(channelId);
    return fraction != null && fraction >= 0.95;
  }

  /// Clears EPG cache, the entire on-disk playlist/catalog cache (including
  /// the per-category files — there's one per VOD/series category, named
  /// dynamically by category id, so wiping the whole directory is simpler
  /// and more thorough than trying to enumerate them), and saved playback
  /// positions. Playlist/EPG source settings, favorites, and hidden-group
  /// choices are left untouched.
  Future<void> clearCache() async {
    await _prefs.remove(AppConstants.keyEpgCache);
    await _prefs.remove(AppConstants.keyEpgLastUpdated);
    await _prefs.remove(AppConstants.keyLastFullSyncAt);
    final positionKeys = _prefs
        .getKeys()
        .where((k) =>
            k.startsWith(AppConstants.keyLastPositionPrefix) ||
            k.startsWith(AppConstants.keyLastDurationPrefix) ||
            k.startsWith('${AppConstants.keyLastFullSyncAt}_'))
        .toList();
    for (final key in positionKeys) {
      await _prefs.remove(key);
    }

    final dir = await _ensureCacheDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
  }

  // --- Viewer-profile scoping ----------------------------------------------
  // See `AppConstants`' "Viewer profiles" section and `ViewerProfile`'s doc
  // comment for the feature. Every getter/setter above this point that's
  // marked "(per viewer)" below resolves its key through `_vk`/`_vkp`
  // instead of the bare constant — a no-op for `mainViewerId`, so an
  // upgrading install with no other viewer keeps reading/writing exactly
  // the key it always has.

  /// Appends the active viewer's suffix to [base] — a no-op for
  /// [AppConstants.mainViewerId]. Every per-viewer getter/setter is built
  /// from this (or [_vkp] for a key that's also namespaced per playlist).
  String _vk(String base) => _activeViewerId == AppConstants.mainViewerId
      ? base
      : '$base${AppConstants.viewerKeySuffix}$_activeViewerId';

  /// Same as [_vk], for a key namespaced per playlist *and* per viewer —
  /// the playlist suffix always comes first, viewer suffix last, so
  /// `deleteViewerData`'s single "ends with the viewer suffix" sweep still
  /// finds it regardless of which playlist it belongs to.
  String _vkp(String base, String playlistId) => _vk('${base}_$playlistId');

  String getActiveViewerId() => _activeViewerId;

  Future<void> setActiveViewerId(String id) async {
    _activeViewerId = id;
    await _prefs.setString(AppConstants.keyActiveViewerId, id);
  }

  /// Always at least one entry (Main) — an install that's never configured
  /// any other viewer simply hasn't written this key yet.
  List<ViewerProfile> getViewerProfiles() {
    final raw = _prefs.getString(AppConstants.keyViewerProfiles);
    if (raw == null || raw.isEmpty) return [ViewerProfile.main()];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final profiles = decoded
          .map((e) => ViewerProfile.fromJson(e as Map<String, dynamic>))
          .toList();
      return profiles.isEmpty ? [ViewerProfile.main()] : profiles;
    } catch (_) {
      return [ViewerProfile.main()];
    }
  }

  Future<void> setViewerProfiles(List<ViewerProfile> profiles) =>
      _prefs.setString(AppConstants.keyViewerProfiles,
          jsonEncode(profiles.map((p) => p.toJson()).toList()));

  /// `{v, salt, hash}` — see `ParentalPin` for how this is produced/checked.
  /// Null means no PIN has ever been set (no restricted profile exists yet).
  Map<String, dynamic>? getParentalPin() {
    final raw = _prefs.getString(AppConstants.keyParentalPin);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> setParentalPin(Map<String, dynamic> record) =>
      _prefs.setString(AppConstants.keyParentalPin, jsonEncode(record));

  Future<void> clearParentalPin() =>
      _prefs.remove(AppConstants.keyParentalPin);

  /// Consecutive wrong-PIN attempts — persisted (not just in memory) so
  /// restarting the app doesn't reset a lockout a kid could otherwise use
  /// to get unlimited guesses.
  int getPinFailCount() => _prefs.getInt(AppConstants.keyPinFailCount) ?? 0;
  Future<void> setPinFailCount(int count) =>
      _prefs.setInt(AppConstants.keyPinFailCount, count);

  DateTime? getPinLockedUntil() {
    final raw = _prefs.getString(AppConstants.keyPinLockedUntil);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setPinLockedUntil(DateTime? time) => time == null
      ? _prefs.remove(AppConstants.keyPinLockedUntil)
      : _prefs.setString(
          AppConstants.keyPinLockedUntil, time.toIso8601String());

  bool getFavoritesDbReconciled() =>
      _prefs.getBool(AppConstants.keyFavoritesDbReconciled) ?? false;
  Future<void> setFavoritesDbReconciled(bool value) =>
      _prefs.setBool(AppConstants.keyFavoritesDbReconciled, value);

  /// A restricted viewer's shown-groups allowlist — see
  /// [AppConstants.keyShownGroups]'s doc comment. (Per playlist, per viewer.)
  Set<String> getShownGroups(String playlistId) =>
      (_prefs.getStringList(_vkp(AppConstants.keyShownGroups, playlistId)) ??
              [])
          .toSet();
  Future<void> setShownGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyShownGroups, playlistId), groups.toList());

  /// Removes every one of [viewerId]'s own keys — favorites, hidden/shown/
  /// favorited groups and hidden channels for every playlist, positions/
  /// durations, recent searches, and its last-channel id — in one sweep,
  /// since every per-viewer key (see [_vk]/[_vkp]) ends with the same
  /// `__vp_<id>` suffix regardless of which feature or playlist it belongs
  /// to. Refuses [AppConstants.mainViewerId] outright: that id's data lives
  /// under the bare, unsuffixed keys every pre-profiles install already
  /// depends on, which this must never touch. The per-viewer
  /// recently-played cache *file* is a separate concern, deleted by
  /// whoever owns that file (`PlaybackService`), not here.
  Future<void> deleteViewerData(String viewerId) async {
    if (viewerId == AppConstants.mainViewerId) return;
    final suffix = '${AppConstants.viewerKeySuffix}$viewerId';
    final keys = _prefs.getKeys().where((k) => k.endsWith(suffix)).toList();
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }
}
