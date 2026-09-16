import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/cyberpunk_palette.dart';
import '../services/app_preferences.dart';
import 'constants.dart';

/// Shared by both `main.dart`'s root `MaterialApp.theme`/`darkTheme` and
/// [withTvThemeIfNeeded] below — having two separate copies of the
/// Minimalist-palette override is exactly how it went missing from the
/// root theme the first time (reported directly: `TvHomeScreen`'s own
/// sidebar still rendered solid purple, because it inherits the root
/// theme, built via `colorSchemeSeed: prefs.palette.primary` directly,
/// not this file's own override).
ColorScheme buildPaletteColorScheme(
    CyberpunkPalette palette, Brightness brightness) {
  if (!palette.isMinimal) {
    return ColorScheme.fromSeed(
            seedColor: palette.primary, brightness: brightness)
        .copyWith(secondary: palette.secondary, tertiary: palette.secondary);
  }
  // Deliberately NOT `ColorScheme.fromSeed(seedColor: Colors.white, ...)`
  // — a fully desaturated seed has no real hue for Material's HCT
  // algorithm to derive from, so it silently picked one anyway (a stray
  // blue), which leaked into every color this override doesn't touch:
  // `primaryContainer` rendered as a solid blue "TV" button on the Layout
  // row, and `surfaceTint` washed every elevated Card/AppBar/Scaffold in
  // that same stray hue — reported directly as "still very gray"
  // everywhere, not just an isolated fill. Building from the plain
  // Material baseline scheme and overriding every field real widgets in
  // this app actually read is the only way to guarantee no hidden hue
  // survives.
  final isDark = brightness == Brightness.dark;
  final neutral = isDark ? Colors.white : Colors.black;
  final neutralDim = isDark ? Colors.white70 : Colors.black54;
  final onNeutral = isDark ? Colors.black : Colors.white;
  final base = isDark ? const ColorScheme.dark() : const ColorScheme.light();
  return base.copyWith(
    primary: neutral,
    onPrimary: onNeutral,
    primaryContainer: neutral.withValues(alpha: 0.18),
    onPrimaryContainer: neutral,
    secondary: neutralDim,
    onSecondary: onNeutral,
    secondaryContainer: neutral.withValues(alpha: 0.12),
    onSecondaryContainer: neutral,
    tertiary: neutralDim,
    surface: isDark ? Colors.black : Colors.white,
    surfaceTint: Colors.transparent,
  );
}

/// Real frosted glass — `BackdropFilter` blur + a translucent fill + a
/// crisp bright contour — for the Minimalist palette's focus highlight.
/// A flat translucent tint alone (no blur) was reported directly as
/// reading "gray" rather than glass; this is deliberately heavier than
/// anything else in this app's UI (which otherwise avoids blur/gradient
/// paint effects for cost reasons on weak GPUs — see `_SelectableRow`'s
/// own doc comment on `Ink`). That tradeoff is safe here specifically
/// because a D-pad has exactly one cursor: at most one of these is ever
/// composited on screen at a time, unlike a decoration applied to every
/// row in a scrolling list.
class MinimalGlassFocus extends StatelessWidget {
  const MinimalGlassFocus(
      {super.key,
      required this.active,
      required this.borderRadius,
      required this.child});

  final bool active;
  final double borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // `child` (a Material/InkWell with its own FocusNode, in every real
    // usage) must stay at the exact same slot in the tree whether or not
    // the glass is showing — an early `if (!active) return child` here,
    // tried first, changed the ancestor chain above `child` every time
    // `active` flipped (no `ClipRRect`/`Stack` at all vs. wrapped), which
    // is a widget-type change at that slot, which makes Flutter tear
    // down and rebuild `child`'s whole element subtree (its `FocusNode`
    // included) on every focus change. Confirmed on real hardware as the
    // cause of a real bug: focus visually "duplicating" and getting
    // stuck, unable to advance past a couple of rows. `ClipRRect` >
    // `Stack` > `[decoration, child]` now always exists in that exact
    // shape; only the decorative first Stack entry's own child toggles
    // (cheap — it holds no state), while `child` stays the stable,
    // never-rebuilt second entry.
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: active
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(borderRadius),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.8),
                            width: 1.5),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          child,
        ],
      ),
    );
  }
}

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
          MediaQuery.of(context).size.width >=
              AppConstants.tvLayoutWidthThreshold);
  if (!isTv) return Builder(builder: builder);

  final palette = prefs.palette;
  // The Minimalist palette deliberately does NOT seed the app's whole
  // ColorScheme from its own primary/secondary the way every other
  // palette does — those two colors are reserved for the wordmark alone
  // (see `_TvTopBar`, which reads them from the palette directly, not
  // from this theme). Every other widget in the app that reads
  // `colorScheme.primary`/`.secondary` for a focus/selected-state fill
  // (20+ call sites, from checkboxes to poster borders to the live list)
  // gets this neutral white/light-gray pair instead, for free — the
  // "black background, white lettering" look applies everywhere at once
  // without hand-editing every one of those call sites individually.
  final scheme = buildPaletteColorScheme(palette, Brightness.dark);
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
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: _tvButtonStyle(scheme, isMinimal: palette.isMinimal)),
      filledButtonTheme: FilledButtonThemeData(
          style: _tvButtonStyle(scheme, isMinimal: palette.isMinimal)),
      textButtonTheme: TextButtonThemeData(
          style: _tvButtonStyle(scheme, isMinimal: palette.isMinimal)),
    ),
    child: Builder(builder: builder),
  );
}

ButtonStyle _tvButtonStyle(ColorScheme scheme, {required bool isMinimal}) {
  // Every other palette's focused button is a fully solid fill — already
  // proven as the fix for a real "can't tell where my selector is"
  // complaint (see the comment above), which a translucent glass fill
  // would risk reintroducing. Minimalist keeps that same legibility via
  // a crisp, fully-opaque white border and label instead of relying on
  // fill contrast, so the *fill* itself is free to be genuinely glassy.
  final focusFill =
      isMinimal ? Colors.white.withValues(alpha: 0.16) : scheme.primary;
  final focusForeground = isMinimal ? Colors.white : scheme.onPrimary;
  final focusBorder = isMinimal ? Colors.white : scheme.primary;
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return focusFill;
      return null;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return focusForeground;
      return null;
    }),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused))
        return BorderSide(color: focusBorder, width: 2);
      return null;
    }),
  );
}
