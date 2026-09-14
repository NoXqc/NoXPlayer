import 'package:flutter/material.dart';

/// A semi-transparent, rounded card grouping a related set of settings
/// rows — the "Login Details"/"Content Overview" panel treatment from the
/// reference screenshot, applied to [ContentManagerScreen]'s existing
/// sections (Playlist Info, Full Catalog Sync, This Device), which
/// already had that exact logical grouping — they just used to render as
/// plain text floating directly on the background with nothing to
/// visually tie each group together.
///
/// A flat white fill at low alpha (rather than `Theme.of(context)
/// .colorScheme.surface`, which is a near-opaque dark color in this app's
/// TV theme) so the panel reads as "a pane of frosted glass over the
/// gradient" — the gradient shows through, tinted, instead of the panel
/// blocking it out with its own solid color.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.children, this.padding = const EdgeInsets.all(16)});

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // A row with its own solid focus fill (TvSwitchListTile, used with
      // zero padding here so it can sit flush against the panel edges)
      // would otherwise square off past these rounded corners.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}
