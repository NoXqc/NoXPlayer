import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/m3u_group.dart';
import '../services/playlist_manager.dart';

/// Left navigation: TV / VOD / Favorites tabs plus a collapsible group list
/// with per-group hide/show toggles. Remote/D-pad friendly — every row is a
/// plain focusable [ListTile] so Android TV/Firestick D-pad navigation works
/// via Flutter's default focus traversal.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.collapsed,
    required this.selectedTab,
    required this.selectedGroup,
    required this.onToggleCollapse,
    required this.onTabChanged,
    required this.onGroupSelected,
  });

  final bool collapsed;
  final String selectedTab;

  /// The whole group, not just its title — group identity is
  /// `(playlistId, title)` now that more than one playlist can exist (two
  /// providers can share a category name), so a bare title alone isn't
  /// enough to know which playlist's `ensureCategoryLoaded`/
  /// `visibleChannels` call this selection actually means.
  final M3uGroup? selectedGroup;
  final VoidCallback onToggleCollapse;
  final ValueChanged<String> onTabChanged;
  final ValueChanged<M3uGroup?> onGroupSelected;

  static const _tabs = ['TV', 'Movies', 'TV Shows', 'Favorites'];
  static const _tabIcons = {
    'TV': Icons.live_tv,
    'Movies': Icons.movie,
    'TV Shows': Icons.video_library,
    'Favorites': Icons.star,
  };

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    // Hidden groups are managed exclusively from Settings > Group
    // Management, which lists everything (including hidden, so you can
    // un-hide it) — this sidebar should only ever show what's visible.
    final groups = switch (selectedTab) {
      'Movies' => playlist.vodGroups,
      'TV Shows' => playlist.seriesGroups,
      _ => playlist.tvGroups,
    }
        .where((g) => !g.isHidden)
        .toList();

    return Column(
      children: [
        IconButton(
          icon: Icon(collapsed ? Icons.chevron_right : Icons.chevron_left),
          tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
          onPressed: onToggleCollapse,
        ),
        const Divider(height: 1),
        for (final tab in _tabs)
          ListTile(
            dense: true,
            leading: Icon(_tabIcons[tab]),
            title: collapsed ? null : Text(tab),
            selected: selectedTab == tab,
            onTap: () => onTabChanged(tab),
          ),
        const Divider(height: 1),
        if (selectedTab == 'Favorites')
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text('Pinned channels', textAlign: TextAlign.center),
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.apps),
                  title: collapsed ? null : const Text('All'),
                  selected: selectedGroup == null,
                  onTap: () => onGroupSelected(null),
                ),
                for (final group in groups)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder),
                    title: collapsed
                        ? null
                        : Text(
                            group.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: group.isHidden
                                  ? Theme.of(context).disabledColor
                                  : null,
                            ),
                          ),
                    selected: selectedGroup?.playlistId == group.playlistId &&
                        selectedGroup?.title == group.title,
                    trailing: collapsed
                        ? null
                        : IconButton(
                            icon: Icon(group.isHidden
                                ? Icons.visibility_off
                                : Icons.visibility),
                            tooltip:
                                group.isHidden ? 'Show group' : 'Hide group',
                            onPressed: () => playlist.toggleGroupHidden(
                                group.playlistId, group.title),
                          ),
                    onTap: () => onGroupSelected(group),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
