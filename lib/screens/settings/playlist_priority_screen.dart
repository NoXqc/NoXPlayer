import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_profile.dart';
import '../../services/playlist_manager.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_panel.dart';
import '../../widgets/settings_scaffold.dart';

/// Lets a user with more than one playlist set which one's groups show
/// first in a given tab — independently per tab. Requested directly: an
/// OTT and a TREX playlist where the preferred order for Live TV ("TREX's
/// groups first") was the *opposite* of the preferred order for Movies/
/// TV Shows ("OTT's first"), which `PlaylistProfile.sortOrder`'s single
/// shared order could never express — every merged list (Live, Movies,
/// Shows) used the exact same playlist order before this existed. See
/// `PlaylistProfile.liveSortOrder`'s doc comment for the actual field.
///
/// Up/Down buttons, not drag-to-reorder — this app is D-pad/remote-first
/// (see CLAUDE.md), and a `ReorderableListView`'s drag gesture has no
/// remote-control equivalent at all. A button is just an ordinary
/// focusable/selectable target, the same as everything else here.
class PlaylistPriorityScreen extends StatefulWidget {
  const PlaylistPriorityScreen({super.key});

  @override
  State<PlaylistPriorityScreen> createState() =>
      _PlaylistPriorityScreenState();
}

class _PlaylistPriorityScreenState extends State<PlaylistPriorityScreen> {
  String _tabCategory = 'tv';

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final enabled = playlist.profiles.where((p) => p.enabled).toList()
      ..sort((a, b) =>
          a.sortOrderFor(_tabCategory).compareTo(b.sortOrderFor(_tabCategory)));

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: 'Playlist Priority',
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Which playlist\'s groups show first — set independently '
                    'for each tab below.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ModeButton(
                          label: 'Live TV',
                          selected: _tabCategory == 'tv',
                          onTap: () => setState(() => _tabCategory = 'tv'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ModeButton(
                          label: 'Movies',
                          selected: _tabCategory == 'vod',
                          onTap: () => setState(() => _tabCategory = 'vod'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ModeButton(
                          label: 'TV Shows',
                          selected: _tabCategory == 'series',
                          onTap: () => setState(() => _tabCategory = 'series'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (enabled.length < 2)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Add another enabled playlist to set a priority '
                        'between them.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else ...[
                    SectionLabel(switch (_tabCategory) {
                      'tv' => 'Live TV order',
                      'vod' => 'Movies order',
                      _ => 'TV Shows order',
                    }),
                    const SizedBox(height: 8),
                    SettingsPanel(
                      padding: EdgeInsets.zero,
                      children: [
                        for (var i = 0; i < enabled.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _PriorityRow(
                            profile: enabled[i],
                            position: i + 1,
                            canMoveUp: i > 0,
                            canMoveDown: i < enabled.length - 1,
                            onMoveUp: () => _move(playlist, enabled, i, -1),
                            onMoveDown: () => _move(playlist, enabled, i, 1),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ));
  }

  Future<void> _move(PlaylistManager playlist, List<PlaylistProfile> ordered,
      int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= ordered.length) return;
    final ids = ordered.map((p) => p.id).toList();
    final moved = ids.removeAt(index);
    ids.insert(target, moved);
    await playlist.setCategoryPriority(_tabCategory, ids);
  }
}

class _PriorityRow extends StatelessWidget {
  const _PriorityRow({
    required this.profile,
    required this.position,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final PlaylistProfile profile;
  final int position;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        child: Text('$position', style: const TextStyle(fontSize: 13)),
      ),
      title: Text(profile.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward),
            tooltip: 'Move up',
            onPressed: canMoveUp ? onMoveUp : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward),
            tooltip: 'Move down',
            onPressed: canMoveDown ? onMoveDown : null,
          ),
        ],
      ),
    );
  }
}
