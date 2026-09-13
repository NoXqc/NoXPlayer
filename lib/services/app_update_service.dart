import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A GitHub release newer than what's currently installed.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.apkSizeBytes,
  });

  /// The release's tag name (e.g. "3.19.1") — same scheme as the app's own
  /// version, so it's directly comparable via [_isNewer].
  final String version;
  final String releaseNotes;
  final String downloadUrl;
  final int apkSizeBytes;
}

/// Checks GitHub for a newer release, downloads it, and hands it to
/// Android's own package installer — there's no Play Store auto-update for
/// a sideloaded app, so this is the in-app replacement (Settings > Check
/// for Updates). See MainActivity.kt's doc comment for the native half
/// (install permission check + the actual install intent, which needs a
/// FileProvider — no pure-Dart/Flutter-plugin way to trigger an APK
/// install exists).
class AppUpdateService {
  static const _channel = MethodChannel('com.nox.nox_iptv/app_update');

  /// Public, unauthenticated GitHub API — fine for a public repo at this
  /// call volume (a user tapping "Check for Updates" occasionally), no
  /// token needed and none should be embedded in a distributed APK anyway.
  static const _apiUrl = 'https://api.github.com/repos/NoXqc/NoXPlayer/releases/latest';

  /// Null if already up to date, the request fails, or the release has no
  /// `.apk` asset attached (shouldn't happen for a real release, but a
  /// malformed/source-only one shouldn't crash the check).
  Future<UpdateInfo?> checkForUpdate() async {
    final response = await http.get(
      Uri.parse(_apiUrl),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('GitHub returned HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final latestVersion = (decoded['tag_name'] as String?)?.trim();
    if (latestVersion == null || latestVersion.isEmpty) return null;

    final packageInfo = await PackageInfo.fromPlatform();
    if (!_isNewer(latestVersion, packageInfo.version)) return null;

    final assets = (decoded['assets'] as List?) ?? const [];
    final apkAsset = assets.cast<Map<String, dynamic>>().firstWhere(
          (a) => (a['name'] as String?)?.toLowerCase().endsWith('.apk') ?? false,
          orElse: () => const {},
        );
    final downloadUrl = apkAsset['browser_download_url'] as String?;
    if (downloadUrl == null) return null;

    return UpdateInfo(
      version: latestVersion,
      releaseNotes: (decoded['body'] as String?)?.trim() ?? '',
      downloadUrl: downloadUrl,
      apkSizeBytes: (apkAsset['size'] as int?) ?? 0,
    );
  }

  /// Compares two "major.minor.patch"-shaped version strings numerically,
  /// not lexicographically — a plain string compare would wrongly rank
  /// "3.9.2" above "3.10.1" (since '9' > '1' as characters). Treats a
  /// missing/non-numeric segment as 0, so a differently-shaped tag (e.g.
  /// "3.19" vs "3.19.1") still compares sensibly instead of throwing.
  bool _isNewer(String remote, String local) {
    final r = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final l = local.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < r.length || i < l.length; i++) {
      final rPart = i < r.length ? r[i] : 0;
      final lPart = i < l.length ? l[i] : 0;
      if (rPart != lPart) return rPart > lPart;
    }
    return false;
  }

  /// Downloads to the app's own cache directory (matching the
  /// FileProvider path config that grants the installer read access to
  /// exactly this one file, nothing broader) — overwrites any previous
  /// download of the same name rather than accumulating old ones.
  Future<File> downloadUpdate(String downloadUrl, {void Function(double fraction)? onProgress}) async {
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await http.Client().send(request);
    if (response.statusCode != 200) {
      throw Exception('Download failed: HTTP ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'noxplayer_update.apk'));
    final sink = file.openWrite();

    await response.stream.map((chunk) {
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
      return chunk;
    }).pipe(sink);
    await sink.close();

    return file;
  }

  /// Android 8+ only — earlier versions have no per-app "unknown sources"
  /// gate at all. Always true there, so callers don't need to branch on
  /// OS version themselves.
  Future<bool> canRequestInstalls() async {
    final result = await _channel.invokeMethod<bool>('canRequestInstalls');
    return result ?? false;
  }

  /// Opens the system settings screen where the user grants this app
  /// "install unknown apps" access — Android requires this be a real user
  /// action from Settings, no app (this one included) can grant it to
  /// itself. No-op on pre-Android-8, where it isn't needed.
  Future<void> requestInstallPermission() => _channel.invokeMethod('requestInstallPermission');

  /// Hands the downloaded file to the system package installer — this is
  /// the point where the OS's own install-confirmation UI takes over;
  /// nothing past this call can be automated further from inside the app.
  Future<void> installApk(String filePath) => _channel.invokeMethod('installApk', {'filePath': filePath});
}
