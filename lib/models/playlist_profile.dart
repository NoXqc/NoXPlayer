import '../utils/constants.dart';

/// One playlist's login/config, part of the app's list of playlists (see
/// `PlaylistManager`, `StorageService.getPlaylists`/`setPlaylists`).
/// Replaces what used to be a handful of single global scalar prefs
/// (`keyM3uUrl`, `keyXtreamServer`/`Username`/`Password`, etc.) — those
/// only ever supported exactly one playlist app-wide.
class PlaylistProfile {
  PlaylistProfile({
    required this.id,
    required this.name,
    required this.mode,
    this.m3uUrl,
    this.epgUrl,
    this.xtreamServer,
    this.xtreamUsername,
    this.xtreamPassword,
    this.enabled = true,
    required this.sortOrder,
    this.syncFrequencyDays = AppConstants.defaultSyncFrequencyDays,
    required this.createdAt,
  });

  /// Stable identifier, generated once and never reused — every
  /// per-playlist prefs key, cache-file name, and catalog-database row
  /// this playlist owns is namespaced by this id (see `Channel
  /// .playlistId`'s doc comment). `'migrated_default'` is reserved for the
  /// one playlist an upgrade from the old single-playlist version
  /// synthesizes — see `PlaylistManager._migrateLegacySinglePlaylist`.
  final String id;

  final String name;

  /// 'm3u' or 'xtream' — same values `StorageService.getPlaylistMode`
  /// used to store as a single global scalar.
  final String mode;

  final String? m3uUrl;
  final String? epgUrl;
  final String? xtreamServer;
  final String? xtreamUsername;
  final String? xtreamPassword;

  bool enabled;

  /// Display/load order in every merged list (Live TV groups, Movies/TV
  /// Shows categories) — lower sorts first, so "Playlist A's groups, then
  /// a separator, then Playlist B's groups" has a stable, user-visible
  /// order instead of whatever order a Map/Set happens to iterate in.
  int sortOrder;

  /// "Update content every N days" — used to live as one global setting
  /// (`AppConstants.keySyncFrequencyDays`); now per-playlist, since two
  /// playlists can reasonably want different refresh cadences.
  int syncFrequencyDays;

  final DateTime createdAt;

  PlaylistProfile copyWith({
    String? name,
    String? mode,
    String? m3uUrl,
    String? epgUrl,
    String? xtreamServer,
    String? xtreamUsername,
    String? xtreamPassword,
    bool? enabled,
    int? sortOrder,
    int? syncFrequencyDays,
  }) =>
      PlaylistProfile(
        id: id,
        name: name ?? this.name,
        mode: mode ?? this.mode,
        m3uUrl: m3uUrl ?? this.m3uUrl,
        epgUrl: epgUrl ?? this.epgUrl,
        xtreamServer: xtreamServer ?? this.xtreamServer,
        xtreamUsername: xtreamUsername ?? this.xtreamUsername,
        xtreamPassword: xtreamPassword ?? this.xtreamPassword,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder ?? this.sortOrder,
        syncFrequencyDays: syncFrequencyDays ?? this.syncFrequencyDays,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode,
        'm3uUrl': m3uUrl,
        'epgUrl': epgUrl,
        'xtreamServer': xtreamServer,
        'xtreamUsername': xtreamUsername,
        'xtreamPassword': xtreamPassword,
        'enabled': enabled,
        'sortOrder': sortOrder,
        'syncFrequencyDays': syncFrequencyDays,
        'createdAt': createdAt.toIso8601String(),
      };

  factory PlaylistProfile.fromJson(Map<String, dynamic> json) =>
      PlaylistProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        mode: json['mode'] as String,
        m3uUrl: json['m3uUrl'] as String?,
        epgUrl: json['epgUrl'] as String?,
        xtreamServer: json['xtreamServer'] as String?,
        xtreamUsername: json['xtreamUsername'] as String?,
        xtreamPassword: json['xtreamPassword'] as String?,
        enabled: json['enabled'] as bool? ?? true,
        sortOrder: json['sortOrder'] as int? ?? 0,
        syncFrequencyDays: json['syncFrequencyDays'] as int? ??
            AppConstants.defaultSyncFrequencyDays,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );

  bool get isXtream => mode == 'xtream';
}
