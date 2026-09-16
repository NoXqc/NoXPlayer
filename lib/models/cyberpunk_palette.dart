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
  });

  /// Stored in prefs — stable even if [label] wording changes later.
  final String id;
  final String label;

  /// Focus fill, selected state, primary glow — for every palette except
  /// [isMinimal] ones, where these stay reserved for the NoXPlayer
  /// wordmark specifically (see `_TvTopBar`) rather than the theme's own
  /// derived `ColorScheme.primary`/`.secondary`, which [withTvThemeIfNeeded]
  /// substitutes a neutral white/light-gray pair for instead.
  final Color primary;

  /// Gradient partner, badges, secondary glow.
  final Color secondary;

  /// True for the single "Minimalist" palette: flat black backgrounds
  /// (no duo-tone gradient) and a translucent white "glass" focus style
  /// instead of every other palette's solid, saturated fill — see
  /// [withTvThemeIfNeeded] and `SettingsGradientBackground`. [primary]/
  /// [secondary] are still real colors on this palette (not black/white)
  /// specifically so the wordmark keeps its own accent regardless of
  /// which palette is active.
  final bool isMinimal;
}
