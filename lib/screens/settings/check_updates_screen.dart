import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../services/app_update_service.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';

/// Settings > Check for Updates — the in-app replacement for a Play Store
/// auto-update, since this is a sideloaded app with no store distribution.
/// See AppUpdateService's doc comment for the full check/download/install
/// mechanism and its one hard limit: Android itself, not this app, decides
/// whether the actual install step needs a fresh user tap on its own
/// confirmation dialog — nothing past handing the APK to the installer can
/// be automated further.
class CheckUpdatesScreen extends StatefulWidget {
  const CheckUpdatesScreen({super.key});

  @override
  State<CheckUpdatesScreen> createState() => _CheckUpdatesScreenState();
}

enum _Status { idle, checking, upToDate, updateAvailable, downloading, readyToInstall, error }

class _CheckUpdatesScreenState extends State<CheckUpdatesScreen> {
  final _updateService = AppUpdateService();
  String _currentVersion = '';
  _Status _status = _Status.idle;
  UpdateInfo? _update;
  double _downloadProgress = 0;
  String? _errorMessage;
  String? _downloadedApkPath;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _currentVersion = info.version);
    });
  }

  Future<void> _check() async {
    setState(() {
      _status = _Status.checking;
      _errorMessage = null;
    });
    try {
      final update = await _updateService.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _update = update;
        _status = update == null ? _Status.upToDate : _Status.updateAvailable;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _download() async {
    final update = _update;
    if (update == null) return;
    setState(() {
      _status = _Status.downloading;
      _downloadProgress = 0;
    });
    try {
      final file = await _updateService.downloadUpdate(
        update.downloadUrl,
        onProgress: (fraction) {
          if (mounted) setState(() => _downloadProgress = fraction);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadedApkPath = file.path;
        _status = _Status.readyToInstall;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _install() async {
    final path = _downloadedApkPath;
    if (path == null) return;
    final canInstall = await _updateService.canRequestInstalls();
    if (!canInstall) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow installing updates'),
          content: const Text(
            'Android needs one-time permission for NoXPlayer to install an '
            'update it downloaded. The next screen is Android\'s own '
            'settings — turn the toggle on, then come back here and press '
            'Install again.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Open Settings')),
          ],
        ),
      );
      if (proceed == true) await _updateService.requestInstallPermission();
      return;
    }
    await _updateService.installApk(path);
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(context, (context) => SettingsScaffold(
      title: 'Check for Updates',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _currentVersion.isEmpty ? 'Current version: —' : 'Current version: $_currentVersion',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          ..._buildStatusContent(context),
        ],
      ),
    ));
  }

  List<Widget> _buildStatusContent(BuildContext context) {
    switch (_status) {
      case _Status.idle:
        return [
          OutlinedButton.icon(
            icon: const Icon(Icons.system_update),
            label: const Text('Check for Updates'),
            onPressed: _check,
          ),
        ];
      case _Status.checking:
        return [
          const Row(
            children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Checking...'),
            ],
          ),
        ];
      case _Status.upToDate:
        return [
          const Text('You\'re on the latest version.'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _check, child: const Text('Check Again')),
        ];
      case _Status.updateAvailable:
        final update = _update!;
        return [
          Text(
            'Version ${update.version} is available',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (update.releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(update.releaseNotes, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Download & Install'),
            onPressed: _download,
          ),
        ];
      case _Status.downloading:
        return [
          Text('Downloading update... ${(_downloadProgress * 100).toStringAsFixed(0)}%'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null),
        ];
      case _Status.readyToInstall:
        return [
          const Text('Download complete.'),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.install_mobile),
            label: const Text('Install'),
            onPressed: _install,
          ),
          const SizedBox(height: 4),
          Text(
            'Android will ask you to confirm the install — that\'s normal, '
            'not every app can skip it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ];
      case _Status.error:
        return [
          Text('Something went wrong: ${_errorMessage ?? 'unknown error'}',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _check, child: const Text('Try Again')),
        ];
    }
  }
}
