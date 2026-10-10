import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
import '../utils/tv_theme.dart';
import '../widgets/mode_button.dart';

/// Shown once, from main.dart's bootstrap gate, the very first time the app
/// launches with zero playlists configured — a brand-new install has no
/// other hint that content lives behind Settings > Playlist Manager rather
/// than just showing up. Modeled directly on [CatalogSyncPromptScreen]: same
/// "runs before the real MaterialApp/theme tree exists, so it carries its
/// own" situation, same reason it reads [AppPreferences.palette] itself
/// instead of inheriting a theme.
class WelcomeAddPlaylistScreen extends StatelessWidget {
  const WelcomeAddPlaylistScreen({super.key, required this.onRespond});

  /// `true` to open [AddPlaylistScreen] right after bootstrap finishes,
  /// `false` to land on the normal (empty) main app — see main.dart's
  /// `_pendingAutoOpenAddPlaylist` for why this can't just push the screen
  /// directly from here (no Navigator exists yet at this point).
  final void Function(bool wantsToAddPlaylist) onRespond;

  @override
  Widget build(BuildContext context) {
    final palette = context.watch<AppPreferences>().palette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: buildPaletteColorScheme(palette, Brightness.dark),
        useMaterial3: true,
      ),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/icon/icon_flat.png',
                      width: 96,
                      height: 96,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Hey beautiful Human,',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const Text(
                    'Welcome to VesperTV',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Add your first playlist?',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Add a playlist to kick things off, or skip for now if '
                    'you just want to browse and discover the app without '
                    'content.',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  // ModeButton over plain Outlined/FilledButton for the same
                  // reason as CatalogSyncPromptScreen — a solid fill *only*
                  // on real D-pad focus, not permanently on one button.
                  SizedBox(
                    width: 320,
                    child: Row(
                      children: [
                        Expanded(
                          child: ModeButton(
                            label: 'Skip for now',
                            selected: false,
                            onTap: () => onRespond(false),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ModeButton(
                            label: 'Add Playlist',
                            selected: false,
                            onTap: () => onRespond(true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
