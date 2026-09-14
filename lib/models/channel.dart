/// A single playable entry parsed from an M3U playlist (a live TV channel
/// or a VOD/movie item — the app treats both the same way at this level).
class Channel {
  Channel({
    required this.id,
    required this.name,
    required this.group,
    required this.url,
    this.logoUrl,
    this.subtitleUrl,
    this.isFavorite = false,
    this.rating,
    this.seriesId,
    this.seriesName,
    this.seriesCoverUrl,
  });

  /// Stable identifier: the M3U `tvg-id` when present (used to match EPG
  /// programmes), otherwise a generated fallback.
  final String id;
  final String name;
  final String group;
  final String url;
  final String? logoUrl;
  final String? subtitleUrl;
  bool isFavorite;

  /// Provider-supplied rating (e.g. Xtream's `rating` field on VOD items).
  /// Meaningless for live channels — null there.
  final String? rating;

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
        name: name,
        group: group,
        url: url,
        logoUrl: logoUrl,
        subtitleUrl: subtitleUrl,
        isFavorite: isFavorite ?? this.isFavorite,
        rating: rating,
        seriesId: seriesId,
        seriesName: seriesName,
        seriesCoverUrl: seriesCoverUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'url': url,
        'logoUrl': logoUrl,
        'subtitleUrl': subtitleUrl,
        'isFavorite': isFavorite,
        'rating': rating,
        'seriesId': seriesId,
        'seriesName': seriesName,
        'seriesCoverUrl': seriesCoverUrl,
      };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        name: json['name'] as String,
        group: json['group'] as String,
        url: json['url'] as String,
        logoUrl: json['logoUrl'] as String?,
        subtitleUrl: json['subtitleUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        rating: json['rating'] as String?,
        seriesId: json['seriesId'] as int?,
        seriesName: json['seriesName'] as String?,
        seriesCoverUrl: json['seriesCoverUrl'] as String?,
      );

  /// Best-effort "is this a live channel, not VOD/an episode" signal from
  /// just an id — the same convention `PlayerScreen._searchScope` already
  /// used in one place; centralized here so every caller that needs to
  /// tell live apart from VOD (without trusting the video controller's
  /// own `duration`, which some live HLS streams misreport as their
  /// current DVR sliding-window length instead of zero/unknown — see
  /// `PlayerControls.isLive`'s doc comment) shares one answer instead of
  /// each guessing separately. Xtream ids are prefixed at creation time
  /// (`xt_vod_...`/`xt_ep_...` — see XtreamApiService); M3U-mode channels
  /// carry no such distinction at all, a pre-existing, separate
  /// limitation — this only returns a confident answer for Xtream ids.
  static bool isLiveId(String id) => !(id.startsWith('xt_vod_') || id.startsWith('xt_ep_'));
}
