import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/channel.dart';
import '../models/xtream_series.dart';
import 'catalog_database.dart';
import 'storage_service.dart';

/// Fetches each title's real-world release date from TMDB (The Movie
/// Database) and caches it — see `Channel.releaseDate`'s doc comment for
/// why this exists as a separate lookup instead of just using the
/// provider's own `added`/`last_modified` field.
///
/// Deliberately narrow about when this runs at all: only ever called for
/// whatever category a user actually opens via "Expand catalog"
/// (`GroupCatalogScreen`), never proactively for a whole catalog or for a
/// hidden group — a hidden group is never opened in the first place, so it
/// never reaches this. A provider's VOD/series catalog can run to tens or
/// hundreds of thousands of items; enriching all of it eagerly would mean
/// that many individual TMDB requests, which is exactly the kind of
/// unbounded background cost this app has been bitten by before (see the
/// EPG hidden-groups fix this same session). Scoping to "only what's
/// actually being looked at right now" keeps this bounded to a single
/// category's worth of items (typically tens to a few hundred) no matter
/// how large the provider's full catalog is.
class TmdbEnrichmentService {
  TmdbEnrichmentService(this._storage, this._db);

  final StorageService _storage;
  final CatalogDatabase _db;

  static const _base = 'https://api.themoviedb.org/3';

  /// Items in flight at once — plain sequential (one at a time) made a
  /// few hundred items take minutes, which read as a *stuck/wrong* sort
  /// rather than a still-loading one (reported directly: newer titles
  /// sitting below older ones, because they just hadn't been fetched yet
  /// — the list only re-sorts with whatever data exists *so far*). Five
  /// concurrent requests is a meaningful speedup without hammering TMDB.
  static const _concurrency = 5;

  /// Small pause between batches, not per-item — TMDB's v3 API no longer
  /// publishes a hard rate limit, but there's no reason to fire batch
  /// after batch with zero spacing at all.
  static const _batchPause = Duration(milliseconds: 150);

  /// Enriches whichever of [items] have a [Channel.tmdbId] but no
  /// [Channel.releaseDate] yet. [onProgress] fires after *every* attempt
  /// (hit or miss), not just ones that found a date, so a caller can show
  /// real "X of Y processed" progress — distinguishing "still working,
  /// correct so far" from "finished, this is the final order" is the
  /// whole point, since a partially-enriched category's incremental sort
  /// is only valid up to whatever point enrichment has actually reached.
  Future<void> enrichVod(List<Channel> items,
      {void Function(int done, int total)? onProgress}) async {
    final key = _storage.getTmdbApiKey();
    final pending =
        items.where((c) => c.tmdbId != null && c.releaseDate == null).toList();
    if (key == null || key.isEmpty || pending.isEmpty) {
      onProgress?.call(0, 0);
      return;
    }
    var done = 0;
    final total = pending.length;
    for (var i = 0; i < pending.length; i += _concurrency) {
      final batch = pending.skip(i).take(_concurrency);
      // A try/catch *per item* (not just around the whole batch) — one
      // item throwing used to reject the whole `Future.wait`, which
      // silently killed every remaining batch with nothing ever
      // surfacing it. Confirmed directly as the real cause of "only one
      // title ever moves, no matter the provider or how well-tagged its
      // catalog is" — data availability was never the problem.
      await Future.wait(batch.map((c) async {
        try {
          final date = await _fetchReleaseDate(c.tmdbId!, key, isMovie: true);
          if (date != null) {
            c.releaseDate = date;
            unawaited(_db.setVodReleaseDate(c.id, date));
          }
        } catch (_) {
          // A dead/invalid key, a rate limit, a title TMDB doesn't have —
          // none of these are worth surfacing as an error to the viewer
          // browsing a poster grid. The item just keeps showing no release
          // date, same as if this service didn't run at all.
        }
        done++;
        onProgress?.call(done, total);
      }));
      await Future<void>.delayed(_batchPause);
    }
  }

  /// Same as [enrichVod] for series — TMDB's `/tv/{id}` endpoint and
  /// `first_air_date` instead of `/movie/{id}`'s `release_date`.
  Future<void> enrichSeries(List<XtreamSeries> items,
      {void Function(int done, int total)? onProgress}) async {
    final key = _storage.getTmdbApiKey();
    final pending =
        items.where((s) => s.tmdbId != null && s.releaseDate == null).toList();
    if (key == null || key.isEmpty || pending.isEmpty) {
      onProgress?.call(0, 0);
      return;
    }
    var done = 0;
    final total = pending.length;
    for (var i = 0; i < pending.length; i += _concurrency) {
      final batch = pending.skip(i).take(_concurrency);
      await Future.wait(batch.map((s) async {
        try {
          final date = await _fetchReleaseDate(s.tmdbId!, key, isMovie: false);
          if (date != null) {
            s.releaseDate = date;
            unawaited(_db.setSeriesReleaseDate(s.id, date));
          }
        } catch (_) {
          // See the matching catch in enrichVod above.
        }
        done++;
        onProgress?.call(done, total);
      }));
      await Future<void>.delayed(_batchPause);
    }
  }

  Future<DateTime?> _fetchReleaseDate(String tmdbId, String apiKey,
      {required bool isMovie}) async {
    try {
      final path = isMovie ? 'movie' : 'tv';
      final uri = Uri.parse('$_base/$path/$tmdbId?api_key=$apiKey');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final raw =
          (isMovie ? data['release_date'] : data['first_air_date']) as String?;
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }
}
