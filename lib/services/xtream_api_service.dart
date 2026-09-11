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
  XtreamApiService({required String server, required this.username, required this.password})
      : server = _normalizeServer(server);

  final String server;
  final String username;
  final String password;

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
    final response = await http.get(_apiUri(action, extra)).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Xtream request failed: $action (HTTP ${response.statusCode})');
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

  Future<List<Map<String, dynamic>>> _getList(String action, [Map<String, String>? extra]) async {
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
  Future<List<Channel>> getLiveStreams({required Map<String, String> categoryNames}) async {
    final raw = await _getList('get_live_streams');
    return raw.map((item) {
      final streamId = item['stream_id'];
      final epgChannelId = item['epg_channel_id']?.toString();
      final id = (epgChannelId != null && epgChannelId.isNotEmpty)
          ? epgChannelId
          : 'xt_live_$streamId';
      final categoryId = item['category_id']?.toString() ?? '';
      return Channel(
        id: id,
        name: item['name']?.toString() ?? 'Unnamed Channel',
        group: categoryNames[categoryId] ?? 'Uncategorized',
        url: '$server/live/$username/$password/$streamId.m3u8',
        logoUrl: item['stream_icon']?.toString(),
      );
    }).toList();
  }

  /// Movies for a single VOD category — call once per category, on demand.
  /// [categoryName] is the display name of [categoryId], already known by
  /// the caller (it's what the user just tapped in the sidebar).
  Future<List<Channel>> getVodStreams(String categoryId, String categoryName) async {
    final raw = await _getList('get_vod_streams', {'category_id': categoryId});
    return raw.map((item) {
      final streamId = item['stream_id'];
      final ext = item['container_extension']?.toString() ?? 'mp4';
      final rating = item['rating']?.toString();
      return Channel(
        id: 'xt_vod_$streamId',
        name: item['name']?.toString() ?? 'Unnamed Movie',
        group: categoryName,
        url: '$server/movie/$username/$password/$streamId.$ext',
        logoUrl: item['stream_icon']?.toString(),
        rating: (rating != null && rating.isNotEmpty && rating != '0') ? rating : null,
      );
    }).toList();
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
    return raw
        .map((item) => XtreamSeries(
              seriesId: int.parse(item['series_id'].toString()),
              name: item['name']?.toString() ?? 'Unnamed Series',
              categoryId: categoryId,
              coverUrl: item['cover']?.toString(),
            ))
        .toList();
  }

  /// Episodes for one series, grouped by season number, plus the series'
  /// own plot/description — both come from the same `get_series_info`
  /// call, so this returns both rather than making SeriesDetailScreen pay
  /// for a second request just for the plot.
  Future<({Map<int, List<Channel>> episodes, String? plot})> getSeriesEpisodes(
    int seriesId,
    String seriesName,
  ) async {
    final decoded = await _getJson('get_series_info', {'series_id': '$seriesId'});
    if (decoded is! Map<String, dynamic>) return (episodes: <int, List<Channel>>{}, plot: null);

    final info = decoded['info'];
    final rawPlot = info is Map ? info['plot']?.toString() : null;
    final plot = (rawPlot != null && rawPlot.isNotEmpty) ? rawPlot : null;

    final episodesByS = decoded['episodes'];
    if (episodesByS is! Map) return (episodes: <int, List<Channel>>{}, plot: plot);

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
        return Channel(
          id: 'xt_ep_$episodeId',
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
