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
  });

  final int seriesId;
  final String name;
  final String categoryId;
  final String? coverUrl;

  /// Mutable, flipped in place by `PlaylistManager.toggleSeriesFavorite` —
  /// same pattern as `Channel.isFavorite`.
  bool isFavorite;

  Map<String, dynamic> toJson() => {
        'seriesId': seriesId,
        'name': name,
        'categoryId': categoryId,
        'coverUrl': coverUrl,
        'isFavorite': isFavorite,
      };

  factory XtreamSeries.fromJson(Map<String, dynamic> json) => XtreamSeries(
        seriesId: json['seriesId'] as int,
        name: json['name'] as String,
        categoryId: json['categoryId'] as String,
        coverUrl: json['coverUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
      );
}
