import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/catalog_database.dart';
import '../../services/epg_service.dart';
import '../../services/storage_service.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';

/// No custom D-pad handling — see SettingsMenuScreen's doc comment for
/// why: plain Flutter default focus traversal is what actually works
/// reliably on real remote hardware here.
class EpgSettingsScreen extends StatefulWidget {
  const EpgSettingsScreen({super.key});

  @override
  State<EpgSettingsScreen> createState() => _EpgSettingsScreenState();
}

class _EpgSettingsScreenState extends State<EpgSettingsScreen> {
  late int _refreshInterval;

  @override
  void initState() {
    super.initState();
    _refreshInterval = context.read<StorageService>().getRefreshInterval();
  }

  Future<void> _applyInterval(int minutes) async {
    setState(() => _refreshInterval = minutes);
    final storage = context.read<StorageService>();
    await storage.setRefreshInterval(minutes);
    final epgUrl = storage.getEpgUrl();
    if (epgUrl != null && epgUrl.isNotEmpty && mounted) {
      context.read<EpgService>().startAutoRefresh(minutes, epgUrl);
    }
  }

  Future<void> _updateNow() async {
    final storage = context.read<StorageService>();
    final url = storage.getEpgUrl();
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No EPG URL set yet — add a playlist first.')),
      );
      return;
    }
    await context.read<EpgService>().refresh(url);
  }

  Future<void> _clearCache() async {
    final storage = context.read<StorageService>();
    final catalogDb = context.read<CatalogDatabase>();
    await storage.clearCache();
    // The VOD/series catalog itself lives in its own local database now
    // (not the JSON-file cache `storage.clearCache()` wipes) — see
    // CatalogDatabase's doc comment.
    await catalogDb.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared.')));
  }

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();

    return withTvThemeIfNeeded(context, (context) => Scaffold(
      appBar: AppBar(title: const Text('EPG')),
      body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<int>(
              initialValue: _refreshInterval,
              decoration: const InputDecoration(
                labelText: 'Auto-refresh interval',
                border: OutlineInputBorder(),
              ),
              items: AppConstants.refreshIntervalOptions
                  .map((m) => DropdownMenuItem(value: m, child: Text('$m minutes')))
                  .toList(),
              onChanged: (value) {
                if (value != null) _applyInterval(value);
              },
            ),
            const SizedBox(height: 12),
            Text(
              epg.lastUpdated == null
                  ? 'EPG never updated'
                  : 'EPG last updated: ${DateFormat('yyyy-MM-dd HH:mm').format(epg.lastUpdated!)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: epg.isLoading
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.calendar_month),
              label: const Text('Update EPG Now'),
              onPressed: epg.isLoading ? null : _updateNow,
            ),
            const Divider(height: 32),
            OutlinedButton(
              onPressed: _clearCache,
              child: const Text('Clear Cache'),
            ),
            const SizedBox(height: 4),
            Text(
              'Clears the cached EPG and catalog data — playlist source, '
              'favorites, and group visibility are kept.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
    ));
  }
}
