import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_profile.dart';
import '../../services/playback_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_panel.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_app_bar_button.dart';
import '../../widgets/tv_switch_list_tile.dart';
import 'add_playlist_screen.dart';
import 'group_management_screen.dart';

/// Replaces the old single-playlist `ContentManagerScreen` — a
/// MyTVOnline3-style list of every playlist (unlimited, not capped),
/// each with its own enable/disable, login, content counts, and full
/// catalog sync cadence. Selecting one drills into [_PlaylistDetailScreen]
/// as its own screen (the reference's list stays visible in a persistent
/// side pane instead) — this app's other Settings screens are all
/// single-column drill-down navigation on both phone and TV, and matching
/// that for the list-to-detail step is simpler and more consistent than a
/// responsive two-pane layout for what's otherwise a small,
/// infrequently-used screen. [_PlaylistDetailScreen] itself *does* use
/// the reference's side-by-side quadrant layout once you're on it though
/// — reported directly: with only a single column, that screen's own
/// content needed scrolling to see all of it despite comfortably fitting
/// a TV-sized screen width-wise.
class PlaylistManagerScreen extends StatelessWidget {
  const PlaylistManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final profiles = playlist.profiles;

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: 'Playlist Manager',
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SettingsPanel(
                    padding: EdgeInsets.zero,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('Add Playlist'),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AddPlaylistScreen())),
                      ),
                      if (profiles.isNotEmpty) const Divider(height: 1),
                      for (var i = 0; i < profiles.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _PlaylistRow(profile: profiles[i]),
                      ],
                    ],
                  ),
                  if (profiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        'No playlists yet — tap "Add Playlist" above to get started.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ));
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.profile});

  final PlaylistProfile profile;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(profile.isXtream ? Icons.dns : Icons.link),
      title: Text(profile.name),
      subtitle: Text(profile.isXtream ? 'Xtream Codes' : 'M3U'),
      trailing: Icon(
        profile.enabled ? Icons.check_circle : Icons.pause_circle_outline,
        color: profile.enabled ? Colors.greenAccent : Colors.white38,
        size: 20,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => _PlaylistDetailScreen(playlistId: profile.id)),
      ),
    );
  }
}

class _PlaylistDetailScreen extends StatefulWidget {
  const _PlaylistDetailScreen({required this.playlistId});

  final String playlistId;

  @override
  State<_PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<_PlaylistDetailScreen> {
  Future<void> _confirmDelete(
      PlaylistManager playlist, PlaylistProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'This removes "${profile.name}"\'s login and cached catalog from this '
          'device. Its favorited channels/movies stay in your shared Favorites '
          'list, but will no longer play unless you add this playlist back.',
        ),
        // Plain TextButton/FilledButton left which one has D-pad focus
        // ambiguous — FilledButton's permanent solid fill looks the same
        // whether it's actually focused or not. ModeButton is this app's
        // established fix elsewhere for exactly this.
        actions: [
          ModeButton(
            label: 'Cancel',
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: 'Delete',
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await playlist.removePlaylist(profile.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    PlaylistProfile? found;
    for (final p in playlist.profiles) {
      if (p.id == widget.playlistId) {
        found = p;
        break;
      }
    }
    if (found == null) {
      // Deleted out from under this screen (e.g. via a race with another
      // route) — nothing left to show, pop back rather than crash on a
      // null profile.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }
    // A separate, genuinely final binding — `found` above is reassigned
    // inside the loop, so Dart won't promote its type across the
    // null-check for the rest of this method.
    final profile = found;

    final summary = playlist.summaryFor(profile.id);
    final lastLoaded = playlist.lastLoadedFor(profile.id);

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: profile.name,
              actions: [
                TvAppBarButton.icon(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit login',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            AddPlaylistScreen(editPlaylistId: profile.id)),
                  ),
                ),
                TvAppBarButton.icon(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete playlist',
                  onTap: () => _confirmDelete(playlist, profile),
                ),
              ],
              // Quadrant layout (Login Details | Content Overview side by
              // side, like the MyTVOnline3 reference this whole screen is
              // modeled on) instead of one long vertical stack — reported
              // directly: everything fit on one already-large TV screen
              // just fine width-wise, so making it scroll vertically to
              // see the rest was wasted space, not a real space
              // constraint. Still wrapped in a scroll view (SingleChildScrollView, not ListView, since
              // there's exactly one child now) as a safety net for a
              // narrow/short viewport, not the primary layout.
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionLabel('This Playlist'),
                          const SizedBox(height: 8),
                          SettingsPanel(
                            padding: EdgeInsets.zero,
                            children: [
                              TvSwitchListTile(
                                title: const Text('Playlist enabled'),
                                subtitle: const Text(
                                  'Frees up this account\'s stream slot for another device — '
                                  'stops playback here immediately, keeps everything else intact.',
                                ),
                                value: profile.enabled,
                                onChanged: (value) {
                                  playlist.setPlaylistEnabled(
                                      profile.id, value);
                                  if (!value) {
                                    context.read<PlaybackService>().stop();
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          const SectionLabel('Login Details'),
                          const SizedBox(height: 8),
                          SettingsPanel(
                            children: [
                              if (profile.isXtream) ...[
                                _DetailRow(
                                    label: 'Server',
                                    value: profile.xtreamServer ?? ''),
                                _DetailRow(
                                    label: 'Username',
                                    value: profile.xtreamUsername ?? ''),
                                _DetailRow(
                                    label: 'Password',
                                    value: '•' *
                                        (profile.xtreamPassword?.length ?? 0)),
                              ] else
                                _DetailRow(
                                    label: 'M3U URL',
                                    value: profile.m3uUrl ?? ''),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionLabel('Content Overview'),
                          const SizedBox(height: 8),
                          SettingsPanel(
                            children: [
                              if (summary == null)
                                const Text('Not loaded yet.')
                              else
                                Text(
                                  profile.isXtream
                                      ? '${summary['tv']} live channels · '
                                          '${summary['vod']} movie categories · '
                                          '${summary['series']} TV show categories'
                                      : '${summary['tv']} live · ${summary['vod']} movies · '
                                          '${summary['series']} TV shows',
                                ),
                              if (lastLoaded != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Last updated: ${DateFormat('yyyy-MM-dd HH:mm').format(lastLoaded)}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                              // Persisted, unlike "Last updated" above
                              // (only ever set in-memory during a live
                              // add/edit — resets to nothing on every
                              // cold restart regardless of which playlist
                              // it is). Reported directly as needed after
                              // several failed add attempts against the
                              // same login silently left duplicate
                              // profiles behind (fixed separately) — with
                              // several identically-named entries and no
                              // "Last updated" to go by post-restart,
                              // there was no way to tell which one was
                              // the original, deliberately-configured
                              // playlist apart from the orphaned retries.
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'Added: ${DateFormat('yyyy-MM-dd HH:mm').format(profile.createdAt)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.visibility_outlined),
                                label: const Text('Group Management'),
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => GroupManagementScreen(
                                          playlistId: profile.id)),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'Hide a group here and it\'s excluded from the background '
                                  'download too, not just the browse tabs.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                          if (profile.isXtream) ...[
                            const SizedBox(height: 20),
                            const SectionLabel('Full Catalog Sync'),
                            const SizedBox(height: 8),
                            SettingsPanel(
                              children: [
                                DropdownButtonFormField<int>(
                                  initialValue: profile.syncFrequencyDays,
                                  decoration: const InputDecoration(
                                    labelText: 'Update content every',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: AppConstants.syncFrequencyDaysOptions
                                      .map((d) => DropdownMenuItem(
                                          value: d,
                                          child: Text(
                                              d == 1 ? '1 day' : '$d days')))
                                      .toList(),
                                  onChanged: (value) {
                                    if (value != null) {
                                      playlist.updatePlaylist(profile.copyWith(
                                          syncFrequencyDays: value));
                                    }
                                  },
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'A stale sync prompts "Update content now?" on launch '
                                    'instead of running automatically.',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ));
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
              child:
                  Text(value, style: const TextStyle(fontFamily: 'monospace'))),
        ],
      ),
    );
  }
}
