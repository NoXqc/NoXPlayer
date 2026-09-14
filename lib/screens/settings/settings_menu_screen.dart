import 'package:flutter/material.dart';

import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';
import 'add_playlist_screen.dart';
import 'check_updates_screen.dart';
import 'content_manager_screen.dart';
import 'epg_settings_screen.dart';
import 'theme_screen.dart';

/// Settings entry point — a plain menu of destinations instead of one long
/// scrollable form. Much easier to navigate with a D-pad (a handful of big
/// rows, not a dense form with several text fields packed in), and each
/// destination stays focused on one concern.
///
/// No custom D-pad handling here at all, deliberately — every custom
/// Up/Down interception tried on this app's Settings screens (a
/// `DpadVerticalNav` using `FocusScope.nextFocus()`, then an
/// `ExplicitFocusOrder` using an explicit node list, several dispatch
/// mechanisms) was reported as unreliable on real hardware, while
/// `GroupManagementScreen`'s checkbox lists — which never had any custom
/// Up/Down code — were confirmed working flawlessly on the same remote.
/// Plain Flutter default focus traversal turned out to be the answer all
/// along; every row below is a single, ordinary focusable widget in
/// simple top-to-bottom document order, exactly like that working list.
class SettingsMenuScreen extends StatelessWidget {
  const SettingsMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(context, (context) => SettingsScaffold(
      title: 'Settings',
      body: ListView(
        children: [
          _MenuTile(
            icon: Icons.playlist_add,
            title: 'Add Playlist',
            subtitle: 'M3U URL or Xtream Codes login',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AddPlaylistScreen())),
          ),
          _MenuTile(
            icon: Icons.video_library_outlined,
            title: 'Content Manager',
            subtitle: 'Playlist info, groups, enable/disable',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ContentManagerScreen())),
          ),
          _MenuTile(
            icon: Icons.palette_outlined,
            title: 'Theme',
            subtitle: 'Dark mode, clock, accent color, layout',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ThemeScreen())),
          ),
          _MenuTile(
            icon: Icons.calendar_month_outlined,
            title: 'EPG',
            subtitle: 'Auto-refresh, update now, clear cache',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const EpgSettingsScreen())),
          ),
          _MenuTile(
            icon: Icons.system_update_outlined,
            title: 'Check for Updates',
            subtitle: 'Download and install the latest release',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const CheckUpdatesScreen())),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Build: ${AppConstants.buildMarker}',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'Report bugs to: noxqcx@gmail.com',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ),
    ));
  }
}

class _MenuTile extends StatefulWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_MenuTile> createState() => _MenuTileState();
}

class _MenuTileState extends State<_MenuTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // ListTile's own focus overlay is a translucent tint blended under
    // the label — stays subtle at any alpha. An explicit solid tileColor
    // on focus (same treatment as _SelectableRow elsewhere) is what
    // actually reads as "obvious" from a couch.
    return ListTile(
      onFocusChange: (f) => setState(() => _focused = f),
      tileColor: _focused ? scheme.primary : null,
      leading: CircleAvatar(
        backgroundColor: _focused ? scheme.onPrimary.withValues(alpha: 0.2) : scheme.primary.withValues(alpha: 0.16),
        foregroundColor: _focused ? scheme.onPrimary : scheme.primary,
        child: Icon(widget.icon),
      ),
      title: Text(widget.title, style: TextStyle(color: _focused ? scheme.onPrimary : null)),
      subtitle: Text(
        widget.subtitle,
        style: TextStyle(color: _focused ? scheme.onPrimary.withValues(alpha: 0.85) : null),
      ),
      trailing: Icon(Icons.chevron_right, color: _focused ? scheme.onPrimary : null),
      onTap: widget.onTap,
    );
  }
}
