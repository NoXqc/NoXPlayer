import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// A `SwitchListTile` with an obvious solid-fill focus highlight — see
/// `SettingsMenuScreen`'s `_MenuTile` for why the stock widget's own
/// focus overlay isn't enough on a TV: it's a translucent tint blended
/// under the label, which stays subtle no matter how strong the color.
class TvSwitchListTile extends StatefulWidget {
  const TvSwitchListTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<TvSwitchListTile> createState() => _TvSwitchListTileState();
}

class _TvSwitchListTileState extends State<TvSwitchListTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Every palette now gets the same contour + gradient-sheen treatment
    // — see `TvHomeScreen._SelectableRow`'s doc comment for the full
    // story. Minimalist's previous translucent-glass alternative is
    // retired in favor of this — its `scheme.primary` already resolves
    // to white (see `buildPaletteColorScheme`), so no palette-specific
    // branching is needed here at all.
    final focusForeground = scheme.primary;
    return Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment below
      // has the full story on why changing a focus widget's ancestor
      // shape between builds corrupts its FocusNode on real hardware.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: _focused ? Border.all(color: scheme.primary, width: 2) : null,
        // A flat `black87` fill here photographed as more "filled" than
        // the real diagonal sheen `_SelectableRow`/`_GroupRow` use for the
        // exact same focus state — see their doc comment.
        // `SwitchListTile.tileColor` can't paint a gradient, so this
        // Container paints it instead and `tileColor` below stays
        // transparent to let it show through.
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
                    color: scheme.primary.withValues(alpha: 0.4),
                    blurRadius: 12)
              ]
            : const [],
      ),
      // MinimalGlassFocus's own blur special-case is retired now that
      // every palette uses the gradient-sheen above instead — see
      // ModeButton's identical comment for why the wrapper itself stays.
      child: MinimalGlassFocus(
        active: false,
        borderRadius: 8,
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          onFocusChange: (f) => setState(() => _focused = f),
          title: DefaultTextStyle.merge(
            style: TextStyle(color: _focused ? focusForeground : null),
            child: widget.title,
          ),
          subtitle: widget.subtitle == null
              ? null
              : DefaultTextStyle.merge(
                  style: TextStyle(
                      color: _focused
                          ? focusForeground.withValues(alpha: 0.85)
                          : null),
                  child: widget.subtitle!,
                ),
          value: widget.value,
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}
