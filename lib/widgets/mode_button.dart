import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
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
    // Minimalist swaps the solid `scheme.primary` focus fill for a
    // translucent one (matching `_tvButtonStyle`'s glass pattern) — see
    // that function's doc comment for why a flat opaque white fill with
    // computed `onPrimary` text isn't the "glass" look.
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    final useGlass = isMinimal && _focused;
    final focusFill =
        isMinimal ? Colors.white.withValues(alpha: 0.16) : scheme.primary;
    final focusForeground = isMinimal ? Colors.white : scheme.onPrimary;
    return MinimalGlassFocus(
      active: useGlass,
      borderRadius: 8,
      child: Material(
        color: _focused && !useGlass
            ? focusFill
            : (widget.selected ? scheme.primaryContainer : Colors.transparent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
              color: widget.selected ? scheme.primary : scheme.outline),
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
                  Icon(widget.icon,
                      size: 18, color: _focused ? focusForeground : null),
                  const SizedBox(width: 8),
                ],
                Text(widget.label,
                    style: TextStyle(color: _focused ? focusForeground : null)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
