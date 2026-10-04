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

  /// TMDB's own image CDN — `w500` is a good balance for a TV poster grid
  /// (noticeably sharper than most providers' own art without pulling full
  /// originals). See `Channel.posterUrl`'s doc comment: this rides along in
  /// the exact same response [_fetchDetails] already fetches for
  /// [Channel.releaseDate]/[XtreamSeries.releaseDate], at no extra request.
  static const _imageBase = 'https://image.tmdb.org/t/p/w500';

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

  /// Enriches whichever of [items] are still missing [Channel.releaseDate]
  /// or [Channel.posterUrl] — the latter was added after the former, so an
  /// item enriched before that point has a release date already but no
  /// poster yet; re-including it here lets a later enrichment pass
  /// backfill just the poster without re-fetching the date. No longer
  /// gated on [Channel.tmdbId] already being set — confirmed directly on
  /// a real provider (Trex/SRS-style) as the actual reason this whole
  /// feature looked like it silently did nothing with a valid key saved:
  /// most of its catalog sends no `tmdb` field at all, so every item was
  /// filtered out before a single request was ever made. A missing
  /// [Channel.tmdbId] is now resolved here too, via [_searchTmdbId], the
  /// same way a human would search TMDB by the title itself.
  /// [onProgress] fires after *every* attempt (hit or miss), not just
  /// ones that found something, so a caller can show real "X of Y
  /// processed" progress — distinguishing "still working, correct so far"
  /// from "finished, this is the final order" is the whole point, since a
  /// partially-enriched category's incremental sort is only valid up to
  /// whatever point enrichment has actually reached.
  Future<void> enrichVod(List<Channel> items,
      {void Function(int done, int total)? onProgress}) async {
    final key = _storage.getTmdbApiKey();
    final pending = items
        .where((c) => c.releaseDate == null || c.posterUrl == null)
        .toList();
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
          var id = c.tmdbId;
          id ??= await _searchTmdbId(c.name, key, isMovie: true);
          if (id != null && id != c.tmdbId) {
            c.tmdbId = id;
            unawaited(_db.setVodTmdbId(c.id, id));
          }
          if (id == null) return;
          final details = await _fetchDetails(id, key, isMovie: true);
          if (details != null) {
            if (details.releaseDate != null) {
              c.releaseDate = details.releaseDate;
              unawaited(_db.setVodReleaseDate(c.id, details.releaseDate!));
            }
            if (details.posterUrl != null) {
              c.posterUrl = details.posterUrl;
              unawaited(_db.setVodPosterUrl(c.id, details.posterUrl!));
            }
          }
        } catch (_) {
          // A dead/invalid key, a rate limit, a title TMDB doesn't have —
          // none of these are worth surfacing as an error to the viewer
          // browsing a poster grid. The item just keeps showing no release
          // date, same as if this service didn't run at all.
        } finally {
          done++;
          onProgress?.call(done, total);
        }
      }));
      await Future<void>.delayed(_batchPause);
    }
  }

  /// Same as [enrichVod] for series — TMDB's `/tv/{id}` endpoint and
  /// `first_air_date` instead of `/movie/{id}`'s `release_date`.
  Future<void> enrichSeries(List<XtreamSeries> items,
      {void Function(int done, int total)? onProgress}) async {
    final key = _storage.getTmdbApiKey();
    final pending = items
        .where((s) => s.releaseDate == null || s.posterUrl == null)
        .toList();
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
          var id = s.tmdbId;
          id ??= await _searchTmdbId(s.name, key, isMovie: false);
          if (id != null && id != s.tmdbId) {
            s.tmdbId = id;
            unawaited(_db.setSeriesTmdbId(s.id, id));
          }
          if (id == null) return;
          final details = await _fetchDetails(id, key, isMovie: false);
          if (details != null) {
            if (details.releaseDate != null) {
              s.releaseDate = details.releaseDate;
              unawaited(_db.setSeriesReleaseDate(s.id, details.releaseDate!));
            }
            if (details.posterUrl != null) {
              s.posterUrl = details.posterUrl;
              unawaited(_db.setSeriesPosterUrl(s.id, details.posterUrl!));
            }
          }
        } catch (_) {
          // See the matching catch in enrichVod above.
        } finally {
          done++;
          onProgress?.call(done, total);
        }
      }));
      await Future<void>.delayed(_batchPause);
    }
  }

  /// Looks up a TMDB id by title for an item the provider sent no `tmdb`
  /// field for — the fallback [enrichVod]/[enrichSeries] use instead of
  /// just giving up. Provider titles are usually decorated (language/
  /// quality prefixes like "FR - "/"4K-EN-HDR - ", trailing tags like
  /// "[MULTI-SUB]") well beyond what TMDB's own search can match against,
  /// so [_cleanTitleForSearch] strips those first. Takes the top result as-
  /// is — TMDB's search endpoint already ranks by relevance/popularity,
  /// and a wrong match here only ever costs a wrong-but-harmless poster/
  /// date on one title, not anything the user acts on directly.
  Future<String?> _searchTmdbId(String rawTitle, String apiKey,
      {required bool isMovie}) async {
    final cleaned = _cleanTitleForSearch(rawTitle);
    if (cleaned.title.isEmpty) return null;
    try {
      final path = isMovie ? 'search/movie' : 'search/tv';
      final uri = Uri.parse('$_base/$path').replace(queryParameters: {
        'api_key': apiKey,
        'query': cleaned.title,
        if (cleaned.year != null)
          (isMovie ? 'year' : 'first_air_date_year'): cleaned.year.toString(),
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = (data['results'] as List?) ?? const [];
      if (results.isEmpty) return null;
      return (results.first as Map<String, dynamic>)['id']?.toString();
    } catch (_) {
      return null;
    }
  }

  /// A leading provider tag ("FR - ", "4K-EN-HDR - " — one or more dash/
  /// underscore-joined alphanumeric segments followed by " - "), a
  /// trailing year in parentheses (captured separately as a search hint,
  /// not left in the query text), and any number of trailing bracketed
  /// tags ("[MULTI-SUB]", "[VF]"). Best-effort, not exhaustive — provider
  /// naming varies, but TMDB's own search ranking tolerates an imperfect
  /// query far better than it tolerates searching for the raw decorated
  /// string wholesale.
  static final RegExp _leadingProviderTag =
      RegExp(r'^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*\s*-\s*');
  static final RegExp _trailingBracketTag = RegExp(r'\s*\[[^\]]*\]\s*$');
  static final RegExp _trailingYear = RegExp(r'\s*\((\d{4})\)\s*$');

  ({String title, int? year}) _cleanTitleForSearch(String raw) {
    var title = raw;
    while (true) {
      final stripped = title.replaceFirst(_trailingBracketTag, '');
      if (stripped == title) break;
      title = stripped;
    }
    int? year;
    final yearMatch = _trailingYear.firstMatch(title);
    if (yearMatch != null) {
      year = int.tryParse(yearMatch.group(1)!);
      title = title.replaceFirst(_trailingYear, '');
    }
    title = title.replaceFirst(_leadingProviderTag, '');
    return (title: title.trim(), year: year);
  }

  Future<({DateTime? releaseDate, String? posterUrl})?> _fetchDetails(
      String tmdbId, String apiKey,
      {required bool isMovie}) async {
    try {
      final path = isMovie ? 'movie' : 'tv';
      final uri = Uri.parse('$_base/$path/$tmdbId?api_key=$apiKey');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawDate =
          (isMovie ? data['release_date'] : data['first_air_date']) as String?;
      final posterPath = data['poster_path'] as String?;
      return (
        releaseDate: (rawDate != null && rawDate.isNotEmpty)
            ? DateTime.tryParse(rawDate)
            : null,
        posterUrl: (posterPath != null && posterPath.isNotEmpty)
            ? '$_imageBase$posterPath'
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}
