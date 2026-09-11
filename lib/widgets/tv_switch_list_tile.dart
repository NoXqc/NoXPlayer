import 'package:flutter/material.dart';

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
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      onFocusChange: (f) => setState(() => _focused = f),
      tileColor: _focused ? scheme.primary : null,
      title: DefaultTextStyle.merge(
        style: TextStyle(color: _focused ? scheme.onPrimary : null),
        child: widget.title,
      ),
      subtitle: widget.subtitle == null
          ? null
          : DefaultTextStyle.merge(
              style: TextStyle(color: _focused ? scheme.onPrimary.withValues(alpha: 0.85) : null),
              child: widget.subtitle!,
            ),
      value: widget.value,
      onChanged: widget.onChanged,
    );
  }
}
