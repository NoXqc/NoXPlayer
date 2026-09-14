/// A series entry from the Xtream Codes API — a container of seasons and
/// episodes, not directly playable. Tapping one fetches its episodes on
/// demand via [XtreamApiService.getSeriesEpisodes].
class XtreamSeries {
  XtreamSeries({
    required this.seriesId,
    required this.name,
    required this.categoryId,
    this.coverUrl,
    this.isFavorite = false,
    this.rating,
  });

  final int seriesId;
  final String name;
  final String categoryId;
  final String? coverUrl;

  /// Provider-supplied rating — same `rating` key Xtream's VOD streams list
  /// carries (see `Channel.rating`), also present per-series on `get_series`
  /// but previously never parsed, so TV shows never got the same "★ N.N"
  /// poster badge movies do even though the provider sends the data.
  final String? rating;

  /// Mutable, flipped in place by `PlaylistManager.toggleSeriesFavorite` —
  /// same pattern as `Channel.isFavorite`.
  bool isFavorite;

  Map<String, dynamic> toJson() => {
        'seriesId': seriesId,
        'name': name,
        'categoryId': categoryId,
        'coverUrl': coverUrl,
        'isFavorite': isFavorite,
        'rating': rating,
      };

  factory XtreamSeries.fromJson(Map<String, dynamic> json) => XtreamSeries(
        seriesId: json['seriesId'] as int,
        name: json['name'] as String,
        categoryId: json['categoryId'] as String,
        coverUrl: json['coverUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        rating: json['rating'] as String?,
      );
}
