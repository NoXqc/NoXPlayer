import 'package:flutter/material.dart';

/// A curated duo-tone accent pair for the TV UI — deliberately two distinct
/// hues (primary + secondary) rather than Material's single-seed tonal
/// ramp, which can't represent "purple *and* magenta" as two intentional
/// accents at once.
class CyberpunkPalette {
  const CyberpunkPalette({
    required this.id,
    required this.label,
    required this.primary,
    required this.secondary,
    this.isMinimal = false,
    this.highlight,
    this.trueBlack = false,
  });

  /// Stored in prefs — stable even if [label] wording changes later.
  final String id;
  final String label;

  /// Focus border/gradient/text accent, for every palette except
  /// [isMinimal] ones, where these stay reserved for the NoXPlayer
  /// wordmark specifically (see `_TvTopBar`) rather than the theme's own
  /// derived `ColorScheme.primary`, which [withTvThemeIfNeeded]
  /// substitutes a neutral white for instead.
  final Color primary;

  /// Gradient partner, badges, secondary glow — and, for a [highlight]
  /// palette (currently only Habs), the dedicated icon/symbol-glyph
  /// accent (`ColorScheme.tertiary`), kept deliberately distinct from
  /// [primary] so icons read as the palette's *other* brand color while
  /// the border/gradient/text stays on [primary] — confirmed directly:
  /// "the symbols and logos blue."
  final Color secondary;

  /// Optional third color for palettes that need one — always the middle
  /// stop of the wordmark and swatch gradients. Habs uses white here so
  /// the wordmark itself is red, white and blue — but, unlike an earlier
  /// version of this palette, [highlight] no longer replaces the theme's
  /// own `ColorScheme.primary`/`.tertiary` (the focus border/gradient/
  /// text every screen reads): that made the gradient-sheen focus
  /// treatment blend toward white instead of Habs' actual red, and read
  /// as "a lot of white" generally. [primary] now drives the focus
  /// border/gradient/text directly for every palette, [highlight] stays
  /// purely the wordmark/swatch decoration. Null for every palette that
  /// doesn't need a third color.
  final Color? highlight;

  /// True for the single "Minimalist" palette: flat black backgrounds
  /// (no duo-tone gradient) and a translucent white "glass" focus style
  /// instead of every other palette's solid, saturated fill — see
  /// [withTvThemeIfNeeded] and `SettingsGradientBackground`. [primary]/
  /// [secondary] are still real colors on this palette (not black/white)
  /// specifically so the wordmark keeps its own accent regardless of
  /// which palette is active.
  final bool isMinimal;

  /// True for palettes whose own accent needs to survive untouched — a
  /// saturated metallic color (gold) gets muted toward olive by
  /// `ColorScheme.fromSeed`'s HCT tonal derivation in dark mode, the same
  /// problem [isMinimal] already had to work around by hand-building its
  /// scheme instead of seeding it (see [buildPaletteColorScheme]). Also
  /// swaps the duo-tone gradient background ([SettingsGradientBackground])
  /// for flat OLED black instead of a heavy accent-to-black wash, same as
  /// [isMinimal]. Unlike [isMinimal], [primary]/[secondary] stay real,
  /// distinct accent colors throughout the theme rather than being
  /// neutralized to white/gray. [highlight] stays unset for this palette
  /// (gold has no second brand color to diverge the icon accent toward —
  /// see [highlight]'s own doc comment) — confirmed directly on real
  /// hardware that a pale highlight painted as a wide solid fill (the
  /// selected tab, every simultaneous "now playing" guide badge) reads
  /// as a washed-out "Game Boy" tint rather than gold, so [primary] — the
  /// more saturated base tone — fills every one of those roles instead.
  final bool trueBlack;
}
