import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// A single-focus-target replacement for one `SegmentedButton` segment.
/// `SegmentedButton` wraps its segments in their own internal
/// focus-traversal handling that doesn't reliably follow a screen's plain
/// top-to-bottom document order — reported directly as making D-pad
/// navigation into a form erratic ("click multiple times down up down
/// up... got lucky"). A row of these behaves exactly like every other
/// row on a settings screen: one focusable stop per option, in the order
/// they're laid out. Same visual language as `TvHomeScreen`'s
/// `_SelectableRow`: a solid fill on focus, distinct from the outline
/// used for "this is the currently selected option."
class ModeButton extends StatefulWidget {
  const ModeButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.focusNode,
  });

  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<ModeButton> createState() => _ModeButtonState();
}

class _ModeButtonState extends State<ModeButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Every palette now gets the same contour + gradient-sheen treatment
    // — see `TvHomeScreen._SelectableRow`'s doc comment for the full
    // story. Originally Dark/Gold-only: confirmed directly on real
    // hardware that a solid opaque fill reads "creamy"/pastel across a
    // wide button; `LiveResumeHint`'s pill look (near-black fill, a crisp
    // bright border, accent-colored text) reused here instead of a flood
    // fill. Selection and live focus both become border-only; a soft
    // glow (the outer Container below) is the one thing that still tells
    // "the D-pad cursor is here" apart from merely "this is the selected
    // option" without falling back to a fill. Minimalist's previous
    // translucent-glass alternative is retired in favor of this — its
    // `scheme.primary` already resolves to white (see
    // `buildPaletteColorScheme`), so no palette-specific branching is
    // needed here at all.
    final focusForeground = scheme.primary;
    final borderSide = _focused
        ? BorderSide(color: scheme.primary, width: 2)
        : BorderSide(
            color: widget.selected ? scheme.primary : scheme.outline,
            width: widget.selected ? 1.5 : 1);
    return Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment has
      // the full story on why changing a focus widget's ancestor shape
      // between builds corrupts its FocusNode on real hardware; the same
      // rule applies here, one level up.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        // A flat `black87` fill here photographed as more "filled" than
        // the real diagonal sheen `_SelectableRow`/`_GroupRow` use for the
        // exact same focus state — see their doc comment. `Material.color`
        // stays transparent below to let this show through.
        gradient: _focused
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.black,
                  Color.lerp(Colors.black, scheme.primaryContainer, 0.4)!,
                  Colors.black,
                ],
                stops: const [0.0, 0.5, 1.0],
              )
            : null,
        boxShadow: _focused
            ? [
                BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.45),
                    blurRadius: 14)
              ]
            : const [],
      ),
      // MinimalGlassFocus's own blur special-case is retired now that
      // every palette uses the gradient-sheen above instead (`active`
      // stays false) — the wrapper itself stays, unchanged, since
      // removing it would itself be exactly the kind of ancestor-shape
      // change its own doc comment warns against.
      child: MinimalGlassFocus(
        active: false,
        borderRadius: 8,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: borderSide,
          ),
          child: InkWell(
            focusNode: widget.focusNode,
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    // `scheme.tertiary` — a dedicated icon/symbol-glyph
                    // accent, separate from the text/border/gradient
                    // accent (`focusForeground`) — see
                    // `buildPaletteColorScheme`'s own doc comment for why
                    // (Habs: white contour/text, blue icons).
                    Icon(widget.icon,
                        size: 18, color: _focused ? scheme.tertiary : null),
                    const SizedBox(width: 8),
                  ],
                  Text(widget.label,
                      style:
                          TextStyle(color: _focused ? focusForeground : null)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
