/// A series entry from the Xtream Codes API — a container of seasons and
/// episodes, not directly playable. Tapping one fetches its episodes on
/// demand via [XtreamApiService.getSeriesEpisodes].
class XtreamSeries {
  XtreamSeries({
    required this.seriesId,
    required this.playlistId,
    required this.name,
    required this.categoryId,
    this.coverUrl,
    this.isFavorite = false,
    this.rating,
    this.addedAt,
  }) : id = '$playlistId::series_$seriesId';

  /// The raw per-provider integer Xtream itself uses — kept because
  /// `getSeriesEpisodes` still needs it for the `get_series_info` API
  /// call. Not safely unique across two different providers on its own
  /// (see `id`).
  final int seriesId;

  /// Which playlist this series came from — see `Channel.playlistId`.
  final String playlistId;

  /// Globally-unique stable identifier, derived from [playlistId] and
  /// [seriesId] — this class had no string id at all before multi-playlist
  /// support; two providers can easily both assign the same raw
  /// `seriesId`, so favoriting/lookup code (`PlaylistManager
  /// .toggleSeriesFavorite`, `CatalogDatabase`'s `series_items` primary
  /// key) uses this instead of the bare int.
  final String id;
  final String name;
  final String categoryId;
  final String? coverUrl;

  /// Provider-supplied rating — same `rating` key Xtream's VOD streams list
  /// carries (see `Channel.rating`), also present per-series on `get_series`
  /// but previously never parsed, so TV shows never got the same "★ N.N"
  /// poster badge movies do even though the provider sends the data.
  final String? rating;

  /// When this show showed up in the provider's catalog — `get_series`
  /// reports it as `last_modified` (epoch seconds), not the `added` field
  /// `get_vod_streams` uses for movies (see `Channel.addedAt`); same
  /// meaning, different key per content type. Null when not reported.
  final DateTime? addedAt;

  /// Mutable, flipped in place by `PlaylistManager.toggleSeriesFavorite` —
  /// same pattern as `Channel.isFavorite`.
  bool isFavorite;

  Map<String, dynamic> toJson() => {
        'seriesId': seriesId,
        'playlistId': playlistId,
        'name': name,
        'categoryId': categoryId,
        'coverUrl': coverUrl,
        'isFavorite': isFavorite,
        'rating': rating,
        'addedAt': addedAt?.millisecondsSinceEpoch,
      };

  /// `playlistId` defaults to `'migrated_default'` for the same reason as
  /// `Channel.fromJson` — see its doc comment.
  factory XtreamSeries.fromJson(Map<String, dynamic> json) => XtreamSeries(
        seriesId: json['seriesId'] as int,
        playlistId: json['playlistId'] as String? ?? 'migrated_default',
        name: json['name'] as String,
        categoryId: json['categoryId'] as String,
        coverUrl: json['coverUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        rating: json['rating'] as String?,
        addedAt: json['addedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['addedAt'] as int)
            : null,
      );
}
