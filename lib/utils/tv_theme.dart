import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/cyberpunk_palette.dart';
import '../services/app_preferences.dart';
import 'constants.dart';

/// Shared by both `main.dart`'s root `MaterialApp.theme` and
/// [withTvThemeIfNeeded] below — having two separate copies of the
/// Minimalist-palette override is exactly how it went missing from the
/// root theme the first time (reported directly: `TvHomeScreen`'s own
/// sidebar still rendered solid purple, because it inherits the root
/// theme, built via `colorSchemeSeed: prefs.palette.primary` directly,
/// not this file's own override).
ColorScheme buildPaletteColorScheme(
    CyberpunkPalette palette, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  if (palette.trueBlack) {
    // Same reasoning as the isMinimal branch below (its own comment has the
    // full story): skip ColorScheme.fromSeed entirely rather than let its
    // HCT tonal derivation mute a saturated accent, and keep surfaceTint
    // transparent so no elevated surface picks up a stray hue wash.
    //
    // Deliberately `primary: palette.primary`, NOT `palette.highlight` —
    // confirmed directly on real hardware as "looks like a Game Boy":
    // scheme.primary gets painted as a full solid fill across wide areas
    // (the selected sidebar tab, every simultaneous "now playing" guide
    // badge via primaryContainer below) — the same role white plays for
    // the Habs palette, i.e. it needs to be the *strong, saturated* color,
    // not a pale tint. `highlight` (the bright champagne shine) stays out
    // of the ColorScheme entirely here and is used only where it's
    // genuinely decorative — the wordmark's gradient middle stop
    // (`_TvTopBar` reads `palette.highlight` directly) — rather than
    // flooding every focus/selected/"now" surface with a pastel wash.
    const onFocus = Color(0xFF1A1203);
    final base = isDark ? const ColorScheme.dark() : const ColorScheme.light();
    return base.copyWith(
      primary: palette.primary,
      onPrimary: onFocus,
      // `primaryContainer` is this app's dedicated gradient-sheen accent
      // (kept separate from `primary`, which drives the focus
      // border/text) — matches `primary` here, same as every palette
      // below, since gold has no highlight substitute to diverge from.
      primaryContainer: palette.primary,
      onPrimaryContainer: palette.primary,
      secondary: palette.secondary,
      onSecondary: Colors.white,
      secondaryContainer: palette.secondary.withValues(alpha: 0.18),
      onSecondaryContainer: palette.secondary,
      // `tertiary` is this app's dedicated icon/symbol-glyph accent (kept
      // separate from `primary`, which drives the focus border/gradient/
      // text) — matches `primary` here, same as every palette below,
      // since gold has no highlight substitute to diverge from.
      tertiary: palette.primary,
      surface: isDark ? Colors.black : Colors.white,
      surfaceTint: Colors.transparent,
    );
  }
  if (!palette.isMinimal) {
    final seeded =
        ColorScheme.fromSeed(seedColor: palette.primary, brightness: brightness)
            .copyWith(secondary: palette.secondary);
    final hasHighlight = palette.highlight != null;
    // A palette using `highlight` (currently only Habs) used to have
    // `primary` substituted with that neutral stand-in (white) for the
    // focus border/gradient/text — reverted per direct feedback: "make
    // the selector red all along with the contour, there is already a
    // lot of white... red contour and inside gradient red." Explicitly
    // `palette.primary` (the raw hex), not `seeded.primary` (the
    // HCT-derived tone `ColorScheme.fromSeed` would otherwise give it) —
    // same reasoning as Dark/Gold's own fix: HCT tonal derivation can
    // mute a saturated accent in dark mode.
    return seeded.copyWith(
      primary: hasHighlight ? palette.primary : seeded.primary,
      onPrimary: hasHighlight ? Colors.white : seeded.onPrimary,
      // `tertiary`: this app's dedicated icon/symbol-glyph accent — for a
      // highlight palette, icons carry the palette's *other* brand color
      // (secondary) instead, so they read distinctly from the
      // border/gradient/text (still primary/red) — confirmed directly:
      // "the symbols and logos blue." For every palette without a
      // highlight substitute, this still matches `primary` exactly (no
      // visible change).
      tertiary: hasHighlight ? palette.secondary : seeded.primary,
      // `primaryContainer`: this app's dedicated gradient-sheen accent —
      // now the same color as `primary` everywhere (border and gradient
      // both red for Habs), per the direct feedback above.
      primaryContainer: hasHighlight ? palette.primary : seeded.primary,
    );
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
  final neutral = isDark ? Colors.white : Colors.black;
  final neutralDim = isDark ? Colors.white70 : Colors.black54;
  final onNeutral = isDark ? Colors.black : Colors.white;
  final base = isDark ? const ColorScheme.dark() : const ColorScheme.light();
  return base.copyWith(
    primary: neutral,
    onPrimary: onNeutral,
    // Same dedicated gradient-sheen accent as every other palette — see
    // the non-minimal branch's own comment. Matches `primary` here too
    // (no highlight substitute for Minimalist to diverge from).
    primaryContainer: neutral,
    onPrimaryContainer: neutral,
    secondary: neutralDim,
    onSecondary: onNeutral,
    secondaryContainer: neutral.withValues(alpha: 0.12),
    onSecondaryContainer: neutral,
    // Same dedicated icon/symbol-glyph accent as every other palette —
    // see the non-minimal branch's own comment. Matches `primary` here
    // too (no highlight substitute for Minimalist to diverge from).
    tertiary: neutral,
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
      outlinedButtonTheme:
          OutlinedButtonThemeData(style: _tvButtonStyle(scheme)),
      filledButtonTheme: FilledButtonThemeData(style: _tvButtonStyle(scheme)),
      textButtonTheme: TextButtonThemeData(style: _tvButtonStyle(scheme)),
      // Plain `IconButton`s (player bar: Recall, Favorite, Reload,
      // Pause/skip) had no theme of their own, so they fell back to
      // Flutter's stock `IconButton` focus treatment — the same weak
      // translucent `focusColor` overlay already fixed for every other
      // button type above, for the exact same reported reason. Reusing
      // `_tvButtonStyle` directly keeps this consistent with the rest of
      // the app rather than inventing a second "obvious focus" look.
      // `isIcon: true` — its content is a glyph, not a label, so it gets
      // the dedicated icon/symbol accent (`scheme.tertiary`) instead of
      // `scheme.primary` — see `buildPaletteColorScheme`'s own doc
      // comment for why (Habs: white contour/text, blue icons).
      iconButtonTheme:
          IconButtonThemeData(style: _tvButtonStyle(scheme, isIcon: true)),
    ),
    child: Builder(builder: builder),
  );
}

/// Every palette now gets the same border + accent-colored text focus
/// treatment — see `TvHomeScreen._SelectableRow`'s doc comment for the
/// full story (originally Dark/Gold-only, since a solid fill reads
/// "creamy"/pastel; `LiveResumeHint`'s near-black-fill + bright-border
/// pill look reused here instead). `ButtonStyle.backgroundColor` can't
/// paint a gradient like `_SelectableRow`/`_GroupRow` do for this same
/// state, so this stays transparent — the border + glow (added by each
/// consuming theme's `focusColor`, already set above) carry it instead.
ButtonStyle _tvButtonStyle(ColorScheme scheme, {bool isIcon = false}) {
  const focusFill = Colors.transparent;
  final focusForeground = isIcon ? scheme.tertiary : scheme.primary;
  final focusBorder = scheme.primary;
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
