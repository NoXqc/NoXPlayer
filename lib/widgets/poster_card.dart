import 'package:flutter/material.dart';

import 'hold_to_activate.dart';

/// One poster/backdrop tile in a browse row — scales and glows when
/// focused, which is the standard "this is where the D-pad is" affordance
/// on TV browse UIs. Shared by the Movies/TV Shows catalog rows
/// ([TvHomeScreen]'s `_CategoryRow`) and the season/episode rows
/// ([SeriesDetailScreen]) — same card shape either way, just fed a movie's
/// poster or an episode's still image.
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.onTap,
    required this.onFocusGained,
    this.rating,
    this.watched = false,
    this.progressFraction,
    this.alwaysShowTitle = false,
    this.focusNode,
    this.isFavorite = false,
    this.onToggleFavorite,
  });

  /// Was 150x210 — ~20% smaller per feedback that the catalog read too
  /// large. `_CategoryRow`'s row height matches this so there's no gap
  /// above/below the shrunk cards.
  static const double width = 120;
  static const double height = 168;

  final String title;
  final String? imageUrl;
  final String? rating;
  final VoidCallback onTap;
  final VoidCallback onFocusGained;

  /// Only the groups quick-jump needs this (on the first card of a row,
  /// so it can focus that row directly after scrolling to it) — every
  /// other card leaves this null and gets its own internal node as usual.
  final FocusNode? focusNode;

  /// Shows a checkmark badge instead of the rating — used by episode cards
  /// for "fully watched" (see StorageService.isFullyWatched).
  final bool watched;

  /// 0.0-1.0 — shows a progress bar + percentage when set and not
  /// [watched] (an episode/movie partway through, not finished).
  final double? progressFraction;

  /// Movie/show posters only caption themselves when there's no artwork
  /// (Netflix-style — the poster IS the label). Episode stills don't work
  /// that way: many look similar, and knowing *which* episode is the
  /// whole point, so [SeriesDetailScreen] sets this to keep the title
  /// (and watched-% ) visible over the image too.
  final bool alwaysShowTitle;

  /// Shows a star badge when true. [onToggleFavorite] is null for callers
  /// that don't have a favorite concept for this item (e.g. episode cards)
  /// — the hold-to-favorite gesture is only wired up when it's provided.
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasImage = widget.imageUrl != null && widget.imageUrl!.isNotEmpty;
    final showProgress = !widget.watched && widget.progressFraction != null;
    final showTitleStrip = !hasImage || widget.alwaysShowTitle;

    final card = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: InkWell(
        focusNode: widget.focusNode,
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onTap,
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) widget.onFocusGained();
        },
        child: AnimatedScale(
          scale: _focused ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Container(
            width: PosterCard.width,
            height: PosterCard.height,
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              borderRadius: BorderRadius.circular(10),
              border: _focused ? Border.all(color: scheme.primary, width: 3) : null,
              // Was two layered shadows (primary + secondary at different
              // blur/spread) for a duo-tone glow — on this hardware
              // (Impeller already disabled elsewhere for GPU weakness)
              // that showed up as part of a real flicker during scrolling.
              // One shadow in a blended color keeps the "not just one flat
              // accent" feel at half the compositing cost.
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: Color.lerp(scheme.primary, scheme.secondary, 0.5)!.withValues(alpha: 0.6),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                if (hasImage)
                  Positioned.fill(
                    child: Image.network(
                      widget.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _PosterFallbackLabel(title: widget.title),
                    ),
                  )
                else
                  _PosterFallbackLabel(title: widget.title),
                if (widget.watched)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Icon(Icons.check_circle, color: scheme.primary, size: 22, shadows: const [
                      Shadow(color: Colors.black, blurRadius: 4),
                    ]),
                  )
                else if (widget.rating != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '★ ${widget.rating}',
                        style: const TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                // Stacked below the watched checkmark (not on top of it)
                // when both apply, rather than picking one over the other.
                if (widget.isFavorite)
                  Positioned(
                    top: widget.watched ? 32 : 6,
                    right: 6,
                    child: const Icon(Icons.star, color: Colors.amber, size: 20, shadows: [
                      Shadow(color: Colors.black, blurRadius: 4),
                    ]),
                  ),
                if (showTitleStrip)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      color: Colors.black.withValues(alpha: hasImage ? 0.78 : 0.54),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          if (showProgress) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: widget.progressFraction,
                                      minHeight: 4,
                                      backgroundColor: Colors.white24,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${(widget.progressFraction! * 100).round()}%',
                                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else if (showProgress)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(10),
                        bottomRight: Radius.circular(10),
                      ),
                      child: LinearProgressIndicator(
                        value: widget.progressFraction,
                        minHeight: 4,
                        backgroundColor: Colors.black45,
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final onToggleFavorite = widget.onToggleFavorite;
    if (onToggleFavorite == null) return card;
    return HoldToActivate(onTap: widget.onTap, onHold: onToggleFavorite, child: card);
  }
}

class _PosterFallbackLabel extends StatelessWidget {
  const _PosterFallbackLabel({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade800,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: const Icon(Icons.movie_creation_outlined, color: Colors.white38, size: 40),
    );
  }
}
