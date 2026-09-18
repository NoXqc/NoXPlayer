import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';

/// Local database of VOD/series catalog items, keyed by category — the
/// on-disk replacement for what used to be one JSON file per category.
///
/// The old approach fully deserialized *every* cached category into Dart
/// objects on every single app launch (`PlaylistManager._restoreXtreamCache`),
/// which is fine for a handful of categories but a genuine memory-capacity
/// problem on a large provider catalog (confirmed on real hardware:
/// `lowmemorykiller`/thrashing, not just a CPU-bound freeze). A real
/// database lets a category's items be *queried* on demand — the same
/// on-demand shape `ensureCategoryLoaded` already uses for the network
/// fetch — instead of everything being loaded into memory upfront.
///
/// Live channels and the small category-name/id lists are NOT stored here
/// — they're not the memory problem and stay on `StorageService`'s
/// existing JSON-file cache.
///
/// Every row also carries a `playlist_id` (multi-playlist support) — a
/// category *name* alone isn't a safe scoping key once two different
/// providers can both have, say, a "Sports" category; every query/write
/// below is scoped by `(category_name, playlist_id)` together, not name
/// alone.
class CatalogDatabase {
  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'nox_catalog.db');
    try {
      _db = await _open(path);
    } catch (e) {
      // Everything in here is re-derivable from the provider, so a
      // database that won't open is worth strictly less than the cost of
      // not opening it: every catalog read for every playlist fails, and
      // it surfaces as categories that load forever rather than as
      // anything that looks like a storage problem. Start over instead.
      debugPrint('CatalogDatabase: reopening from scratch after $e');
      await deleteDatabase(path);
      _db = await _open(path);
    }
    return _db!;
  }

  Future<Database> _open(String path) async {
    final db = await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vod_channels (
            id TEXT PRIMARY KEY,
            playlist_id TEXT NOT NULL,
            category_name TEXT NOT NULL,
            name TEXT NOT NULL,
            url TEXT NOT NULL,
            logo_url TEXT,
            subtitle_url TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            rating TEXT,
            added_at INTEGER,
            series_id INTEGER,
            series_name TEXT,
            series_cover_url TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_vod_category ON vod_channels(category_name)');
        await db.execute(
            'CREATE INDEX idx_vod_playlist ON vod_channels(playlist_id)');

        await db.execute('''
          CREATE TABLE series_items (
            id TEXT PRIMARY KEY,
            series_id INTEGER NOT NULL,
            playlist_id TEXT NOT NULL,
            category_name TEXT NOT NULL,
            name TEXT NOT NULL,
            cover_url TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            rating TEXT,
            added_at INTEGER
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_series_category ON series_items(category_name)');
        await db.execute(
            'CREATE INDEX idx_series_playlist ON series_items(playlist_id)');
      },
      // v1 -> v2: added series_items.rating.
      // v2 -> v3: added multi-playlist support — playlist_id on both
      // tables, series_items' primary key changed from the bare
      // (not-safely-unique-across-providers) series_id to a real composite
      // string id. Destructive: drop + recreate rather than an ALTER +
      // backfill — this genuinely needed a schema *restructure* (the PK
      // itself changed shape), not just a new column, and this is a fully
      // re-derivable local cache (re-synced from the network the next time
      // each category/playlist loads), not user data.
      // v3 -> v4: added_at on both tables (the "What's New" carousel's sort
      // key). Plain ALTER TABLE ADD COLUMN, NOT drop + recreate — unlike
      // v2 -> v3 there's no structural change here, just one new nullable
      // column, and SQLite defaults an added column to NULL on every
      // existing row for free. A drop + recreate was tried here once and
      // shipped (v3.33.0's initial build): it wiped the *entire* VOD/series
      // cache on every device on first launch, which forced main.dart's
      // bootstrap to block the splash on a full from-scratch network
      // re-fetch of every category, on every platform (phone and TV alike,
      // since CatalogDatabase is shared) — observed directly as a
      // multi-minute stuck splash on real hardware. Existing rows simply
      // get added_at = NULL, which getRecentlyAddedVod/getRecentlyAddedSeries
      // already treat as "nothing to show for this one yet" — exactly the
      // fully-re-derivable-cache reasoning above, just without paying for
      // it by force on every device the moment this ships.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE series_items ADD COLUMN rating TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('DROP TABLE IF EXISTS vod_channels');
          await db.execute('DROP TABLE IF EXISTS series_items');
          await db.execute('''
            CREATE TABLE vod_channels (
              id TEXT PRIMARY KEY,
              playlist_id TEXT NOT NULL,
              category_name TEXT NOT NULL,
              name TEXT NOT NULL,
              url TEXT NOT NULL,
              logo_url TEXT,
              subtitle_url TEXT,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              rating TEXT,
              series_id INTEGER,
              series_name TEXT,
              series_cover_url TEXT
            )
          ''');
          await db.execute(
              'CREATE INDEX idx_vod_category ON vod_channels(category_name)');
          await db.execute(
              'CREATE INDEX idx_vod_playlist ON vod_channels(playlist_id)');
          await db.execute('''
            CREATE TABLE series_items (
              id TEXT PRIMARY KEY,
              series_id INTEGER NOT NULL,
              playlist_id TEXT NOT NULL,
              category_name TEXT NOT NULL,
              name TEXT NOT NULL,
              cover_url TEXT,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              rating TEXT
            )
          ''');
          await db.execute(
              'CREATE INDEX idx_series_category ON series_items(category_name)');
          await db.execute(
              'CREATE INDEX idx_series_playlist ON series_items(playlist_id)');
        }
        if (oldVersion < 4) {
          // Re-runnable on purpose. A migration that throws takes the
          // whole database open down with it, and every catalog read for
          // every playlist with it — which presents as categories that
          // never finish loading rather than as anything database-shaped.
          // This one can genuinely find the column already there: an
          // earlier build of this same version did a drop + recreate that
          // created the tables *with* `added_at`, and a process killed
          // between that statement and sqflite committing the new version
          // number leaves exactly that state behind.
          await _addColumnIfMissing(db, 'vod_channels', 'added_at', 'INTEGER');
          await _addColumnIfMissing(db, 'series_items', 'added_at', 'INTEGER');
        }
      },
    );
    return db;
  }

  /// `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS` in SQLite, and
  /// adding one that's already there throws. Asking the table what it has
  /// first is the only way to make the step idempotent.
  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String type) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((c) => c['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  Map<String, Object?> _channelToRow(String categoryName, Channel c) => {
        'id': c.id,
        'playlist_id': c.playlistId,
        'category_name': categoryName,
        'name': c.name,
        'url': c.url,
        'logo_url': c.logoUrl,
        'subtitle_url': c.subtitleUrl,
        'is_favorite': c.isFavorite ? 1 : 0,
        'rating': c.rating,
        'added_at': c.addedAt?.millisecondsSinceEpoch,
        'series_id': c.seriesId,
        'series_name': c.seriesName,
        'series_cover_url': c.seriesCoverUrl,
      };

  Channel _rowToChannel(Map<String, Object?> row) {
    final id = row['id'] as String;
    final playlistId = row['playlist_id'] as String;
    // Strip the playlist prefix back off — same '$playlistId::$rawId'
    // scheme every id is built with (see Channel.playlistId's doc
    // comment); only the first '::' matters, playlist ids don't contain
    // the delimiter themselves.
    final prefix = '$playlistId::';
    final rawId = id.startsWith(prefix) ? id.substring(prefix.length) : id;
    final addedAt = row['added_at'] as int?;
    return Channel(
      id: id,
      rawId: rawId,
      playlistId: playlistId,
      name: row['name'] as String,
      group: row['category_name'] as String,
      url: row['url'] as String,
      logoUrl: row['logo_url'] as String?,
      subtitleUrl: row['subtitle_url'] as String?,
      isFavorite: (row['is_favorite'] as int) == 1,
      rating: row['rating'] as String?,
      addedAt:
          addedAt != null ? DateTime.fromMillisecondsSinceEpoch(addedAt) : null,
      seriesId: row['series_id'] as int?,
      seriesName: row['series_name'] as String?,
      seriesCoverUrl: row['series_cover_url'] as String?,
    );
  }

  Map<String, Object?> _seriesToRow(String categoryName, XtreamSeries s) => {
        'id': s.id,
        'series_id': s.seriesId,
        'playlist_id': s.playlistId,
        'category_name': categoryName,
        'name': s.name,
        'cover_url': s.coverUrl,
        'is_favorite': s.isFavorite ? 1 : 0,
        'rating': s.rating,
        'added_at': s.addedAt?.millisecondsSinceEpoch,
      };

  XtreamSeries _rowToSeries(Map<String, Object?> row) {
    final addedAt = row['added_at'] as int?;
    return XtreamSeries(
      seriesId: row['series_id'] as int,
      playlistId: row['playlist_id'] as String,
      name: row['name'] as String,
      categoryId: row['category_name'] as String,
      coverUrl: row['cover_url'] as String?,
      isFavorite: (row['is_favorite'] as int) == 1,
      rating: row['rating'] as String?,
      addedAt:
          addedAt != null ? DateTime.fromMillisecondsSinceEpoch(addedAt) : null,
    );
  }

  /// Replaces (not merges) a category's rows — a re-fetch (e.g. "Update
  /// Content") should fully reflect the provider's current item list, not
  /// leave stale rows behind for items the provider removed. Scoped by
  /// `(category_name, playlist_id)` together — deleting by category name
  /// alone would also wipe a different playlist's same-named category.
  Future<void> upsertVodCategory(
      String playlistId, String categoryName, List<Channel> items) async {
    final db = await _database;
    final batch = db.batch();
    batch.delete('vod_channels',
        where: 'category_name = ? AND playlist_id = ?',
        whereArgs: [categoryName, playlistId]);
    for (final c in items) {
      batch.insert('vod_channels', _channelToRow(categoryName, c),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Channel>> getVodCategory(String playlistId, String categoryName,
      {int? limit}) async {
    final db = await _database;
    final rows = await db.query('vod_channels',
        where: 'category_name = ? AND playlist_id = ?',
        whereArgs: [categoryName, playlistId],
        limit: limit);
    return rows.map(_rowToChannel).toList();
  }

  /// The category's *real* item count, ignoring [getVodCategory]'s
  /// `limit` — used so the UI can show a category's true size (a
  /// provider's actual "5,000 movies in this one category" figure)
  /// instead of the display-side render cap, which callers otherwise
  /// have no way to distinguish from the true count (both look like
  /// "here are some items", nothing says "there were more").
  Future<int> getVodCategoryCount(
      String playlistId, String categoryName) async {
    final db = await _database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM vod_channels WHERE category_name = ? AND playlist_id = ?',
        [categoryName, playlistId]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Searches the *entire* local catalog by title, not just whatever
  /// happens to be paged into memory this session — confirmed on real
  /// hardware as a genuine gap: `PlaylistManager.allCachedVod`/
  /// `allCachedSeries` (what `SearchScreen` used to search) only ever
  /// held up to 300 items per category (`_maxItemsPerCategory`, applied
  /// when a category is loaded into memory), even though every item past
  /// that cap was already sitting here in the database the whole time. A
  /// title anywhere past position #300 in a large category (some
  /// providers bundle thousands of items under one category) was
  /// invisible to search even though it was fully synced. Querying here
  /// instead searches everything ever persisted, regardless of that cap
  /// or of which categories happen to be "warmed" into memory right now.
  ///
  /// Filtered in SQL, not by pulling every row into Dart and scanning
  /// there — this catalog can be 100k+ items, and `LIKE` lets SQLite do
  /// that scan natively instead of marshaling the whole table across the
  /// platform channel on every keystroke. `LIKE` is case-insensitive for
  /// plain ASCII letters (not for accented characters — sqflite doesn't
  /// bundle ICU — a known, minor gap versus the old Dart-side
  /// `toLowerCase()` scan, accepted for the much better scalability).
  ///
  /// [playlistIds] restricts results to those playlists — the caller
  /// passes only the currently-*enabled* ones, so a disabled playlist's
  /// stale cached rows don't leak into search results.
  Future<List<Channel>> searchVod(String query, List<String> playlistIds,
      {int limit = 200}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'vod_channels',
      where: 'name LIKE ? AND playlist_id IN ($placeholders)',
      whereArgs: ['%$query%', ...playlistIds],
      limit: limit,
    );
    return rows.map(_rowToChannel).toList();
  }

  /// Category-name substrings the "What's New" carousel refuses to
  /// surface, however recently something in them was added — an
  /// auto-playing slideshow the user didn't ask to browse into is a
  /// different thing from the category existing at all, so this doesn't
  /// hide the category itself (see `PlaylistSession.hiddenGroups` for
  /// that, a separate, deliberate per-category opt-out) — it just keeps
  /// this one uninvited surface from dipping into it. SQLite's `LIKE` is
  /// already case-insensitive for plain ASCII text like these.
  static const _adultCategoryKeywords = ['XXX', 'ADULT', 'PORN', '18+'];

  static String _excludeAdultCategoriesClause() =>
      _adultCategoryKeywords.map((_) => 'category_name NOT LIKE ?').join(' AND ');

  static List<String> _excludeAdultCategoriesArgs() =>
      _adultCategoryKeywords.map((k) => '%$k%').toList();

  /// The newest movies the provider has, newest first — what the TV
  /// layout's "What's New" carousel shows. Scoped to [playlistIds] (the
  /// currently-enabled ones) exactly like [searchVod]; rows with no
  /// `added_at` are skipped outright rather than sorted as if they were
  /// ancient, so a provider that doesn't report the field contributes
  /// nothing here instead of filling the carousel with arbitrary titles.
  Future<List<Channel>> getRecentlyAddedVod(List<String> playlistIds,
      {int limit = 5}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'vod_channels',
      where: 'playlist_id IN ($placeholders) AND added_at IS NOT NULL'
          ' AND ${_excludeAdultCategoriesClause()}',
      whereArgs: [...playlistIds, ..._excludeAdultCategoriesArgs()],
      orderBy: 'added_at DESC',
      limit: limit,
    );
    return rows.map(_rowToChannel).toList();
  }

  Future<void> upsertSeriesCategory(
      String playlistId, String categoryName, List<XtreamSeries> items) async {
    final db = await _database;
    final batch = db.batch();
    batch.delete('series_items',
        where: 'category_name = ? AND playlist_id = ?',
        whereArgs: [categoryName, playlistId]);
    for (final s in items) {
      batch.insert('series_items', _seriesToRow(categoryName, s),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<XtreamSeries>> getSeriesCategory(
      String playlistId, String categoryName,
      {int? limit}) async {
    final db = await _database;
    final rows = await db.query('series_items',
        where: 'category_name = ? AND playlist_id = ?',
        whereArgs: [categoryName, playlistId],
        limit: limit);
    return rows.map(_rowToSeries).toList();
  }

  /// See [searchVod]'s doc comment — same idea for series.
  Future<List<XtreamSeries>> searchSeries(
      String query, List<String> playlistIds,
      {int limit = 200}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'series_items',
      where: 'name LIKE ? AND playlist_id IN ($placeholders)',
      whereArgs: ['%$query%', ...playlistIds],
      limit: limit,
    );
    return rows.map(_rowToSeries).toList();
  }

  /// See [getRecentlyAddedVod]'s doc comment — same idea for series.
  Future<List<XtreamSeries>> getRecentlyAddedSeries(List<String> playlistIds,
      {int limit = 5}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'series_items',
      where: 'playlist_id IN ($placeholders) AND added_at IS NOT NULL'
          ' AND ${_excludeAdultCategoriesClause()}',
      whereArgs: [...playlistIds, ..._excludeAdultCategoriesArgs()],
      orderBy: 'added_at DESC',
      limit: limit,
    );
    return rows.map(_rowToSeries).toList();
  }

  /// See [getVodCategoryCount]'s doc comment — same idea for series.
  Future<int> getSeriesCategoryCount(
      String playlistId, String categoryName) async {
    final db = await _database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM series_items WHERE category_name = ? AND playlist_id = ?',
        [categoryName, playlistId]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Every favorited movie regardless of whether its category has been
  /// opened this session — unlike the old in-memory-scan approach, this
  /// sees the whole catalog since it's a direct query, not a scan of
  /// whatever's currently paged into memory. [playlistIds] restricts to
  /// currently-*enabled* playlists — see [searchVod]'s doc comment.
  Future<List<Channel>> getAllFavoriteVod(List<String> playlistIds) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query('vod_channels',
        where: 'is_favorite = 1 AND playlist_id IN ($placeholders)',
        whereArgs: playlistIds);
    return rows.map(_rowToChannel).toList();
  }

  Future<List<XtreamSeries>> getAllFavoriteSeries(
      List<String> playlistIds) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query('series_items',
        where: 'is_favorite = 1 AND playlist_id IN ($placeholders)',
        whereArgs: playlistIds);
    return rows.map(_rowToSeries).toList();
  }

  Future<void> setVodFavorite(String id, bool value) async {
    final db = await _database;
    await db.update('vod_channels', {'is_favorite': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Keyed by the composite `XtreamSeries.id` now, not the bare (not
  /// safely-unique-across-providers) `seriesId` int.
  Future<void> setSeriesFavorite(String id, bool value) async {
    final db = await _database;
    await db.update('series_items', {'is_favorite': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Deletes every row belonging to one playlist — used when that playlist
  /// is removed entirely (`PlaylistManager.removePlaylist`), so its cached
  /// catalog doesn't linger for a disabled/deleted playlist.
  Future<void> clearForPlaylist(String playlistId) async {
    final db = await _database;
    await db.delete('vod_channels',
        where: 'playlist_id = ?', whereArgs: [playlistId]);
    await db.delete('series_items',
        where: 'playlist_id = ?', whereArgs: [playlistId]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('vod_channels');
    await db.delete('series_items');
  }
}
