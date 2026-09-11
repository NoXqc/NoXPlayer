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
  });

  /// Stored in prefs — stable even if [label] wording changes later.
  final String id;
  final String label;

  /// Focus fill, selected state, primary glow.
  final Color primary;

  /// Gradient partner, badges, secondary glow.
  final Color secondary;
}
