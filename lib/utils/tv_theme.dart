import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
import 'constants.dart';

/// Wraps [builder] in the same dark cyberpunk palette [TvHomeScreen] uses
/// when this is running as the TV layout — otherwise returns it unwrapped,
/// so it keeps inheriting the ambient phone theme (which does respect
/// light/dark mode) normally.
///
/// [MovieDetailScreen], [SeriesDetailScreen], [SearchScreen], and
/// [PlayerScreen] are reachable from both [HomeScreen] (phone) and
/// [TvHomeScreen] — without this they'd snap back to the plain Material
/// theme the instant you left the TV browse screen, breaking the look.
/// Uses the exact same `isTv` check as main.dart's own layout switch.
Widget withTvThemeIfNeeded(BuildContext context, WidgetBuilder builder) {
  final prefs = context.watch<AppPreferences>();
  final isTv = prefs.layoutMode == 'tv' ||
      (prefs.layoutMode == 'auto' &&
          MediaQuery.of(context).size.width >= AppConstants.tvLayoutWidthThreshold);
  if (!isTv) return Builder(builder: builder);

  final scheme = ColorScheme.fromSeed(seedColor: prefs.palette.primary, brightness: Brightness.dark)
      .copyWith(secondary: prefs.palette.secondary, tertiary: prefs.palette.secondary);
  return Theme(
    data: ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // Stock Material widgets (ListTile, SwitchListTile, SegmentedButton,
      // plain InkWell) default to a barely-visible focus overlay — fine at
      // arm's length with a mouse, not from a couch with a D-pad. Reported
      // directly: "sometimes bright, sometimes a kind of light selector...
      // you don't know where your selector is." A solid, opaque focus
      // color (rather than the default low-alpha tint) fixes every one of
      // those widgets at once, without rebuilding each of them by hand —
      // the same "fix once centrally" approach as `_SelectableRow`
      // elsewhere, just via the theme instead of a bespoke widget.
      // `ThemeData.focusColor`'s default (`Colors.black12`-ish) is used
      // as-is by consuming widgets, not further blended — so this needs
      // to already be a sensible overlay alpha itself, not the solid
      // palette color, or it'd paint over the label text entirely.
      focusColor: scheme.primary.withValues(alpha: 0.45),
      // Still reported as "not obvious enough" even with the focusColor
      // boost above — that overlay is a translucent tint blended *under*
      // a button's own label/border, which stays subtle regardless of
      // alpha. These react to `WidgetState.focused` directly instead,
      // for a solid fill + thick bright border matching `_SelectableRow`'s
      // treatment elsewhere in the app — the actual "obvious highlight"
      // the Live TV list already has.
      outlinedButtonTheme: OutlinedButtonThemeData(style: _tvButtonStyle(scheme)),
      filledButtonTheme: FilledButtonThemeData(style: _tvButtonStyle(scheme)),
      textButtonTheme: TextButtonThemeData(style: _tvButtonStyle(scheme)),
    ),
    child: Builder(builder: builder),
  );
}

ButtonStyle _tvButtonStyle(ColorScheme scheme) {
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return scheme.primary;
      return null;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return scheme.onPrimary;
      return null;
    }),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return BorderSide(color: scheme.primary, width: 2);
      return null;
    }),
  );
}
