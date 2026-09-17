/// A single playable entry parsed from an M3U playlist (a live TV channel
/// or a VOD/movie item — the app treats both the same way at this level).
class Channel {
  Channel({
    required this.id,
    required this.rawId,
    required this.playlistId,
    required this.name,
    required this.group,
    required this.url,
    this.logoUrl,
    this.subtitleUrl,
    this.isFavorite = false,
    this.rating,
    this.addedAt,
    this.seriesId,
    this.seriesName,
    this.seriesCoverUrl,
  });

  /// Stable identifier: the M3U `tvg-id` when present (used to match EPG
  /// programmes), otherwise a generated fallback. Already prefixed with
  /// `playlistId` at construction time (see `XtreamApiService`/
  /// `M3uParser`) so ids stay globally unique once channels from more than
  /// one playlist are merged into the same lists — two different
  /// providers can easily reuse the same raw `stream_id`/`tvg-id`.
  final String id;

  /// The pre-multi-playlist-support id shape, unprefixed — e.g.
  /// `xt_vod_$streamId`, `xt_ep_$episodeId`, `xt_live_$streamId`/an
  /// `epg_channel_id`, or an M3U `tvg-id`. [id] is `'$playlistId::$rawId'`.
  /// Kept as its own field (not derived by string-stripping [id] at every
  /// call site — `playlistId` is variable-length, `::` splitting would be
  /// fragile) purely for the handful of places that pattern-match on the
  /// provider's own id shape: [isLiveId], the Movies/TV-Shows "Continue
  /// Watching" `xt_vod_`/`xt_ep_` prefix filters, and
  /// `PlaylistManager.getVodDescription`'s raw-stream-id extraction.
  final String rawId;

  /// Which playlist this channel came from — the same id every group,
  /// hidden-groups entry, and cache-file name for this playlist share
  /// (see `PlaylistProfile.id`). Used to detect a playlist boundary when
  /// rendering merged group lists (a divider between Playlist A's and
  /// Playlist B's groups), and to scope Group Management/favorites-group
  /// lookups.
  final String playlistId;
  final String name;
  final String group;
  final String url;
  final String? logoUrl;
  final String? subtitleUrl;
  bool isFavorite;

  /// Provider-supplied rating (e.g. Xtream's `rating` field on VOD items).
  /// Meaningless for live channels — null there.
  final String? rating;

  /// When the provider says this title showed up in its catalog (Xtream's
  /// `added` field on VOD items, epoch seconds). Null for live channels,
  /// for M3U playlists (no such concept exists there at all), and whenever
  /// the provider didn't report it — the "What's New" carousel simply has
  /// nothing to show in those cases rather than guessing an order.
  final DateTime? addedAt;

  /// Set on episode channels only (see PlaylistManager.loadSeriesEpisodes)
  /// — the series this episode belongs to, so "Continue Watching" can show
  /// and reopen the actual show instead of just this one episode. Mutable
  /// (like [isFavorite]) rather than requiring a full reconstruction each
  /// time a season screen is opened.
  int? seriesId;
  String? seriesName;
  String? seriesCoverUrl;

  Channel copyWith({bool? isFavorite}) => Channel(
        id: id,
        rawId: rawId,
        playlistId: playlistId,
        name: name,
        group: group,
        url: url,
        logoUrl: logoUrl,
        subtitleUrl: subtitleUrl,
        isFavorite: isFavorite ?? this.isFavorite,
        rating: rating,
        addedAt: addedAt,
        seriesId: seriesId,
        seriesName: seriesName,
        seriesCoverUrl: seriesCoverUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'rawId': rawId,
        'playlistId': playlistId,
        'name': name,
        'group': group,
        'url': url,
        'logoUrl': logoUrl,
        'subtitleUrl': subtitleUrl,
        'isFavorite': isFavorite,
        'rating': rating,
        'addedAt': addedAt?.millisecondsSinceEpoch,
        'seriesId': seriesId,
        'seriesName': seriesName,
        'seriesCoverUrl': seriesCoverUrl,
      };

  /// `playlistId` defaults to `'migrated_default'` and `rawId` to [id]
  /// itself when absent from a decoded blob — belt-and-suspenders only:
  /// every on-disk cache file this reads gained a playlist-id-suffixed
  /// name in this same release (see `PlaylistManager`'s per-session cache
  /// naming), so a pre-multi-playlist cache file is simply never looked up
  /// again under its old unsuffixed name post-upgrade, not silently
  /// misread as if it had these fields.
  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        rawId: json['rawId'] as String? ?? json['id'] as String,
        playlistId: json['playlistId'] as String? ?? 'migrated_default',
        name: json['name'] as String,
        group: json['group'] as String,
        url: json['url'] as String,
        logoUrl: json['logoUrl'] as String?,
        subtitleUrl: json['subtitleUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        rating: json['rating'] as String?,
        addedAt: json['addedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['addedAt'] as int)
            : null,
        seriesId: json['seriesId'] as int?,
        seriesName: json['seriesName'] as String?,
        seriesCoverUrl: json['seriesCoverUrl'] as String?,
      );

  /// Best-effort "is this a live channel, not VOD/an episode" signal from
  /// just a raw id — the same convention `PlayerScreen._searchScope`
  /// already used in one place; centralized here so every caller that
  /// needs to tell live apart from VOD (without trusting the video
  /// controller's own `duration`, which some live HLS streams misreport as
  /// their current DVR sliding-window length instead of zero/unknown —
  /// see `PlayerControls.isLive`'s doc comment) shares one answer instead
  /// of each guessing separately. Xtream ids are prefixed at creation time
  /// (`xt_vod_...`/`xt_ep_...` — see XtreamApiService); M3U-mode channels
  /// carry no such distinction at all, a pre-existing, separate
  /// limitation — this only returns a confident answer for Xtream ids.
  /// Takes a raw id (`Channel.rawId`, not `Channel.id`) — the playlist
  /// prefix on `id` would otherwise mask these provider-native prefixes.
  static bool isLiveId(String rawId) =>
      !(rawId.startsWith('xt_vod_') || rawId.startsWith('xt_ep_'));
}
