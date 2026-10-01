import 'package:cached_network_image/cached_network_image.dart';
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
    this.focusNode,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.cardWidth = PosterCard.width,
    this.cardPosterHeight = PosterCard.posterHeight,
    this.fit = BoxFit.cover,
  });

  /// Was 120x168 with the title overlaid on the poster (and only shown at
  /// all when there was no artwork) — reported directly as a real
  /// usability gap: plenty of titles have no poster, and there was no
  /// way to read one without moving D-pad focus onto it first (the hero
  /// banner at the top of the screen is the only other place a title
  /// shows). The title now always renders in its own row below the
  /// poster, for every card, so this is smaller than before (less to
  /// decode/cache per poster too — see cacheWidth/cacheHeight below).
  /// Shrunk again (was 104x148/34) per feedback that the catalog should
  /// show more at once and leave more room for a bigger hero banner —
  /// same ~0.70 poster aspect ratio kept; titleHeight only trimmed to
  /// what 11pt/2 lines actually needs, not the font itself.
  static const double width = 84;
  static const double posterHeight = 120;
  static const double titleHeight = 30;
  static const double height = posterHeight + titleHeight;

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

  /// Shows a star badge when true. [onToggleFavorite] is null for callers
  /// that don't have a favorite concept for this item (e.g. episode cards)
  /// — the hold-to-favorite gesture is only wired up when it's provided.
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;

  /// Override [PosterCard.width]/[PosterCard.posterHeight] per instance —
  /// a search result's channel-logo row sits in the same row shape as
  /// Movies/TV Shows results but reads better noticeably smaller, since a
  /// broadcast logo carries far less detail than a movie poster. Every
  /// existing call site keeps the original static sizing unchanged.
  final double cardWidth;
  final double cardPosterHeight;

  /// `BoxFit.cover` (the default) is right for a movie/show poster
  /// designed to fill its whole rectangle — a broadcast logo is usually a
  /// transparent-background mark meant to be seen whole, so search's
  /// channel row passes `BoxFit.contain` instead, same convention
  /// `ChannelListTile` already uses for the same kind of image.
  final BoxFit fit;

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
          // Bumped from 1.08 — the same relative scale at this smaller
          // card size grew it by fewer pixels, so the focus "pop" read
          // as noticeably weaker; this restores a similarly visible glow.
          scale: _focused ? 1.10 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.cardWidth,
            height: widget.cardPosterHeight + PosterCard.titleHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: widget.cardWidth,
                  height: widget.cardPosterHeight,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(10),
                    border: _focused
                        ? Border.all(color: scheme.primary, width: 3)
                        : null,
                    // Was two layered shadows (primary + secondary at
                    // different blur/spread) for a duo-tone glow — on this
                    // hardware (Impeller already disabled elsewhere for GPU
                    // weakness) that showed up as part of a real flicker
                    // during scrolling. One shadow in a blended color keeps
                    // the "not just one flat accent" feel at half the
                    // compositing cost.
                    boxShadow: _focused
                        ? [
                            BoxShadow(
                              color: Color.lerp(
                                      scheme.primary, scheme.secondary, 0.5)!
                                  .withValues(alpha: 0.6),
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
                          child: CachedNetworkImage(
                            imageUrl: widget.imageUrl!,
                            fit: widget.fit,
                            // Provider posters commonly come in well above
                            // this card's on-screen size; without this,
                            // Flutter decodes and caches each one at full
                            // source resolution, which is the real memory
                            // cost of browsing a catalog (not the item
                            // metadata) — this was still causing device-
                            // wide OOM kills on a memory-constrained
                            // Firestick even after capping items per
                            // category. Forcing decode-time downsampling to
                            // roughly the card's physical size cuts each
                            // cached image's memory footprint by an order
                            // of magnitude or more.
                            memCacheWidth: (widget.cardWidth *
                                    MediaQuery.of(context).devicePixelRatio)
                                .round(),
                            memCacheHeight: (widget.cardPosterHeight *
                                    MediaQuery.of(context).devicePixelRatio)
                                .round(),
                            // A poster popping in instantly from the grey
                            // placeholder reads as a jarring flash,
                            // especially when scrolling back re-triggers a
                            // fetch after the tight in-memory cache evicted
                            // it — fadeInDuration is purely cosmetic, same
                            // cost either way. The disk cache underneath
                            // (this package's whole point over plain
                            // Image.network) is what actually avoids a full
                            // network re-fetch on that same scroll-back,
                            // which the memory cache ceiling alone
                            // couldn't do.
                            fadeInDuration: const Duration(milliseconds: 250),
                            errorWidget: (_, __, ___) =>
                                const _PosterFallbackIcon(),
                          ),
                        )
                      else
                        const _PosterFallbackIcon(),
                      if (widget.watched)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(Icons.check_circle,
                              color: scheme.primary,
                              size: 18,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 4),
                              ]),
                        )
                      else if (widget.rating != null)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '★ ${widget.rating}',
                              style: const TextStyle(
                                  color: Colors.amber,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      // Stacked below the watched checkmark (not on top of
                      // it) when both apply, rather than picking one over
                      // the other.
                      if (widget.isFavorite)
                        Positioned(
                          top: widget.watched ? 26 : 4,
                          right: 4,
                          child: const Icon(Icons.star,
                              color: Colors.amber,
                              size: 16,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 4),
                              ]),
                        ),
                      if (showProgress)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                            ),
                            // Was a plain 4px `scheme.primary` bar directly
                            // on the poster — reported directly as barely
                            // visible, and on a focused card actively
                            // blending into the focus border/glow above it
                            // (also `scheme.primary`, by design, so the two
                            // were never going to read as separate things).
                            // An opaque backing strip plus a percentage
                            // label fixes both at once: legible against any
                            // poster art regardless of focus state, and a
                            // real number reads at a glance without having
                            // to notice a thin bar's fill length at all.
                            // `scheme.secondary` for the fill — this app's
                            // whole duo-tone design already guarantees that
                            // reads as a distinct hue from whatever
                            // `scheme.primary` the focus glow is using.
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.78),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(4, 2, 4, 3),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${(widget.progressFraction! * 100).round()}%',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        height: 1.0,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        value: widget.progressFraction,
                                        minHeight: 4,
                                        backgroundColor: Colors.white24,
                                        color: scheme.secondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  height: PosterCard.titleHeight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _focused ? scheme.primary : Colors.white,
                        fontSize: 11,
                        fontWeight:
                            _focused ? FontWeight.bold : FontWeight.normal,
                        height: 1.15,
                      ),
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
    return HoldToActivate(
        onTap: widget.onTap, onHold: onToggleFavorite, child: card);
  }
}

class _PosterFallbackIcon extends StatelessWidget {
  const _PosterFallbackIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade800,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: const Icon(Icons.movie_creation_outlined,
          color: Colors.white38, size: 40),
    );
  }
}
