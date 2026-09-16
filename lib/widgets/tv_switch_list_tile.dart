import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';

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
    // Minimalist's `scheme.primary` is plain opaque white (see
    // `withTvThemeIfNeeded`) — used as-is here, `tileColor` would paint a
    // fully solid white block, not the "glass" look the theme is meant to
    // have everywhere else. Same translucent-white-fill + solid-white-text
    // pattern as `_tvButtonStyle` uses for buttons, applied here since a
    // `SwitchListTile` doesn't go through that shared style.
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    final focusFill = isMinimal ? Colors.white.withValues(alpha: 0.16) : scheme.primary;
    final focusForeground = isMinimal ? Colors.white : scheme.onPrimary;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      onFocusChange: (f) => setState(() => _focused = f),
      tileColor: _focused ? focusFill : null,
      title: DefaultTextStyle.merge(
        style: TextStyle(color: _focused ? focusForeground : null),
        child: widget.title,
      ),
      subtitle: widget.subtitle == null
          ? null
          : DefaultTextStyle.merge(
              style: TextStyle(color: _focused ? focusForeground.withValues(alpha: 0.85) : null),
              child: widget.subtitle!,
            ),
      value: widget.value,
      onChanged: widget.onChanged,
    );
  }
}
