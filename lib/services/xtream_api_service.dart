import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/channel.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';

/// Talks to a real Xtream Codes ("XC API") panel via `player_api.php`.
///
/// Large providers can have tens of thousands of movies/series — pulling
/// the whole catalog at once (or via the `get.php` M3U export) is exactly
/// what caused an OutOfMemoryError on a 28k-live/158k-VOD/50k-series
/// account. Categories are cheap and fetched eagerly; VOD/series items are
/// fetched lazily, one category at a time, which keeps every response in
/// the hundreds-of-KB to low-MB range regardless of catalog size.
class XtreamApiService {
  XtreamApiService({
    required String server,
    required this.username,
    required this.password,
    required this.playlistId,
  }) : server = _normalizeServer(server);

  final String server;
  final String username;
  final String password;

  /// Which playlist this login belongs to — prefixed onto every id this
  /// instance generates (`Channel.id`/`XtreamSeries.id`) so two different
  /// Xtream logins' ids can never collide once merged into the same lists.
  /// See `Channel.playlistId`'s doc comment.
  final String playlistId;

  /// From the account's own `user_info.max_connections` (a string in the
  /// API response, `"0"` conventionally meaning unlimited) — null until
  /// [authenticate] runs, or if the field was missing/unparseable.
  /// PlaylistManager uses this to size how many categories it fetches
  /// concurrently: confirmed on real hardware that firing more concurrent
  /// requests than an account actually allows gets the extras rejected
  /// with HTTP 403 — and, a separate bug also fixed alongside this, that
  /// nothing gave up retrying those, so it hammered the server with
  /// rejected requests forever for the rest of the session.
  int? maxConnections;

  /// From the account's own `user_info.exp_date` (an epoch-seconds
  /// string) — null until [authenticate] runs, and also left null if the
  /// field is missing, unparseable, or "0" (some panels use that for a
  /// lifetime/reseller-unlimited account with no real expiry to report).
  DateTime? expiryDate;

  static String _normalizeServer(String server) {
    var s = server.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri _apiUri(String action, [Map<String, String>? extra]) {
    return Uri.parse('$server/player_api.php').replace(queryParameters: {
      'username': username,
      'password': password,
      if (action.isNotEmpty) 'action': action,
      ...?extra,
    });
  }

  Future<dynamic> _getJson(String action, [Map<String, String>? extra]) async {
    final response = await http
        .get(_apiUri(action, extra))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception(
          'Xtream request failed: $action (HTTP ${response.statusCode})');
    }
    // Off the UI thread — this is the shared decode path for every single
    // API call, including the per-category VOD/series fetches that fire
    // every time scrolling opens a newly-visible category. Confirmed via a
    // live Dart VM pause during an actual freeze (stuck the whole time
    // inside one uninterruptible native call) that a synchronous jsonDecode
    // here is exactly what was blocking the UI thread for seconds on a
    // large provider's category response — this is the first-fetch
    // counterpart to the cache-side fix in PlaylistManager.
    return compute(_decodeJsonBody, response.body);
  }

  Future<List<Map<String, dynamic>>> _getList(String action,
      [Map<String, String>? extra]) async {
    final decoded = await _getJson(action, extra);
    if (decoded is! List) return [];
    return decoded.cast<Map<String, dynamic>>();
  }

  /// Verifies the credentials and account status. Throws if invalid,
  /// expired, or disabled.
  Future<void> authenticate() async {
    final decoded = await _getJson('');
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected Xtream API response');
    }
    final userInfo = decoded['user_info'] as Map<String, dynamic>?;
    if (userInfo == null || userInfo['auth'] != 1) {
      throw Exception('Invalid Xtream username/password');
    }
    final status = userInfo['status'] as String?;
    if (status != 'Active') {
      throw Exception('Xtream account is not active (status: $status)');
    }
    final rawMaxConnections =
        int.tryParse(userInfo['max_connections']?.toString() ?? '');
    // "0" conventionally means unlimited on Xtream panels — leave
    // maxConnections null in that case so callers fall back to their own
    // default cap rather than reading 0 as "allow zero connections".
    maxConnections = (rawMaxConnections != null && rawMaxConnections > 0)
        ? rawMaxConnections
        : null;
    final rawExpDate = int.tryParse(userInfo['exp_date']?.toString() ?? '');
    expiryDate = (rawExpDate != null && rawExpDate > 0)
        ? DateTime.fromMillisecondsSinceEpoch(rawExpDate * 1000)
        : null;
  }

  List<XtreamCategory> _toCategories(List<Map<String, dynamic>> raw) => raw
      .map((c) => XtreamCategory(
            id: c['category_id']?.toString() ?? '',
            name: c['category_name']?.toString() ?? 'Uncategorized',
          ))
      .where((c) => c.id.isNotEmpty)
      .toList();

  Future<List<XtreamCategory>> getLiveCategories() =>
      _getList('get_live_categories').then(_toCategories);

  Future<List<XtreamCategory>> getVodCategories() =>
      _getList('get_vod_categories').then(_toCategories);

  Future<List<XtreamCategory>> getSeriesCategories() =>
      _getList('get_series_categories').then(_toCategories);

  /// All live channels — fetched whole (typically single-digit MB even for
  /// large providers), since users expect to search live TV without
  /// picking a category first. [categoryNames] maps category id -> display
  /// name (from [getLiveCategories]) so [Channel.group] holds the same
  /// display name used everywhere else, keeping the sidebar's group
  /// filtering ("channels where c.group == selected group title") working
  /// identically to M3U mode.
  Future<List<Channel>> getLiveStreams(
      {required Map<String, String> categoryNames}) async {
    final raw = await _getList('get_live_streams');
    // Building a Channel per item is cheap in isolation, but a provider with
    // hundreds of live categories can mean tens of thousands of channels —
    // enough synchronous Dart work on the main isolate (no `await` inside
    // the loop to yield control) to block input dispatch past Android's 5s
    // ANR watchdog, confirmed on real hardware after "Update Content" was
    // hit right after a cold launch. One batched `compute()` call (not one
    // per item — that itself caused a launch-time isolate-spawn-storm
    // regression earlier this session) moves it off the main isolate.
    return compute(
      _buildLiveChannels,
      _LiveStreamsArgs(
        raw: raw,
        categoryNames: categoryNames,
        server: server,
        username: username,
        password: password,
        playlistId: playlistId,
      ),
    );
  }

  /// Movies for a single VOD category — call once per category, on demand.
  /// [categoryName] is the display name of [categoryId], already known by
  /// the caller (it's what the user just tapped in the sidebar).
  Future<List<Channel>> getVodStreams(
      String categoryId, String categoryName) async {
    final raw = await _getList('get_vod_streams', {'category_id': categoryId});
    // Some providers bundle thousands of items into a single category (the
    // whole reason `PlaylistManager` caps what it keeps in memory) — the
    // full list is still built once here before that cap applies, so this
    // needs the same off-main-isolate treatment as getLiveStreams.
    return compute(
      _buildVodChannels,
      _VodStreamsArgs(
        raw: raw,
        categoryName: categoryName,
        server: server,
        username: username,
        password: password,
        playlistId: playlistId,
      ),
    );
  }

  /// Plot/description for one movie — a separate on-demand call
  /// (`get_vod_info`), not part of [getVodStreams]: the list endpoint used
  /// for the whole category doesn't carry it, and fetching it for every
  /// item in a 150k-title catalog just to populate a browse grid isn't
  /// worth the request — only called when a user actually opens one
  /// movie's detail screen.
  Future<String?> getVodDescription(String streamId) async {
    final decoded = await _getJson('get_vod_info', {'vod_id': streamId});
    if (decoded is! Map<String, dynamic>) return null;
    final info = decoded['info'];
    final plot = info is Map ? info['plot']?.toString() : null;
    return (plot != null && plot.isNotEmpty) ? plot : null;
  }

  /// Series (not directly playable) for a single category — call once per
  /// category, on demand. Use [getSeriesEpisodes] to resolve a chosen
  /// series into its playable episodes.
  Future<List<XtreamSeries>> getSeriesForCategory(String categoryId) async {
    final raw = await _getList('get_series', {'category_id': categoryId});
    // Same rationale as getVodStreams above — a single category can hold
    // thousands of series.
    return compute(_buildSeriesItems,
        _SeriesArgs(raw: raw, categoryId: categoryId, playlistId: playlistId));
  }

  /// Episodes for one series, grouped by season number, plus the series'
  /// own plot/description — both come from the same `get_series_info`
  /// call, so this returns both rather than making SeriesDetailScreen pay
  /// for a second request just for the plot.
  Future<({Map<int, List<Channel>> episodes, String? plot})> getSeriesEpisodes(
    int seriesId,
    String seriesName,
  ) async {
    final decoded =
        await _getJson('get_series_info', {'series_id': '$seriesId'});
    if (decoded is! Map<String, dynamic>)
      return (episodes: <int, List<Channel>>{}, plot: null);

    final info = decoded['info'];
    final rawPlot = info is Map ? info['plot']?.toString() : null;
    final plot = (rawPlot != null && rawPlot.isNotEmpty) ? rawPlot : null;

    final episodesByS = decoded['episodes'];
    if (episodesByS is! Map)
      return (episodes: <int, List<Channel>>{}, plot: plot);

    final result = <int, List<Channel>>{};
    episodesByS.forEach((seasonKey, episodeList) {
      final season = int.tryParse(seasonKey.toString()) ?? 0;
      if (episodeList is! List) return;
      final channels = episodeList.map((raw) {
        final episode = raw as Map<String, dynamic>;
        final episodeId = episode['id'];
        final ext = episode['container_extension']?.toString() ?? 'mp4';
        final episodeNum = episode['episode_num']?.toString() ?? '?';
        final title = episode['title']?.toString() ?? 'Episode $episodeNum';
        // Most Xtream panels include a per-episode still under `info`
        // (commonly `movie_image`) — read it defensively, since not every
        // panel supplies it; the UI falls back to the series' own cover
        // art when this is null rather than showing a blank card.
        final info = episode['info'];
        final stillUrl = info is Map ? info['movie_image']?.toString() : null;
        final rawId = 'xt_ep_$episodeId';
        return Channel(
          id: '$playlistId::$rawId',
          rawId: rawId,
          playlistId: playlistId,
          name: 'S${season}E$episodeNum — $title',
          group: seriesName,
          url: '$server/series/$username/$password/$episodeId.$ext',
          logoUrl: (stillUrl != null && stillUrl.isNotEmpty) ? stillUrl : null,
        );
      }).toList();
      result[season] = channels;
    });

    return (episodes: result, plot: plot);
  }
}

// Top-level — required by `compute`, which runs this on a separate isolate
// with no access to instance state.
dynamic _decodeJsonBody(String body) => jsonDecode(body);

class _LiveStreamsArgs {
  const _LiveStreamsArgs({
    required this.raw,
    required this.categoryNames,
    required this.server,
    required this.username,
    required this.password,
    required this.playlistId,
  });
  final List<Map<String, dynamic>> raw;
  final Map<String, String> categoryNames;
  final String server;
  final String username;
  final String password;
  final String playlistId;
}

List<Channel> _buildLiveChannels(_LiveStreamsArgs args) {
  return args.raw.map((item) {
    final streamId = item['stream_id'];
    final epgChannelId = item['epg_channel_id']?.toString();
    final rawId = (epgChannelId != null && epgChannelId.isNotEmpty)
        ? epgChannelId
        : 'xt_live_$streamId';
    final categoryId = item['category_id']?.toString() ?? '';
    return Channel(
      id: '${args.playlistId}::$rawId',
      rawId: rawId,
      playlistId: args.playlistId,
      name: item['name']?.toString() ?? 'Unnamed Channel',
      group: args.categoryNames[categoryId] ?? 'Uncategorized',
      url:
          '${args.server}/live/${args.username}/${args.password}/$streamId.m3u8',
      logoUrl: item['stream_icon']?.toString(),
    );
  }).toList();
}

class _VodStreamsArgs {
  const _VodStreamsArgs({
    required this.raw,
    required this.categoryName,
    required this.server,
    required this.username,
    required this.password,
    required this.playlistId,
  });
  final List<Map<String, dynamic>> raw;
  final String categoryName;
  final String server;
  final String username;
  final String password;
  final String playlistId;
}

List<Channel> _buildVodChannels(_VodStreamsArgs args) {
  return args.raw.map((item) {
    final streamId = item['stream_id'];
    final ext = item['container_extension']?.toString() ?? 'mp4';
    final rating = item['rating']?.toString();
    final rawId = 'xt_vod_$streamId';
    return Channel(
      id: '${args.playlistId}::$rawId',
      rawId: rawId,
      playlistId: args.playlistId,
      name: item['name']?.toString() ?? 'Unnamed Movie',
      group: args.categoryName,
      url:
          '${args.server}/movie/${args.username}/${args.password}/$streamId.$ext',
      logoUrl: item['stream_icon']?.toString(),
      rating: (rating != null && rating.isNotEmpty && rating != '0')
          ? rating
          : null,
    );
  }).toList();
}

class _SeriesArgs {
  const _SeriesArgs(
      {required this.raw, required this.categoryId, required this.playlistId});
  final List<Map<String, dynamic>> raw;
  final String categoryId;
  final String playlistId;
}

List<XtreamSeries> _buildSeriesItems(_SeriesArgs args) {
  return args.raw.map((item) {
    final rating = item['rating']?.toString();
    return XtreamSeries(
      seriesId: int.parse(item['series_id'].toString()),
      playlistId: args.playlistId,
      name: item['name']?.toString() ?? 'Unnamed Series',
      categoryId: args.categoryId,
      coverUrl: item['cover']?.toString(),
      rating: (rating != null && rating.isNotEmpty && rating != '0')
          ? rating
          : null,
    );
  }).toList();
}
