import 'package:cached_network_image/cached_network_image.dart';
// `file`'s own `FileSystem` isn't used here — just `File`/`LocalFileSystem`
// — and it collides with flutter_cache_manager's identically-named
// abstract class below, which is the one actually being implemented.
import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// `CachedNetworkImage`'s own default cache manager splits its cache
/// across two different kinds of storage in a way that quietly breaks on
/// Android: the cache *index* (which URL maps to which file, and whether
/// it's still fresh) lives under `getApplicationSupportDirectory()` — a
/// location the OS never touches on its own — but the actual cached
/// image *files* live under `getTemporaryDirectory()`, which on Android
/// is `context.cacheDir`: storage the OS is explicitly documented to
/// reclaim under its own judgment, independent of anything the app does,
/// and does so more aggressively the less free storage a device has.
///
/// Confirmed directly on a real box: posters already fetched and shown
/// once still had to be re-downloaded from scratch after nothing more
/// than an ordinary force-stop/relaunch — no uninstall, no manual cache
/// clear. The index still said "cached"; the actual file the OS had
/// already reclaimed simply wasn't there anymore, so every poster paid
/// its full first-load network cost again on every cold start, not just
/// the first one ever.
///
/// Fix: point the cache's files at the *same* kind of storage its own
/// index already correctly uses, so both live or die together instead of
/// silently drifting out of sync. Installed once in main.dart, before
/// `runApp`, as [CachedNetworkImageProvider.defaultCacheManager] — every
/// `CachedNetworkImage` in the app already goes through that static
/// field whenever it isn't given a `cacheManager:` of its own, so no
/// individual call site needs to change.
final CacheManager persistentImageCacheManager = CacheManager(
  Config('noxplayer_posters', fileSystem: _PersistentFileSystem('noxplayer_posters')),
);

/// Identical to `flutter_cache_manager`'s own default `IOFileSystem`,
/// except rooted at [getApplicationSupportDirectory] instead of
/// [getTemporaryDirectory] — see this file's doc comment for why that's
/// the one thing that actually needed to change.
class _PersistentFileSystem implements FileSystem {
  _PersistentFileSystem(this._cacheKey) : _fileDir = _createDirectory(_cacheKey);

  final String _cacheKey;
  final Future<Directory> _fileDir;

  static Future<Directory> _createDirectory(String key) async {
    final baseDir = await getApplicationSupportDirectory();
    final path = p.join(baseDir.path, key);
    const fs = LocalFileSystem();
    final directory = fs.directory(path);
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<File> createFile(String name) async {
    final directory = await _fileDir;
    if (!(await directory.exists())) {
      await _createDirectory(_cacheKey);
    }
    return directory.childFile(name);
  }
}
