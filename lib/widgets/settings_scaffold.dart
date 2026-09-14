import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';

/// Every Settings-family screen's background used to be whatever flat,
/// near-black surface `ThemeData.scaffoldBackgroundColor` happened to
/// resolve to — reported directly as looking like a plain terminal,
/// nothing like the rest of this app's own "cyberpunk" duo-tone identity
/// (already named on [CyberpunkPalette] itself: `secondary`'s doc comment
/// literally says "gradient partner", a use this was the first screen to
/// actually act on). A reference screenshot of another player's Settings
/// (bright saturated blue gradient, white pill for the focused row, no
/// separate app-bar color break) is the direct inspiration here.
///
/// A `Stack` with the gradient painted behind a fully transparent
/// `Scaffold` — rather than `Scaffold.backgroundColor` alone — so the
/// *app bar* shares the exact same gradient instead of sitting in its own
/// flat-colored strip above it, matching that reference's borderless
/// look. Every Settings screen should use this instead of building its
/// own `Scaffold` directly, the same "fix the look once, centrally"
/// approach `SectionLabel`/`_SelectableRow` already use elsewhere.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({super.key, required this.title, required this.body, this.actions, this.bottom});

  final String title;
  final Widget body;
  final List<Widget>? actions;

  /// For screens that need a TabBar in the app bar (Group Management) —
  /// kept optional since most Settings screens don't.
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: _SettingsGradientBackground()),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: Text(title),
            actions: actions,
            bottom: bottom,
          ),
          body: body,
        ),
      ],
    );
  }
}

/// Standalone so [GroupManagementScreen] (which needs its own `PopScope`
/// wrapping the whole `Scaffold`, not just this background) can paint the
/// identical gradient without going through [SettingsScaffold] itself.
class SettingsGradientBackground extends StatelessWidget {
  const SettingsGradientBackground({super.key});

  @override
  Widget build(BuildContext context) => const _SettingsGradientBackground();
}

class _SettingsGradientBackground extends StatelessWidget {
  const _SettingsGradientBackground();

  @override
  Widget build(BuildContext context) {
    final palette = context.watch<AppPreferences>().palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // Blended toward black rather than used at full saturation —
          // this still has to sit *behind* plain white body text on
          // every screen it's used on, at every point in the gradient,
          // not just the corners. Reference image's own brightest corner
          // reads as a fairly deep, saturated blue for exactly the same
          // reason, not a pastel.
          colors: [
            Color.lerp(palette.primary, Colors.black, 0.35)!,
            Color.lerp(palette.secondary, Colors.black, 0.65)!,
          ],
        ),
      ),
    );
  }
}
