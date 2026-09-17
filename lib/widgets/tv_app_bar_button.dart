import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
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
    // Same Minimalist-aware treatment as ModeButton — a translucent glass
    // fill instead of a flat opaque one for that palette. See ModeButton's
    // own doc comment for why.
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    final useGlass = isMinimal && _focused;
    final focusFill =
        isMinimal ? Colors.white.withValues(alpha: 0.16) : scheme.primary;
    final focusForeground = isMinimal ? Colors.white : scheme.onPrimary;
    final isIcon = widget.icon != null;
    final shape = isIcon ? const CircleBorder() : const StadiumBorder();

    Widget content = isIcon
        ? Icon(widget.icon, color: _focused ? focusForeground : Colors.white)
        : Text(widget.label!,
            style: TextStyle(
                color: _focused ? focusForeground : Colors.white,
                fontWeight: FontWeight.w600));

    Widget button = MinimalGlassFocus(
      active: useGlass,
      borderRadius: isIcon ? 24 : 20,
      child: Material(
        color: _focused && !useGlass ? focusFill : Colors.transparent,
        shape: shape,
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
    );

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}
