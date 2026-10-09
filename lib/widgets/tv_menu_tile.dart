import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// A focus-obvious `ListTile` for a menu-style destination row (an icon, a
/// title, an optional subtitle, a chevron) — originally private to
/// `SettingsMenuScreen`, pulled out here once a second screen
/// (`PlaylistManagerScreen`'s "Add Playlist"/"Playlist Priority" rows)
/// needed the identical look rather than a plain `ListTile` relying on
/// Flutter's own weak default focus overlay (see `_tvButtonStyle`'s doc
/// comment for why that overlay isn't enough on a TV). [leading]/
/// [trailing] let a row that needs something other than the default
/// icon-circle/chevron (`PlaylistManagerScreen`'s enabled/paused status
/// icon, `ProfilePickerScreen`/`ProfilesScreen`'s initial-letter avatar
/// and "currently active" check) reuse this same contour treatment
/// instead of falling back to a bare `ListTile` — confirmed directly as
/// still showing the old translucent pastel wash on real hardware.
class TvMenuTile extends StatefulWidget {
  const TvMenuTile({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.autofocus = false,
    this.enabled = true,
    this.focusNode,
    required this.onTap,
  }) : assert(icon != null || leading != null,
            'TvMenuTile needs either icon or leading');

  final IconData? icon;

  /// Overrides the default icon-in-a-circle built from [icon].
  final Widget? leading;
  final String title;
  final String? subtitle;

  /// Overrides the default chevron. Pass `SizedBox.shrink()` for no
  /// trailing content at all, rather than leaving this unset.
  final Widget? trailing;
  final bool autofocus;

  /// Same meaning as `ListTile.enabled` — dimmed, unfocusable, and
  /// [onTap] never fires (e.g. "this is already the active profile").
  final bool enabled;

  /// Lets a caller drive focus onto this specific row from outside —
  /// `autofocus` only fires once, on this Element's first build, so a
  /// caller that needs to re-focus a *specific* row later (e.g. the
  /// multiview channel picker re-focusing the first result after a group
  /// filter changes) needs a node it can call `.requestFocus()` on
  /// directly, same as `ModeButton`/`_SwitchToLinkedChannelButton`
  /// elsewhere in this app. Null (every existing caller) falls back to an
  /// owned, internal node, unchanged from before.
  final FocusNode? focusNode;
  final VoidCallback onTap;

  @override
  State<TvMenuTile> createState() => _TvMenuTileState();
}

class _TvMenuTileState extends State<TvMenuTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Every palette now gets the same contour + gradient-sheen treatment
    // — see `TvHomeScreen._SelectableRow`'s doc comment for the full
    // story. `ListTile`'s own focus overlay is a translucent tint
    // blended under the label — stays subtle at any alpha. An explicit
    // border + gradient fill on focus (same treatment as `_SelectableRow`
    // elsewhere) is what actually reads as "obvious" from a couch.
    // Minimalist's previous translucent-glass alternative is retired in
    // favor of this — its `scheme.primary` already resolves to white
    // (see `buildPaletteColorScheme`), so no palette-specific branching
    // is needed here at all.
    final focusForeground = scheme.primary;
    return Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment just
      // below has the full story on why changing a focus widget's
      // ancestor shape between builds corrupts its FocusNode on real
      // hardware.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: _focused ? Border.all(color: scheme.primary, width: 2) : null,
        // A flat `black87` fill here photographed as more "filled" than
        // the real diagonal sheen `_SelectableRow`/`_GroupRow` use for the
        // exact same focus state — see their doc comment. `ListTile.
        // tileColor` can't paint a gradient, so this Container paints it
        // instead and `tileColor` below stays transparent to let it show
        // through.
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
        child: ListTile(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          onFocusChange: (f) => setState(() => _focused = f),
          leading: widget.leading ??
              CircleAvatar(
                backgroundColor: _focused
                    ? focusForeground.withValues(alpha: 0.2)
                    : scheme.primary.withValues(alpha: 0.16),
                // `scheme.tertiary` — a dedicated icon/symbol-glyph
                // accent, separate from the text/border/contour accent
                // (`focusForeground`) — see `buildPaletteColorScheme`'s
                // own doc comment for why (Habs: white contour/text,
                // blue icons).
                foregroundColor: scheme.tertiary,
                child: Icon(widget.icon),
              ),
          title: Text(widget.title,
              style: TextStyle(color: _focused ? focusForeground : null)),
          subtitle: widget.subtitle == null
              ? null
              : Text(
                  widget.subtitle!,
                  style: TextStyle(
                      color: _focused
                          ? focusForeground.withValues(alpha: 0.85)
                          : null),
                ),
          trailing: widget.trailing ??
              Icon(Icons.chevron_right,
                  color: _focused ? scheme.tertiary : null),
          onTap: widget.enabled ? widget.onTap : null,
        ),
      ),
    );
  }
}
