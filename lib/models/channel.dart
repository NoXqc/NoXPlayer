/// A manual cross-playlist link — see
/// `AppConstants.keyChannelLinks`'s doc comment. Identifies another
/// [Channel] by its own (playlistId, rawId), the same pair
/// `PlaylistManager.resolveChannelLink` looks a live [Channel] back up
/// from.
typedef ChannelLink = ({String playlistId, String rawId});

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
    this.epgIdOverride,
    this.tmdbId,
    this.releaseDate,
    this.posterUrl,
    this.backdropUrl,
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

  /// A manually-assigned EPG channel id (see
  /// `PlaylistManager.setEpgIdOverride`), replacing [rawId] as the key an
  /// EPG lookup uses for this channel — set on the already-loaded
  /// `Channel` in place, the same "mutate in place, no full reload"
  /// pattern [isFavorite] already uses, and reapplied from
  /// [PlaylistSession.epgIdOverrides] every time this channel's list is
  /// (re)built (see the `favoriteIds()` stamping loops in
  /// `playlist_session.dart`, right next to where this is stamped
  /// alongside them). Exists because a provider's own `epg_channel_id`/
  /// `tvg-id` for a channel can be missing, wrong, or simply not covered
  /// by whatever third-party XMLTV source is configured — reported
  /// directly (Trex channels with no EPG match at all in a third-party
  /// feed that otherwise parses fine). Null means "use rawId", not "no
  /// EPG" — every existing channel keeps working exactly as before.
  String? epgIdOverride;

  /// The TMDB (The Movie Database) id this title is looked up by — the
  /// provider's own `get_vod_streams`/`get_series` bulk list call
  /// [addedAt] already comes from sends one for *some* items at zero extra
  /// network cost; when it doesn't (confirmed directly: entirely untagged
  /// on some providers, with no TMDB-sourced [releaseDate]/[posterUrl]
  /// ever appearing as a result — "What's New" looked like it was simply
  /// never using TMDB at all), [TmdbEnrichmentService] resolves one itself
  /// via a title search instead and stamps it in here. Mutable (not
  /// `final`) for exactly that reason — same pattern [releaseDate]/
  /// [posterUrl] already use. Exists purely as the lookup key those two
  /// are fetched with; nothing else in the app reads this directly.
  String? tmdbId;

  /// The title's actual real-world release date — deliberately *not* the
  /// same thing as [addedAt] (when the provider's own catalog first
  /// listed it), which is often months or years off from when something
  /// actually released. Reported directly: wanted to sort a category by
  /// genuine release recency ("just came out Oct 1 2026" at the top), not
  /// by provider ingestion date. Requires a separate TMDB API lookup per
  /// [tmdbId] (see `TmdbEnrichmentService`) — not available from the bulk
  /// catalog list the way [addedAt]/[rating] are, so this stays null until
  /// that lookup has actually run and cached a result for this item.
  /// Mutable (not `final`) — same "stamp it in place on the already-built
  /// object" pattern [epgIdOverride]/[seriesId] use, since enrichment runs
  /// *after* a category's [Channel] objects already exist in memory.
  DateTime? releaseDate;

  /// A TMDB poster image, fetched at zero extra request cost — the same
  /// per-[tmdbId] lookup `TmdbEnrichmentService` already makes for
  /// [releaseDate] returns a `poster_path` in that identical response.
  /// Consistently higher-resolution and more reliably present than a
  /// provider's own [logoUrl]/[seriesCoverUrl] (reported directly as this
  /// app's least-liked thing about the "What's New" row), so callers
  /// prefer this over those when it's set, falling back otherwise. Same
  /// mutable "stamp in place" reasoning as [releaseDate].
  String? posterUrl;

  /// A TMDB *backdrop* image — a landscape (16:9) scene still/key-art,
  /// a completely different asset from [posterUrl]'s portrait poster,
  /// fetched from the same per-[tmdbId] lookup at no extra request cost
  /// (`backdrop_path` rides along in that identical response). Requested
  /// directly after seeing TiviMate's full-bleed hero banner: stretching
  /// [posterUrl] (portrait) to fill a wide banner is the exact "hand and
  /// a desk" crop bug this app already hit once building its own hero —
  /// a real landscape backdrop is the actual fix, not a different crop of
  /// the same wrong image. Same mutable "stamp in place" pattern as
  /// [posterUrl]; null until enrichment has run for this item, same as
  /// every TMDB-sourced field here.
  String? backdropUrl;

  /// The id every EPG lookup call site uses — see [epgIdOverride]'s doc
  /// comment. Never [rawId] directly from an EPG-lookup call site; that
  /// would bypass a manual assignment.
  String get epgId => epgIdOverride ?? rawId;

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
        epgIdOverride: epgIdOverride,
        tmdbId: tmdbId,
        releaseDate: releaseDate,
        posterUrl: posterUrl,
        backdropUrl: backdropUrl,
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
        'tmdbId': tmdbId,
        'releaseDate': releaseDate?.millisecondsSinceEpoch,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
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
        tmdbId: json['tmdbId'] as String?,
        releaseDate: json['releaseDate'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['releaseDate'] as int)
            : null,
        posterUrl: json['posterUrl'] as String?,
        backdropUrl: json['backdropUrl'] as String?,
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
