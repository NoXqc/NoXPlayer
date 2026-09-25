import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist_profile.dart';
import '../utils/constants.dart';

/// Wraps [SharedPreferences] for small settings values, and the OS temp
/// directory for larger cached payloads (parsed playlist/catalog JSON) —
/// multi-MB strings don't belong in SharedPreferences' XML-backed store,
/// and living under the temp dir means the OS can reclaim them under
/// storage pressure with no worse outcome than "re-fetch from network".
class StorageService {
  late SharedPreferences _prefs;
  Directory? _cacheDir;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
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

  // --- Favorites (global — shared across every playlist) -------------------

  Set<String> getFavorites() =>
      (_prefs.getStringList(AppConstants.keyFavorites) ?? []).toSet();
  Future<void> setFavorites(Set<String> ids) =>
      _prefs.setStringList(AppConstants.keyFavorites, ids.toList());

  Set<String> getFavoriteSeries() =>
      (_prefs.getStringList(AppConstants.keyFavoriteSeries) ?? []).toSet();
  Future<void> setFavoriteSeries(Set<String> ids) =>
      _prefs.setStringList(AppConstants.keyFavoriteSeries, ids.toList());

  // --- Hidden / favorited groups (per playlist) -----------------------------
  // Group identity is (playlistId, title), not just title — two different
  // providers can easily have a same-named category. Each playlist gets its
  // own namespaced key rather than one shared Set, so there's no collision.

  Set<String> getHiddenGroups(String playlistId) =>
      (_prefs.getStringList('${AppConstants.keyHiddenGroups}_$playlistId') ??
              [])
          .toSet();
  Future<void> setHiddenGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          '${AppConstants.keyHiddenGroups}_$playlistId', groups.toList());

  /// Keyed by `Channel.rawId` (not the composite `id`) — this is already
  /// namespaced per playlist via the key suffix, same as [getHiddenGroups].
  Set<String> getHiddenChannels(String playlistId) =>
      (_prefs.getStringList('${AppConstants.keyHiddenChannels}_$playlistId') ??
              [])
          .toSet();
  Future<void> setHiddenChannels(String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          '${AppConstants.keyHiddenChannels}_$playlistId', rawIds.toList());

  Set<String> getFavoritedGroups(String playlistId) =>
      (_prefs.getStringList('${AppConstants.keyFavoritedGroups}_$playlistId') ??
              [])
          .toSet();
  Future<void> setFavoritedGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          '${AppConstants.keyFavoritedGroups}_$playlistId', groups.toList());

  // --- Search history -------------------------------------------------------

  static const _maxRecentSearches = 10;

  /// Most-recent-first. Shared across Live TV/Movies/TV Shows scopes rather
  /// than kept separate per scope — simpler, and a remembered search is
  /// useful regardless of which scope tab happens to be selected right now.
  List<String> getRecentSearches() =>
      _prefs.getStringList(AppConstants.keyRecentSearches) ?? [];

  Future<void> addRecentSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value();
    final list = getRecentSearches()
        .where((s) => s.toLowerCase() != trimmed.toLowerCase())
        .toList();
    list.insert(0, trimmed);
    if (list.length > _maxRecentSearches)
      list.removeRange(_maxRecentSearches, list.length);
    return _prefs.setStringList(AppConstants.keyRecentSearches, list);
  }

  Future<void> clearRecentSearches() =>
      _prefs.remove(AppConstants.keyRecentSearches);

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

  // --- Resume playback ---------------------------------------------------

  String? getLastChannelId() => _prefs.getString(AppConstants.keyLastChannelId);
  Future<void> setLastChannelId(String id) =>
      _prefs.setString(AppConstants.keyLastChannelId, id);

  int getLastPosition(String channelId) =>
      _prefs.getInt('${AppConstants.keyLastPositionPrefix}$channelId') ?? 0;
  Future<void> setLastPosition(String channelId, int milliseconds) => _prefs
      .setInt('${AppConstants.keyLastPositionPrefix}$channelId', milliseconds);

  int getLastDuration(String channelId) =>
      _prefs.getInt('${AppConstants.keyLastDurationPrefix}$channelId') ?? 0;
  Future<void> setLastDuration(String channelId, int milliseconds) => _prefs
      .setInt('${AppConstants.keyLastDurationPrefix}$channelId', milliseconds);

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
}
