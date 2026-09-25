import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cyberpunk_palette.dart';
import '../../services/app_preferences.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_switch_list_tile.dart';

/// Appearance + layout — grouped together since "what does this look like"
/// is really one concern spanning theme mode, accent color, and whether
/// the phone or TV presentation is used.
///
/// No custom D-pad handling — see SettingsMenuScreen's doc comment for
/// why: plain Flutter default focus traversal (including its ordinary
/// 2D directional movement into/across the palette swatches and layout
/// buttons below) is what actually works reliably on real remote
/// hardware here.
class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences>();

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: 'Theme',
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TvSwitchListTile(
                    title: const Text('Dark theme'),
                    value: prefs.themeMode == ThemeMode.dark,
                    onChanged: (value) => prefs
                        .setThemeMode(value ? ThemeMode.dark : ThemeMode.light),
                  ),
                  TvSwitchListTile(
                    title: const Text('Show clock'),
                    subtitle:
                        const Text('Displays the current time in the top bar'),
                    value: prefs.showClock,
                    onChanged: prefs.setShowClock,
                  ),
                  const SizedBox(height: 16),
                  const SectionLabel('Theme color'),
                  const SizedBox(height: 4),
                  Text(
                    'Drives the TV browse screens (tabs, groups, catalog) — those '
                    'always stay dark regardless of the switch above, the same '
                    'way most streaming apps do.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final option in AppConstants.cyberpunkPalettes)
                        _PaletteSwatch(
                          palette: option,
                          selected: prefs.palette.id == option.id,
                          onTap: () => prefs.setPalette(option),
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                  const SectionLabel('Layout'),
                  const SizedBox(height: 4),
                  Text(
                    'Auto picks phone vs TV layout by screen size — force one if '
                    'your box isn\'t detected correctly.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  // Was a `SegmentedButton` — replaced since its internal focus
                  // traversal doesn't follow plain document order the way a
                  // regular row of widgets does.
                  Row(
                    children: [
                      for (final option in const [
                        ('auto', 'Auto'),
                        ('phone', 'Phone'),
                        ('tv', 'TV')
                      ]) ...[
                        Expanded(
                          child: ModeButton(
                            label: option.$2,
                            selected: prefs.layoutMode == option.$1,
                            onTap: () => prefs.setLayoutMode(option.$1),
                          ),
                        ),
                        if (option.$1 != 'tv') const SizedBox(width: 12),
                      ],
                    ],
                  ),
                  const Divider(height: 32),
                  const SectionLabel('Live TV guide'),
                  const SizedBox(height: 4),
                  Text(
                    'Timeline shows every channel at once, on a scrollable '
                    'schedule grid, instead of one channel\'s now/next at a time.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final option in const [
                        ('live', 'Live'),
                        ('timeline', 'Timeline')
                      ]) ...[
                        Expanded(
                          child: ModeButton(
                            label: option.$2,
                            selected: prefs.guideViewMode == option.$1,
                            onTap: () => prefs.setGuideViewMode(option.$1),
                          ),
                        ),
                        if (option.$1 != 'timeline') const SizedBox(width: 12),
                      ],
                    ],
                  ),
                ],
              ),
            ));
  }
}

/// A split circle (primary on top-left, secondary on bottom-right) so the
/// duo-tone nature of each palette is visible in the picker itself, not
/// just once applied.
class _PaletteSwatch extends StatefulWidget {
  const _PaletteSwatch({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final CyberpunkPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PaletteSwatch> createState() => _PaletteSwatchState();
}

class _PaletteSwatchState extends State<_PaletteSwatch> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // The static "selected" border/checkmark and the D-pad's current
    // focus were both rendering as "something bright around this
    // swatch" — reported as genuinely confusing ("you're focused on the
    // bright one which isn't even a selection"). A ring in a color
    // neither the palette nor the selected-indicator uses keeps the two
    // facts visually distinct, the same fix already applied to the Live
    // TV channel list earlier this session.
    return InkWell(
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Minimalist keeps its own `primary`/`secondary` as
                // purple/magenta deliberately (see CyberpunkPalette
                // .isMinimal's doc comment — that's the wordmark's own
                // accent, not this theme's real look), so the swatch here
                // needs its own black/white gradient instead of those
                // fields directly — reported directly as otherwise
                // rendering identically to the actual Purple/Magenta
                // swatch right next to it, with nothing to tell them
                // apart in the picker itself.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.palette.isMinimal
                      ? [Colors.black, Colors.white]
                      : [
                          widget.palette.primary,
                          if (widget.palette.highlight != null)
                            widget.palette.highlight!,
                          widget.palette.secondary,
                        ],
                ),
                border: widget.selected
                    ? Border.all(
                        color: Theme.of(context).colorScheme.onSurface,
                        width: 3)
                    : null,
                boxShadow: _focused
                    ? [
                        const BoxShadow(
                            color: Colors.white, blurRadius: 0, spreadRadius: 3)
                      ]
                    : null,
              ),
              // A plain white checkmark disappears against the white half
              // of Minimalist's new black/white gradient — a dark shadow
              // keeps it visible regardless of which half it lands on,
              // same "readable over anything behind it" fix already used
              // for text over the Live TV list's video preview elsewhere.
              child: widget.selected
                  ? const Icon(Icons.check, color: Colors.white, shadows: [
                      Shadow(color: Colors.black, blurRadius: 4),
                    ])
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              widget.palette.label,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
