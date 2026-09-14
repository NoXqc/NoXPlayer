import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // --- Playlist / EPG source URLs -----------------------------------------

  String? getM3uUrl() => _prefs.getString(AppConstants.keyM3uUrl);
  Future<void> setM3uUrl(String url) => _prefs.setString(AppConstants.keyM3uUrl, url);

  String? getEpgUrl() => _prefs.getString(AppConstants.keyEpgUrl);
  Future<void> setEpgUrl(String url) => _prefs.setString(AppConstants.keyEpgUrl, url);

  int getRefreshInterval() =>
      _prefs.getInt(AppConstants.keyRefreshInterval) ?? AppConstants.defaultRefreshIntervalMinutes;
  Future<void> setRefreshInterval(int minutes) =>
      _prefs.setInt(AppConstants.keyRefreshInterval, minutes);

  String getThemeMode() => _prefs.getString(AppConstants.keyThemeMode) ?? 'dark';
  Future<void> setThemeMode(String mode) => _prefs.setString(AppConstants.keyThemeMode, mode);

  bool getShowClock() => _prefs.getBool(AppConstants.keyShowClock) ?? true;
  Future<void> setShowClock(bool value) => _prefs.setBool(AppConstants.keyShowClock, value);

  /// Falls back to the first entry (Purple/Magenta) when unset or when the
  /// stored id doesn't match a known palette — no migration attempted from
  /// the old single-seed-color storage, a fresh sensible default is simpler
  /// than trying to map an arbitrary old color onto the closest palette.
  String getPaletteId() => _prefs.getString(AppConstants.keyPaletteId) ?? AppConstants.cyberpunkPalettes.first.id;
  Future<void> setPaletteId(String id) => _prefs.setString(AppConstants.keyPaletteId, id);

  /// 'auto', 'phone', or 'tv'.
  String getLayoutMode() => _prefs.getString(AppConstants.keyLayoutMode) ?? AppConstants.defaultLayoutMode;
  Future<void> setLayoutMode(String mode) => _prefs.setString(AppConstants.keyLayoutMode, mode);

  bool getPlaylistEnabled() => _prefs.getBool(AppConstants.keyPlaylistEnabled) ?? true;
  Future<void> setPlaylistEnabled(bool value) =>
      _prefs.setBool(AppConstants.keyPlaylistEnabled, value);

  /// Whether the one-time "Hold Down to return to your live stream" hint
  /// has already been shown next to the live island pill — see
  /// LiveIslandOverlay. Shown at most once ever, not once per app launch.
  bool getHasSeenLiveIslandHint() => _prefs.getBool(AppConstants.keyHasSeenLiveIslandHint) ?? false;
  Future<void> setHasSeenLiveIslandHint() =>
      _prefs.setBool(AppConstants.keyHasSeenLiveIslandHint, true);

  // --- Xtream Codes (XC API) credentials ------------------------------------

  String getPlaylistMode() => _prefs.getString(AppConstants.keyPlaylistMode) ?? 'm3u';
  Future<void> setPlaylistMode(String mode) => _prefs.setString(AppConstants.keyPlaylistMode, mode);

  String? getXtreamServer() => _prefs.getString(AppConstants.keyXtreamServer);
  Future<void> setXtreamServer(String value) => _prefs.setString(AppConstants.keyXtreamServer, value);

  String? getXtreamUsername() => _prefs.getString(AppConstants.keyXtreamUsername);
  Future<void> setXtreamUsername(String value) =>
      _prefs.setString(AppConstants.keyXtreamUsername, value);

  String? getXtreamPassword() => _prefs.getString(AppConstants.keyXtreamPassword);
  Future<void> setXtreamPassword(String value) =>
      _prefs.setString(AppConstants.keyXtreamPassword, value);

  // --- Favorites / hidden groups -------------------------------------------

  Set<String> getFavorites() => (_prefs.getStringList(AppConstants.keyFavorites) ?? []).toSet();
  Future<void> setFavorites(Set<String> ids) =>
      _prefs.setStringList(AppConstants.keyFavorites, ids.toList());

  Set<String> getFavoriteSeries() =>
      (_prefs.getStringList(AppConstants.keyFavoriteSeries) ?? []).toSet();
  Future<void> setFavoriteSeries(Set<String> ids) =>
      _prefs.setStringList(AppConstants.keyFavoriteSeries, ids.toList());

  Set<String> getHiddenGroups() =>
      (_prefs.getStringList(AppConstants.keyHiddenGroups) ?? []).toSet();
  Future<void> setHiddenGroups(Set<String> groups) =>
      _prefs.setStringList(AppConstants.keyHiddenGroups, groups.toList());

  Set<String> getFavoritedGroups() =>
      (_prefs.getStringList(AppConstants.keyFavoritedGroups) ?? []).toSet();
  Future<void> setFavoritedGroups(Set<String> groups) =>
      _prefs.setStringList(AppConstants.keyFavoritedGroups, groups.toList());

  // --- Search history -------------------------------------------------------

  static const _maxRecentSearches = 10;

  /// Most-recent-first. Shared across Live TV/Movies/TV Shows scopes rather
  /// than kept separate per scope — simpler, and a remembered search is
  /// useful regardless of which scope tab happens to be selected right now.
  List<String> getRecentSearches() => _prefs.getStringList(AppConstants.keyRecentSearches) ?? [];

  Future<void> addRecentSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value();
    final list = getRecentSearches().where((s) => s.toLowerCase() != trimmed.toLowerCase()).toList();
    list.insert(0, trimmed);
    if (list.length > _maxRecentSearches) list.removeRange(_maxRecentSearches, list.length);
    return _prefs.setStringList(AppConstants.keyRecentSearches, list);
  }

  Future<void> clearRecentSearches() => _prefs.remove(AppConstants.keyRecentSearches);

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

  // --- Full catalog sync -------------------------------------------------

  DateTime? getLastFullSyncAt() {
    final raw = _prefs.getString(AppConstants.keyLastFullSyncAt);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastFullSyncAt(DateTime time) =>
      _prefs.setString(AppConstants.keyLastFullSyncAt, time.toIso8601String());

  int getSyncFrequencyDays() =>
      _prefs.getInt(AppConstants.keySyncFrequencyDays) ?? AppConstants.defaultSyncFrequencyDays;
  Future<void> setSyncFrequencyDays(int days) =>
      _prefs.setInt(AppConstants.keySyncFrequencyDays, days);

  // --- Resume playback ---------------------------------------------------

  String? getLastChannelId() => _prefs.getString(AppConstants.keyLastChannelId);
  Future<void> setLastChannelId(String id) => _prefs.setString(AppConstants.keyLastChannelId, id);

  int getLastPosition(String channelId) =>
      _prefs.getInt('${AppConstants.keyLastPositionPrefix}$channelId') ?? 0;
  Future<void> setLastPosition(String channelId, int milliseconds) =>
      _prefs.setInt('${AppConstants.keyLastPositionPrefix}$channelId', milliseconds);

  int getLastDuration(String channelId) =>
      _prefs.getInt('${AppConstants.keyLastDurationPrefix}$channelId') ?? 0;
  Future<void> setLastDuration(String channelId, int milliseconds) =>
      _prefs.setInt('${AppConstants.keyLastDurationPrefix}$channelId', milliseconds);

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
            k.startsWith(AppConstants.keyLastDurationPrefix))
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
