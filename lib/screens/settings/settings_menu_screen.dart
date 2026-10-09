import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_menu_tile.dart';
import 'add_playlist_screen.dart';
import 'check_updates_screen.dart';
import 'epg_settings_screen.dart';
import 'playlist_manager_screen.dart';
import 'profiles_screen.dart';
import 'theme_screen.dart';
import 'tmdb_settings_screen.dart';

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
    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: 'Settings',
              body: ListView(
                children: [
                  TvMenuTile(
                    icon: Icons.playlist_add,
                    title: 'Add Playlist',
                    subtitle: 'M3U URL or Xtream Codes login',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const AddPlaylistScreen())),
                  ),
                  TvMenuTile(
                    icon: Icons.video_library_outlined,
                    title: 'Playlist Manager',
                    subtitle: 'Every playlist: login, groups, enable/disable',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const PlaylistManagerScreen())),
                  ),
                  TvMenuTile(
                    icon: Icons.people_outline,
                    title: 'Profiles',
                    subtitle:
                        'Separate favorites, history & hidden groups per viewer',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const ProfilesScreen())),
                  ),
                  TvMenuTile(
                    icon: Icons.palette_outlined,
                    title: 'Theme',
                    subtitle: 'Clock, accent color, layout',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ThemeScreen())),
                  ),
                  TvMenuTile(
                    icon: Icons.calendar_month_outlined,
                    title: 'EPG',
                    subtitle:
                        'Auto-refresh, channel matching & pairing, clear cache',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const EpgSettingsScreen())),
                  ),
                  TvMenuTile(
                    icon: Icons.movie_filter_outlined,
                    title: 'TMDB (Release Dates)',
                    subtitle: 'Optional key for sorting by real release date',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const TmdbSettingsScreen())),
                  ),
                  TvMenuTile(
                    icon: Icons.system_update_outlined,
                    title: 'Check for Updates',
                    subtitle: 'Download and install the latest release',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const CheckUpdatesScreen())),
                  ),
                  // Reads whatever code is actually running via
                  // PackageInfo (same source CheckUpdatesScreen's
                  // "Current version" line uses) rather than a hand-typed
                  // constant — requested directly, after the previous
                  // buildMarker string (a version number plus a long
                  // hand-maintained per-release changelog) was replaced
                  // with just the line below: "so I can confirm easily
                  // the current version inside the app" needed *some*
                  // version stamp back, just not the changelog text.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (context, snapshot) {
                        final version = snapshot.data?.version;
                        return Text(
                          version == null ? 'Version —' : 'Version $version',
                          style:
                              const TextStyle(fontSize: 11, color: Colors.grey),
                        );
                      },
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      'Report any bugs or glitches to noxqcx@gmail.com',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ));
  }
}
