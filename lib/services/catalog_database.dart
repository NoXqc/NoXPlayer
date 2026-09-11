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
class CatalogDatabase {
  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'nox_catalog.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vod_channels (
            id TEXT PRIMARY KEY,
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
        await db.execute('CREATE INDEX idx_vod_category ON vod_channels(category_name)');

        await db.execute('''
          CREATE TABLE series_items (
            series_id INTEGER PRIMARY KEY,
            category_name TEXT NOT NULL,
            name TEXT NOT NULL,
            cover_url TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_series_category ON series_items(category_name)');
      },
    );
    _db = db;
    return db;
  }

  Map<String, Object?> _channelToRow(String categoryName, Channel c) => {
        'id': c.id,
        'category_name': categoryName,
        'name': c.name,
        'url': c.url,
        'logo_url': c.logoUrl,
        'subtitle_url': c.subtitleUrl,
        'is_favorite': c.isFavorite ? 1 : 0,
        'rating': c.rating,
        'series_id': c.seriesId,
        'series_name': c.seriesName,
        'series_cover_url': c.seriesCoverUrl,
      };

  Channel _rowToChannel(Map<String, Object?> row) => Channel(
        id: row['id'] as String,
        name: row['name'] as String,
        group: row['category_name'] as String,
        url: row['url'] as String,
        logoUrl: row['logo_url'] as String?,
        subtitleUrl: row['subtitle_url'] as String?,
        isFavorite: (row['is_favorite'] as int) == 1,
        rating: row['rating'] as String?,
        seriesId: row['series_id'] as int?,
        seriesName: row['series_name'] as String?,
        seriesCoverUrl: row['series_cover_url'] as String?,
      );

  Map<String, Object?> _seriesToRow(String categoryName, XtreamSeries s) => {
        'series_id': s.seriesId,
        'category_name': categoryName,
        'name': s.name,
        'cover_url': s.coverUrl,
        'is_favorite': s.isFavorite ? 1 : 0,
      };

  XtreamSeries _rowToSeries(Map<String, Object?> row) => XtreamSeries(
        seriesId: row['series_id'] as int,
        name: row['name'] as String,
        categoryId: row['category_name'] as String,
        coverUrl: row['cover_url'] as String?,
        isFavorite: (row['is_favorite'] as int) == 1,
      );

  /// Replaces (not merges) a category's rows — a re-fetch (e.g. "Update
  /// Content") should fully reflect the provider's current item list, not
  /// leave stale rows behind for items the provider removed.
  Future<void> upsertVodCategory(String categoryName, List<Channel> items) async {
    final db = await _database;
    final batch = db.batch();
    batch.delete('vod_channels', where: 'category_name = ?', whereArgs: [categoryName]);
    for (final c in items) {
      batch.insert('vod_channels', _channelToRow(categoryName, c),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Channel>> getVodCategory(String categoryName, {int? limit}) async {
    final db = await _database;
    final rows =
        await db.query('vod_channels', where: 'category_name = ?', whereArgs: [categoryName], limit: limit);
    return rows.map(_rowToChannel).toList();
  }

  Future<void> upsertSeriesCategory(String categoryName, List<XtreamSeries> items) async {
    final db = await _database;
    final batch = db.batch();
    batch.delete('series_items', where: 'category_name = ?', whereArgs: [categoryName]);
    for (final s in items) {
      batch.insert('series_items', _seriesToRow(categoryName, s),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<XtreamSeries>> getSeriesCategory(String categoryName, {int? limit}) async {
    final db = await _database;
    final rows =
        await db.query('series_items', where: 'category_name = ?', whereArgs: [categoryName], limit: limit);
    return rows.map(_rowToSeries).toList();
  }

  /// Every favorited movie regardless of whether its category has been
  /// opened this session — unlike the old in-memory-scan approach, this
  /// sees the whole catalog since it's a direct query, not a scan of
  /// whatever's currently paged into memory.
  Future<List<Channel>> getAllFavoriteVod() async {
    final db = await _database;
    final rows = await db.query('vod_channels', where: 'is_favorite = 1');
    return rows.map(_rowToChannel).toList();
  }

  Future<List<XtreamSeries>> getAllFavoriteSeries() async {
    final db = await _database;
    final rows = await db.query('series_items', where: 'is_favorite = 1');
    return rows.map(_rowToSeries).toList();
  }

  Future<void> setVodFavorite(String id, bool value) async {
    final db = await _database;
    await db.update('vod_channels', {'is_favorite': value ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setSeriesFavorite(int seriesId, bool value) async {
    final db = await _database;
    await db.update('series_items', {'is_favorite': value ? 1 : 0},
        where: 'series_id = ?', whereArgs: [seriesId]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('vod_channels');
    await db.delete('series_items');
  }
}
