import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// A top-bar action button (back arrow, an icon action, a text action like
/// "Done") with the same real-focus-only solid fill [ModeButton] already
/// established for everything else in this app. Plain `IconButton`/
/// `TextButton` in an `AppBar` use Flutter's own default focus indicator —
/// a faint ripple/overlay that reads as barely visible on this app's dark
/// backgrounds on real remote hardware, reported directly: "the back
/// arrow, edit and delete is barely visible... that's the case for every
/// page." [SettingsScaffold] uses this for its own back arrow so every
/// screen built on it gets the fix at once; screens with their own
/// `actions:` (Edit/Delete in Playlist Manager, Done in Group Management)
/// use it directly in place of the `IconButton`/`TextButton` they had.
class TvAppBarButton extends StatefulWidget {
  const TvAppBarButton.icon({
    super.key,
    required IconData this.icon,
    required this.onTap,
    this.tooltip,
    this.focusNode,
  }) : label = null;

  const TvAppBarButton.label({
    super.key,
    required String this.label,
    required this.onTap,
    this.tooltip,
    this.focusNode,
  }) : icon = null;

  final IconData? icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<TvAppBarButton> createState() => _TvAppBarButtonState();
}

class _TvAppBarButtonState extends State<TvAppBarButton> {
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
    final isIcon = widget.icon != null;
    final shape = isIcon ? const CircleBorder() : const StadiumBorder();
    final focusedShape = isIcon
        ? CircleBorder(side: BorderSide(color: scheme.primary, width: 2))
        : StadiumBorder(side: BorderSide(color: scheme.primary, width: 2));

    // `scheme.tertiary` — a dedicated icon/symbol-glyph accent, separate
    // from the text/border/gradient accent (`focusForeground`) — see
    // `buildPaletteColorScheme`'s own doc comment for why (Habs: white
    // contour/text, blue icons).
    Widget content = isIcon
        ? Icon(widget.icon, color: _focused ? scheme.tertiary : Colors.white)
        : Text(widget.label!,
            style: TextStyle(
                color: _focused ? focusForeground : Colors.white,
                fontWeight: FontWeight.w600));

    Widget button = Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment below
      // has the full story on why changing a focus widget's ancestor
      // shape between builds corrupts its FocusNode on real hardware.
      decoration: BoxDecoration(
        shape: isIcon ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isIcon ? null : BorderRadius.circular(20),
        // A flat `black87` fill here photographed as more "filled" than
        // the real diagonal sheen `_SelectableRow`/`_GroupRow` use for the
        // exact same focus state — see their doc comment.
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
                    blurRadius: 12)
              ]
            : const [],
      ),
      // MinimalGlassFocus's own blur special-case is retired now that
      // every palette uses the gradient-sheen above instead — see
      // ModeButton's identical comment for why the wrapper itself stays.
      child: MinimalGlassFocus(
        active: false,
        borderRadius: isIcon ? 24 : 20,
        child: Material(
          color: Colors.transparent,
          shape: _focused ? focusedShape : shape,
          child: InkWell(
            focusNode: widget.focusNode,
            customBorder: shape,
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            child: Padding(
              padding: isIcon
                  ? const EdgeInsets.all(10)
                  : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: content,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}
