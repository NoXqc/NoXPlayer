import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/app_preferences.dart';
import '../../services/playback_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_panel.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_switch_list_tile.dart';
import 'group_management_screen.dart';

/// Playlist info (what's loaded, when), a link into Group Management (the
/// content filter — hide a group and it's genuinely never fetched), how
/// often the full catalog sync runs, and the enable/disable toggle for
/// freeing up a provider's connection slot for another device.
///
/// No custom D-pad handling — see SettingsMenuScreen's doc comment for
/// why: plain Flutter default focus traversal is what actually works
/// reliably on real remote hardware here.
class ContentManagerScreen extends StatefulWidget {
  const ContentManagerScreen({super.key});

  @override
  State<ContentManagerScreen> createState() => _ContentManagerScreenState();
}

class _ContentManagerScreenState extends State<ContentManagerScreen> {
  late int _syncFrequencyDays;

  @override
  void initState() {
    super.initState();
    _syncFrequencyDays = context.read<StorageService>().getSyncFrequencyDays();
  }

  Future<void> _applySyncFrequency(int days) async {
    setState(() => _syncFrequencyDays = days);
    await context.read<StorageService>().setSyncFrequencyDays(days);
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final prefs = context.watch<AppPreferences>();
    final storage = context.read<StorageService>();
    final lastFullSync = storage.getLastFullSyncAt();

    return withTvThemeIfNeeded(context, (context) => SettingsScaffold(
      title: 'Content Manager',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionLabel('Playlist Info'),
          const SizedBox(height: 8),
          SettingsPanel(
            children: [
              if (playlist.lastLoadSummary == null)
                const Text('No playlist loaded yet.')
              else
                Text(
                  playlist.isXtream
                      ? '${playlist.lastLoadSummary!['tv']} live channels · '
                          '${playlist.lastLoadSummary!['vod']} movie categories · '
                          '${playlist.lastLoadSummary!['series']} TV show categories'
                      : '${playlist.lastLoadSummary!['tv']} live · '
                          '${playlist.lastLoadSummary!['vod']} movies · '
                          '${playlist.lastLoadSummary!['series']} TV shows',
                ),
              if (playlist.lastLoaded != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Last updated: ${DateFormat('yyyy-MM-dd HH:mm').format(playlist.lastLoaded!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Group Management'),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const GroupManagementScreen())),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Hide a group here and it\'s excluded from the background catalog '
                  'download too, not just from the browse tabs. Show a hidden group '
                  'again and it starts fetching right away — no need to wait for '
                  '"Update content".',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (playlist.isXtream) ...[
            const SizedBox(height: 20),
            const SectionLabel('Full Catalog Sync'),
            const SizedBox(height: 8),
            SettingsPanel(
              children: [
                DropdownButtonFormField<int>(
                  initialValue: _syncFrequencyDays,
                  decoration: const InputDecoration(
                    labelText: 'Update content every',
                    border: OutlineInputBorder(),
                  ),
                  items: AppConstants.syncFrequencyDaysOptions
                      .map((d) => DropdownMenuItem(value: d, child: Text(d == 1 ? '1 day' : '$d days')))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) _applySyncFrequency(value);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    lastFullSync == null
                        ? 'Full catalog sync never completed yet.'
                        : 'Last full sync: ${DateFormat('yyyy-MM-dd HH:mm').format(lastFullSync)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'A stale sync shows a brief "Update content now?" prompt on launch '
                    'instead of running automatically — everyday launches in between '
                    'open straight in with no wait.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          const SectionLabel('This Device'),
          const SizedBox(height: 8),
          SettingsPanel(
            padding: EdgeInsets.zero,
            children: [
              TvSwitchListTile(
                title: const Text('Playlist enabled'),
                subtitle: const Text(
                  'Turn off to free up this account\'s stream slot for another '
                  'device — stops playback here immediately, keeps everything '
                  'else (catalog, favorites, login) intact.',
                ),
                value: prefs.playlistEnabled,
                onChanged: (value) {
                  prefs.setPlaylistEnabled(value);
                  if (!value) context.read<PlaybackService>().stop();
                },
              ),
            ],
          ),
        ],
      ),
    ));
  }
}
