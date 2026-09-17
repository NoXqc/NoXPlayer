import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/xtream_series.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import '../utils/route_observer.dart';
import '../utils/tv_theme.dart';
import '../widgets/catalog_warmup_banner.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/mode_button.dart';
import '../widgets/player_controls.dart';
import '../widgets/poster_card.dart';
import '../widgets/section_label.dart';
import '../widgets/settings_scaffold.dart';
import 'catalog_sync_screen.dart';
import 'movie_detail_screen.dart';
import 'player_screen.dart';
import 'search_screen.dart';
import 'series_detail_screen.dart';
import 'settings/settings_menu_screen.dart';

/// Directional D-pad focus movement between widgets (arrow keys via the
/// default `FocusTraversalPolicy`) does *not* automatically scroll a newly
/// focused widget into view the way Tab-based traversal does — several
/// rows in this screen's sidebars ended up effectively unreachable by
/// remote for exactly this reason (most recently: a new bottom-of-list
/// button that focus could reach but stayed below the visible viewport,
/// reading as "doesn't exist"). Called from every row's `onFocusChange`
/// rather than added once at the list level, since a `ListView` has no
/// single hook for "one of my descendants just got focused."
void _ensureVisible(BuildContext context) {
  Scrollable.ensureVisible(context,
      duration: const Duration(milliseconds: 150), alignment: 0.5);
}

/// A 10-foot, remote-friendly alternate to [HomeScreen] for TV boxes/
/// Firesticks. Always dark (streaming-app convention, independent of the
/// phone's light/dark setting) with a Netflix/Apple-TV-style poster-row
/// browse for Movies/TV Shows, and a groups+list+preview layout for Live
/// TV — reusing the same providers/services and even the same
/// [VideoPlayerPane] the phone layout uses; this is a new presentation
/// layer only, not a second copy of the playback/catalog logic.
///
/// Columns collapse progressively as D-pad focus moves right, so a 4-column
/// layout (tabs, groups, channel list, preview) doesn't crowd out the video
/// preview once you're actually browsing the channel list — only the
/// column currently in use (and anything to its right, not yet visited)
/// stays full width.
class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> with RouteAware {
  String _tab = 'TV';

  /// Group identity is `(playlistId, title)` now that more than one
  /// playlist can exist (two providers can share a category name), but
  /// this field itself stays a bare title — every place that reads it
  /// back either re-resolves its playlistId itself when it actually needs
  /// one (Favorites-tab selections, via `_favoriteGroupCategory`) or
  /// merges across playlists by title on purpose (Live TV's
  /// `visibleChannels`/`_effectiveLiveGroup`, an accepted edge case if two
  /// playlists ever share an exact live group name).
  String? _selectedGroup;
  String? _focusedTitle;
  String? _focusedImageUrl;

  /// How far right D-pad focus currently is: 0=tabs, 1=groups, 2=list,
  /// 3=preview. Columns with an index below this collapse to an icon-only
  /// strip — "show only the tab you're on", as requested.
  int _focusDepth = 0;

  /// One [FocusScopeNode] per column: tabs, groups-or-browse-groups, and
  /// the last column (catalog browse, or the merged live-list-over-video
  /// region). Flutter's default arrow-key traversal picks the "nearest"
  /// focusable widget by on-screen geometry, which is unreliable once
  /// columns have collapsed to different widths and rows have different
  /// heights — reported as getting "stuck in the groups" unable to go back
  /// left. [_moveColumnFocus] replaces that guesswork with an explicit
  /// jump to the target column's scope, which Flutter then resolves to
  /// whatever was last focused there (or the first focusable item, if
  /// nothing was) — the same fix pattern as [DpadVerticalNav] elsewhere in
  /// this app.
  final FocusScopeNode _col0Scope = FocusScopeNode(debugLabel: 'tv-tabs');
  // Not final — see _onTabChanged, which replaces these with fresh
  // instances on every tab switch specifically (not just cleared) to
  // guarantee no stale focus memory survives, while every other use of
  // these two (_moveColumnFocus, column-to-column movement within the
  // *same* tab) keeps relying on FocusScopeNode's own restore-last-
  // focused-child behavior exactly as the doc comment above describes —
  // that's genuinely desirable there, just not across a tab switch.
  FocusScopeNode _col1Scope = FocusScopeNode(debugLabel: 'tv-col1');
  FocusScopeNode _col2Scope = FocusScopeNode(debugLabel: 'tv-col2');

  /// True once a Left press at the leftmost poster in the browse grid has
  /// found nowhere further left to go, but hasn't yet been confirmed by a
  /// second such press — see [_handleBrowseLeft]. Requiring two in a row
  /// stops one slightly-too-eager Left press from accidentally bouncing
  /// all the way out of the catalog and back to the tabs rail.
  bool _leftEdgeArmed = false;
  Timer? _leftEdgeArmTimer;

  /// The "double ← for groups" hint's floating overlay — anchored to
  /// whichever poster is actually focused at the moment [_handleBrowseLeft]
  /// arms (via its `RenderBox`, captured once right then, not
  /// continuously tracked — the grid isn't scrolling during this exact
  /// interaction, so a live-tracking `CompositedTransformFollower` would
  /// be solving a problem that doesn't occur here). Requested directly,
  /// twice: first tried next to `_BrowseHero`'s title, corrected to "the
  /// actual poster title" instead — the focused poster's own on-screen
  /// position, not the hero banner's.
  OverlayEntry? _leftEdgeHintOverlay;

  /// Per-category-title [GlobalKey]s attached to each browse row (see
  /// [_buildMoviesBrowse]/[_buildShowsBrowse]) so the Movies/TV Shows
  /// groups column can jump straight to a category instead of filtering
  /// the whole view down to it — a shortcut into the existing catalog
  /// scroll, not a second way of browsing.
  final Map<String, GlobalKey> _groupRowKeys = {};
  final GlobalKey _continueWatchingRowKey = GlobalKey();
  final ScrollController _browseScrollController = ScrollController();

  /// Whether Movies/TV Shows is currently showing the "What's New"
  /// carousel instead of the normal poster catalog. True on every entry
  /// into either tab (see [_onTabChanged]) — it's the default view —
  /// until "All" or a real category is picked from the groups column.
  bool _showWhatsNew = false;

  /// The carousel's Play button, owned here (like
  /// [_groupFirstPosterFocusNodes]/[_continueWatchingFirstFocusNode]) so
  /// [_enterBrowseColumn] can hand D-pad focus straight to it. Deliberately
  /// not `autofocus` inside the carousel itself: that fires as soon as the
  /// widget is built — i.e. the instant the tab is switched, while focus is
  /// still meant to be on the tabs rail — and would drag the cursor into
  /// the content column unasked.
  final FocusNode _whatsNewPlayFocusNode =
      FocusNode(debugLabel: 'whats-new-play');

  /// Groups mid-way through the "grey out for 30s, then actually hide"
  /// flow — long-pressing one of these again cancels the hide instead of
  /// (necessarily) hiding it, since it hasn't actually disappeared yet.
  final Set<String> _pendingHideGroups = {};
  final Map<String, Timer> _pendingHideTimers = {};

  static const _pendingHideDuration = Duration(seconds: 30);

  /// `_pendingHideGroups`/`_pendingHideTimers`/`_groupRowKeys` are all
  /// keyed by this composite instead of a bare title — two playlists can
  /// share a category name, and a bare-title key would let one playlist's
  /// "pending hide"/browse-row-scroll-target state bleed into another's
  /// same-named group.
  String _groupKey(String playlistId, String title) => '$playlistId::$title';

  void _startPendingHide(String playlistId, String title) {
    final key = _groupKey(playlistId, title);
    _pendingHideTimers[key]?.cancel();
    setState(() => _pendingHideGroups.add(key));
    _pendingHideTimers[key] = Timer(_pendingHideDuration, () {
      _pendingHideTimers.remove(key);
      if (!mounted) return;
      setState(() => _pendingHideGroups.remove(key));
      context.read<PlaylistManager>().setGroupHidden(playlistId, title, true);
    });
  }

  void _cancelPendingHide(String playlistId, String title) {
    final key = _groupKey(playlistId, title);
    _pendingHideTimers.remove(key)?.cancel();
    setState(() => _pendingHideGroups.remove(key));
  }

  /// Long-press menu for a real category row — "add/remove favorites"
  /// (the whole group's channels, not one at a time) and hide/cancel-hide.
  Future<void> _showGroupOptions(String playlistId, String title) async {
    final playlist = context.read<PlaylistManager>();
    final isFavorited = playlist.isGroupFavorited(playlistId, title);
    final isPending = _pendingHideGroups.contains(_groupKey(playlistId, title));

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('favorite'),
            child: Text(
                isFavorited ? 'Remove from Favourites' : 'Add to Favourites'),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(isPending ? 'cancel_hide' : 'hide'),
            child: Text(isPending ? 'Cancel Hide' : 'Hide Group'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    switch (choice) {
      case 'favorite':
        playlist.setGroupFavorited(playlistId, title, !isFavorited);
      case 'hide':
        _startPendingHide(playlistId, title);
      case 'cancel_hide':
        _cancelPendingHide(playlistId, title);
    }
  }

  GlobalKey _keyForGroup(String playlistId, String title) => _groupRowKeys
      .putIfAbsent(_groupKey(playlistId, title), () => GlobalKey());

  /// A plain [FocusNode] for the *first* poster of each category row —
  /// separate from the scroll position entirely. Scrolling a row into
  /// view (see [_scrollToBrowseGroup]) doesn't by itself move the D-pad
  /// cursor, so pressing Right afterward was restoring whatever card was
  /// previously focused in the browse column (from an earlier visit,
  /// possibly a totally different row), which then dragged the scroll
  /// right back to wherever *that* was.
  ///
  /// A first attempt fixed that by wrapping each row in its own
  /// `FocusScope` and requesting focus on that — which "worked" for the
  /// jump, but broke Up/Down between rows *everywhere*, not just after a
  /// jump: nesting a `FocusScope` per row turns each into its own
  /// traversal boundary, and default directional focus doesn't cross
  /// those to reach a sibling row. A plain `FocusNode.requestFocus()`
  /// moves the cursor without introducing any new boundary, so normal
  /// navigation elsewhere is unaffected.
  final Map<String, FocusNode> _groupFirstPosterFocusNodes = {};

  FocusNode _firstPosterFocusNodeForGroup(String playlistId, String title) =>
      _groupFirstPosterFocusNodes.putIfAbsent(_groupKey(playlistId, title),
          () => FocusNode(debugLabel: 'row-$title-first'));

  /// First card of the Continue Watching row, when present — that row has
  /// no group title to key off of, so it needs its own dedicated node
  /// (see [_enterBrowseColumn]).
  final FocusNode _continueWatchingFirstFocusNode =
      FocusNode(debugLabel: 'continue-watching-first');

  /// Live TV channel list — lets [_restoreLiveFocus] jump back to a known
  /// row offset directly instead of guessing from the current scroll
  /// position.
  final ScrollController _liveListController = ScrollController();

  /// Whichever row currently matches [PlaybackService.currentChannel] —
  /// only one row can match at a time, so a single shared node is enough
  /// (see [_restoreLiveFocus]).
  final FocusNode _currentChannelFocusNode =
      FocusNode(debugLabel: 'current-channel-row');

  /// A starting estimate only — rows can grow to two lines for a long
  /// channel name — refined by `Scrollable.ensureVisible` once the target
  /// row is close enough to the viewport to have actually been built.
  static const double _liveRowHeightEstimate = 72;

  /// Keeps a whole row's header visible when D-pad focus lands on one of
  /// its cards, not just the card itself — Flutter's own default
  /// "scroll the focused widget into view" only guarantees the *card* is
  /// visible, which for a tall row can leave its header (e.g. "Continue
  /// Watching") scrolled just above the fold. Runs after the frame so it
  /// applies on top of / overrides that default scroll instead of racing it.
  void _ensureRowVisible(GlobalKey rowKey) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = rowKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0);
      }
    });
  }

  /// Group-list rows were reading noticeably larger than they needed to
  /// at 10-foot viewing distance — this is a logical/DP size, so it comes
  /// out the same physical size on a 1080p or a 4K panel of the same
  /// screen dimensions; the fix is just a smaller number, not a
  /// per-resolution one.
  static const double _groupFontSize = 13;

  static const _tabs = ['TV', 'Movies', 'TV Shows', 'Favorites'];
  static const _tabIcons = {
    'TV': Icons.live_tv,
    'Movies': Icons.movie,
    'TV Shows': Icons.video_library,
    'Favorites': Icons.star,
  };

  void _onTabChanged(String tab) {
    _disarmLeftEdge();
    // A deliberate visit to the TV tab is exactly the "user actually
    // looked for it" moment PlaybackService.isSilentlyResuming's doc
    // comment describes — end the cold-start suppression window early so
    // this tab immediately shows what's actually playing.
    if (tab == 'TV') context.read<PlaybackService>().clearSilentResume();
    // _col1Scope/_col2Scope are shared across every tab (see the widget
    // tree below — Live TV and Movies/TV Shows both build their groups/
    // main-area columns inside the *same* FocusScopeNode instances, not
    // one each). Flutter's own FocusScopeNode automatically remembers
    // whichever descendant last had focus and restores it the next time
    // that scope regains focus — reported directly: scroll down to the
    // 15th group in Movies, drill into its catalog, back out to the tab
    // bar, switch to TV Shows, and the selector lands on TV Shows' 15th
    // group instead of the top, purely because that's positionally where
    // Movies' focus was left, with nothing about it aware the actual
    // content is now a completely different list.
    //
    // `.unfocus()` alone (tried first) turned out not to fix this: it's
    // a no-op unless the node being called already has focus (an early
    // `if (!hasFocus) return;` guard in Flutter's own implementation) —
    // and at the exact moment a tab is switched, focus is on _col0Scope
    // (the tabs column being tapped/selected), not _col1Scope/_col2Scope
    // at all, so that guard always bailed out before clearing anything.
    // Replacing both with genuinely fresh FocusScopeNode instances instead
    // guarantees no memory survives, by construction — a new node simply
    // has none to begin with. The old instances are disposed immediately
    // after; nothing else holds a reference to them past this point.
    _col1Scope.dispose();
    _col2Scope.dispose();
    _col1Scope = FocusScopeNode(debugLabel: 'tv-col1');
    _col2Scope = FocusScopeNode(debugLabel: 'tv-col2');
    setState(() {
      _tab = tab;
      _selectedGroup = null;
      _focusedTitle = null;
      _focusedImageUrl = null;
      _focusDepth = 0;
      _showWhatsNew = tab == 'Movies' || tab == 'TV Shows';
    });
    // Switching back to the TV tab clears the explicit group selection —
    // _effectiveLiveGroup falls back to the playing channel's own group
    // (or the first group) rather than an unfiltered "All" — but never
    // scrolled the channel list to whatever's actually playing — it just
    // showed the list from the top, which read as "the guide shows the
    // wrong channel" (a completely unrelated live channel happened to sort
    // first). _restoreLiveFocus already does exactly this scroll/focus,
    // today only wired to firing when *popping back from fullscreen*
    // (didPopNext) — this is the same restoration, just for the other way
    // of returning to this tab. Needs a frame so the channel list has
    // actually rebuilt for the new group/tab before scrolling within it.
    if (tab == 'TV') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreLiveFocus();
      });
    }
  }

  /// Left inside the poster grid should still move card-to-card normally.
  /// Only once that fails (nothing further left in the current row) does
  /// this arm a one-shot "confirm" window — a second Left press with
  /// nowhere to go, within [_leftEdgeArmWindow], is what actually exits
  /// back to the tabs rail. Any successful move, or letting the window
  /// lapse, disarms it.
  static const _leftEdgeArmWindow = Duration(seconds: 2);

  void _handleBrowseLeft() {
    final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.left) ??
        false;
    if (moved) {
      _disarmLeftEdge();
      return;
    }
    if (_leftEdgeArmed) {
      _disarmLeftEdge();
      _moveColumnFocus(-1, 2);
    } else {
      _leftEdgeArmed = true;
      _showLeftEdgeHint();
      _leftEdgeArmTimer?.cancel();
      _leftEdgeArmTimer = Timer(_leftEdgeArmWindow, _disarmLeftEdge);
    }
  }

  void _disarmLeftEdge() {
    _leftEdgeArmTimer?.cancel();
    _leftEdgeArmTimer = null;
    _leftEdgeArmed = false;
    _leftEdgeHintOverlay?.remove();
    _leftEdgeHintOverlay = null;
  }

  // Requested directly: a visible cue for exactly this window, since
  // nothing on screen previously indicated that a second Left press
  // (within _leftEdgeArmWindow) was even a thing — the first press just
  // silently did nothing, with no way to tell "that didn't work" apart
  // from "press it again and it will." An OverlayEntry (not a Positioned
  // inside this screen's own widget tree) specifically so it can be
  // placed using the focused poster's *global* screen position — no
  // ancestor-Stack coordinate-space conversion needed, the same reason
  // Tooltip/dropdown menus use this mechanism.
  void _showLeftEdgeHint() {
    final renderObject =
        FocusManager.instance.primaryFocus?.context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final overlay = Overlay.of(context, rootOverlay: true);
    _leftEdgeHintOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: topLeft.dx,
        top: topLeft.dy + size.height + 6,
        width: size.width,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Double',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                  const Icon(Icons.keyboard_arrow_left,
                      color: Colors.white, size: 16),
                  const Icon(Icons.keyboard_arrow_left,
                      color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  const Text('for groups',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_leftEdgeHintOverlay!);
  }

  /// Not a real category — a pinned entry at the top of the TV tab's
  /// groups column so favorited channels are reachable without leaving
  /// the tab (the separate "Favorites" tab still exists too).
  static const _favoritesGroupSentinel = '__favorites__';

  /// [playlistId] is required for a real group selection (from a
  /// `_GroupRow`, which always has its own `M3uGroup.playlistId` on
  /// hand), null for the sentinels ("All", "Favourites") — Favorites-tab
  /// selections re-resolve their own playlistId via
  /// [_favoriteGroupCategory] instead of trusting the caller, since that
  /// column mixes bare titles pulled from every playlist's favorited
  /// groups together with no single caller-known playlist.
  void _onGroupSelected(String? group, {String? playlistId}) {
    context.read<PlaybackService>().clearSilentResume();
    setState(() => _selectedGroup = group);
    if (group == null || group == _favoritesGroupSentinel) return;
    if (_tab == 'Favorites') {
      // A favorited *group* here can be a live TV group, a movies group,
      // or a TV shows group (see _showGroupOptions — long-pressing a group
      // works the same everywhere) — unlike a starred individual channel,
      // its content isn't guaranteed to already be cached just because
      // it's favorited, so a movies/series pick still needs the normal
      // on-demand fetch. A live group's channels are always already
      // loaded (Live TV has no lazy-loading), so nothing to do there.
      final resolved =
          _favoriteGroupCategory(context.read<PlaylistManager>(), group);
      if (resolved == null) return;
      if (resolved.category == 'vod' || resolved.category == 'series') {
        context.read<PlaylistManager>().ensureCategoryLoaded(
            resolved.playlistId, group, resolved.category);
      }
      return;
    }
    context
        .read<PlaylistManager>()
        .ensureCategoryLoaded(playlistId!, group, _categoryForTab(_tab));
  }

  /// Which tab a favorited group actually belongs to, and which playlist
  /// it came from — the Favorites tab's groups column mixes all three
  /// group kinds (and every playlist's own groups) together, so a plain
  /// `_categoryForTab(_tab)` (always "tv" there) isn't enough to know how
  /// to load or render a given selection. Null if the group was
  /// un-favorited/removed since the list was built. Search order (vod,
  /// series, tv) matches the original single-playlist behavior; the first
  /// match wins if (rare) two playlists share a favorited group's title.
  ({String category, String playlistId})? _favoriteGroupCategory(
      PlaylistManager playlist, String title) {
    for (final g in playlist.vodGroups) {
      if (g.title == title) return (category: 'vod', playlistId: g.playlistId);
    }
    for (final g in playlist.seriesGroups) {
      if (g.title == title)
        return (category: 'series', playlistId: g.playlistId);
    }
    for (final g in playlist.tvGroups) {
      if (g.title == title) return (category: 'tv', playlistId: g.playlistId);
    }
    return null;
  }

  /// Every `_CategoryRow` is effectively the same height regardless of how
  /// many posters it holds (fixed 210px poster strip + header + padding —
  /// the poster count only changes how far it scrolls *horizontally*, not
  /// its height), so a target row's position is just `index * this` —
  /// used instead of `Scrollable.ensureVisible` for [_scrollToBrowseGroup]
  /// because that approach fundamentally can't reach a row the
  /// `ListView.builder` hasn't built yet (its `GlobalKey.currentContext`
  /// is null until it scrolls near the viewport) — exactly the case
  /// reported: jumping to a group further down than what's currently
  /// rendered silently did nothing.
  static const double _categoryRowHeight = 262;

  bool _hasContinueWatchingRow(String idPrefix) {
    final playback = context.read<PlaybackService>();
    final storage = context.read<StorageService>();
    return playback.recentlyPlayed.any((c) =>
        c.rawId.startsWith(idPrefix) && storage.getLastPosition(c.id) > 0);
  }

  /// Movies/TV Shows groups column: a fast way to find a category, not a
  /// filter — scrolls that category's row into view in the existing
  /// catalog instead of hiding everything else, since the browse view
  /// already organizes everything by category via its row headers.
  Future<void> _scrollToBrowseGroup(String playlistId, String title) async {
    final playlist = context.read<PlaylistManager>();
    playlist.ensureCategoryLoaded(playlistId, title, _categoryForTab(_tab));
    if (!_browseScrollController.hasClients) return;

    final isMovies = _tab == 'Movies';
    final titles = isMovies
        ? playlist.vodGroups
            .where((g) => !g.isHidden && g.channels.isNotEmpty)
            .map((g) => g.title)
            .toList()
        : playlist.seriesGroups
            .where((g) =>
                !g.isHidden &&
                playlist
                    .visibleSeries(
                        playlistId: g.playlistId, categoryName: g.title)
                    .isNotEmpty)
            .map((g) => g.title)
            .toList();
    var index = titles.indexOf(title);
    if (index < 0) return;
    if (_hasContinueWatchingRow(isMovies ? 'xt_vod_' : 'xt_ep_')) index += 1;

    // jumpTo, not animateTo — same fix as _restoreLiveFocus's live channel
    // list, and the same real bug: jumping to a group near the bottom of a
    // long list (a big provider can have hundreds of categories) forced
    // Flutter to build+lay out every row in between fast enough to finish
    // within a fixed animation duration, which is exactly what an ANR
    // confirmed on real hardware (a live Dart VM pause during the freeze)
    // turned out to be caused by elsewhere. jumpTo sets the offset
    // instantly instead.
    _browseScrollController.jumpTo(index * _categoryRowHeight);
    // Scrolling the row into view doesn't move the D-pad cursor by
    // itself — without this, pressing Right afterward restored whichever
    // card was focused from an earlier visit (possibly a different row
    // entirely), which then dragged the scroll right back to wherever
    // that was.
    if (mounted)
      _firstPosterFocusNodeForGroup(playlistId, title).requestFocus();
  }

  /// Right-arrow from the groups rail (browse tabs) when the user hasn't
  /// picked a specific group — [_col2Scope.requestFocus] alone restores
  /// whatever poster was focused on an earlier visit (possibly a
  /// different row's 3rd or 4th card), which read as the selector
  /// randomly landing "a few clicks to the right" of the first title.
  /// Picking a specific group already sets focus itself via
  /// [_scrollToBrowseGroup], so this only needs to cover the plain "just
  /// move right" case.
  void _enterBrowseColumn() {
    // The carousel replaces the poster rows entirely while it's up, so
    // none of the per-group first-poster nodes below exist to focus — its
    // Play button is the deliberate landing spot instead (see
    // [_whatsNewPlayFocusNode]). Falls back to the column's own scope if
    // the carousel is still loading/empty and has no Play button mounted.
    if (_showWhatsNew) {
      if (_whatsNewPlayFocusNode.context != null) {
        _whatsNewPlayFocusNode.requestFocus();
      } else {
        _col2Scope.requestFocus();
      }
      return;
    }
    final playlist = context.read<PlaylistManager>();
    final isMovies = _tab == 'Movies';
    final groups = isMovies
        ? playlist.vodGroups.where((g) => !g.isHidden && g.channels.isNotEmpty)
        : playlist.seriesGroups.where((g) =>
            !g.isHidden &&
            playlist
                .visibleSeries(playlistId: g.playlistId, categoryName: g.title)
                .isNotEmpty);
    final targetNode = _hasContinueWatchingRow(isMovies ? 'xt_vod_' : 'xt_ep_')
        ? _continueWatchingFirstFocusNode
        : groups.isNotEmpty
            ? _firstPosterFocusNodeForGroup(
                groups.first.playlistId, groups.first.title)
            : null;
    if (targetNode == null) {
      _col2Scope.requestFocus();
      return;
    }
    // The target row's PosterCard (and its focusNode) only exists once
    // `ListView.builder` has actually built it — if a previous group jump
    // left the scroll position far from the top, the first row isn't
    // built yet and requestFocus on it would silently do nothing. Scroll
    // to top first in that case, same as _scrollToBrowseGroup.
    // jumpTo, not animateTo — same fix/reasoning as _scrollToBrowseGroup
    // just above; the distance back to 0 can be just as large.
    if (_browseScrollController.hasClients &&
        _browseScrollController.offset > 0) {
      _browseScrollController.jumpTo(0);
    }
    targetNode.requestFocus();
  }

  void _scrollBrowseToTop() {
    if (_browseScrollController.hasClients) {
      _browseScrollController.jumpTo(0);
    }
  }

  /// Leaves the "What's New" carousel (if it's showing) and then runs the
  /// normal catalog jump. Deferred a frame in that case: the poster list
  /// isn't mounted while the carousel is up, so
  /// [_browseScrollController] has no clients yet and both
  /// [_scrollBrowseToTop] and [_scrollToBrowseGroup] would silently
  /// no-op — and the list, once it does remount, restores its previous
  /// offset from `PageStorage` rather than starting at the top.
  void _leaveWhatsNewThen(VoidCallback jump) {
    if (!_showWhatsNew) {
      jump();
      return;
    }
    setState(() => _showWhatsNew = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) jump();
    });
  }

  String _categoryForTab(String tab) => switch (tab) {
        'Movies' => 'vod',
        'TV Shows' => 'series',
        _ => 'tv',
      };

  void _updateBrowseFocus(String title, String? imageUrl) {
    if (_focusedTitle == title) return;
    setState(() {
      _focusedTitle = title;
      _focusedImageUrl = imageUrl;
    });
  }

  void _onColumnFocus(int depth) {
    if (_focusDepth != depth) setState(() => _focusDepth = depth);
  }

  /// Explicitly jumps D-pad focus one column left/right, clamped to
  /// [maxDepth]. Bound to the arrow keys via [CallbackShortcuts] in
  /// [build] instead of relying on default directional traversal — see the
  /// field doc on the `_colNScope` nodes for why.
  void _moveColumnFocus(int delta, int maxDepth) {
    final target = (_focusDepth + delta).clamp(0, maxDepth);
    if (target == _focusDepth) return;
    final scope = switch (target) {
      0 => _col0Scope,
      1 => _col1Scope,
      _ => _col2Scope,
    };
    scope.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _leftEdgeArmTimer?.cancel();
    _leftEdgeHintOverlay?.remove();
    _browseScrollController.dispose();
    _liveListController.dispose();
    _currentChannelFocusNode.dispose();
    _col0Scope.dispose();
    _col1Scope.dispose();
    _col2Scope.dispose();
    for (final node in _groupFirstPosterFocusNodes.values) {
      node.dispose();
    }
    _continueWatchingFirstFocusNode.dispose();
    _whatsNewPlayFocusNode.dispose();
    for (final timer in _pendingHideTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  /// Fires when a route pushed on top of this screen (the fullscreen
  /// player) is popped and this screen is visible again — the point where
  /// a user reported the Live TV guide "brings us back to the top of the
  /// list instead of the current channel" after backing out of fullscreen.
  @override
  void didPopNext() {
    final isBrowseTab = _tab == 'Movies' || _tab == 'TV Shows';
    if (!isBrowseTab) {
      // Reported directly: scroll to browse a different group (without
      // actually picking a channel from it), hold Right to resume the
      // channel that's actually live, then leave fullscreen again — the
      // *browsed* group was still showing instead of the live channel's
      // own, since nothing here ever cleared `_selectedGroup` on the way
      // back. `isFullscreenActive` is still true at this exact point
      // (PlayerScreen's own dispose-time clear is deferred a frame — see
      // that class's doc comment — so it hasn't run yet), which is
      // exactly what distinguishes "we just left the fullscreen player"
      // from `didPopNext` firing for any *other* pushed route (Search,
      // Settings) — those never touch this flag, and must NOT have this
      // reset applied: closing Search after deliberately browsing a
      // group should land back on that same group, not jump away to
      // whatever's live.
      if (context.read<PlaybackService>().isFullscreenActive) {
        // Reported directly: picking a channel from the pinned
        // "Favourites" entry (_favoritesGroupSentinel — a real channel's
        // *own* group is never this value, it's synthetic), going
        // fullscreen, then leaving fullscreen again landed back on that
        // channel's real category instead of staying on Favourites. The
        // blanket reset above is otherwise harmless for a real group (see
        // _effectiveLiveGroup's own fallback to the playing channel's
        // group — resetting to null and leaving a real group selected
        // that already matches the playing channel resolve to the exact
        // same displayed group either way), but Favourites is never one
        // of the real groups that fallback searches, so resetting it
        // always loses the selection outright. Keep it selected here
        // specifically when it's still true to what's actually playing.
        final playing = context.read<PlaybackService>().currentChannel;
        final stayOnFavorites = _selectedGroup == _favoritesGroupSentinel &&
            playing != null &&
            context
                .read<PlaylistManager>()
                .favoriteLiveChannels
                .any((c) => c.id == playing.id);
        if (!stayOnFavorites) {
          setState(() => _selectedGroup = null);
        }
      }
      _restoreLiveFocus();
      return;
    }
    // Popping fullscreen while sitting on a Movies/TV Shows tab used to
    // leave focus restoration entirely to Flutter's own implicit handling
    // after the pop — fine on a small catalog, but confirmed on real
    // hardware to cause the exact same class of ANR as the fullscreen
    // right-arrow bug (an expensive default focus search, this time
    // triggered by the pop itself rather than a keypress) once the
    // Movies/TV Shows catalog is large. Explicitly handing focus to the
    // tabs rail — always small, regardless of catalog size — gives
    // Flutter a cheap, deliberate target instead of letting it search.
    _col0Scope.requestFocus();
  }

  /// Same channel-list filtering [_buildLiveList] renders, factored out so
  /// [_restoreLiveFocus] can find the playing channel's index in the exact
  /// same list instead of risking the two falling out of sync.
  List<Channel> _currentLiveChannels(PlaylistManager playlist) {
    return _tab == 'Favorites'
        ? (_selectedGroup == null
            ? playlist.favoriteChannels
            : playlist.favoriteChannels
                .where((c) => c.group == _selectedGroup)
                .toList())
        : _effectiveLiveGroup(playlist) == _favoritesGroupSentinel
            ? playlist.favoriteLiveChannels
            : playlist.visibleChannels(
                groupTitle: _effectiveLiveGroup(playlist), category: 'tv');
  }

  /// The Live TV groups column has no standalone "All" entry anymore — it
  /// read as a confusing dumping-ground, and made returning from a stream
  /// feel like the app "forgot" which real group you were in (see
  /// [_onTabChanged], which resets [_selectedGroup] to null on every tab
  /// switch). Every visit now resolves to an actual group: whichever one
  /// is explicitly selected, otherwise the currently playing channel's own
  /// group (so switching tabs and back, or returning from fullscreen,
  /// lands exactly where playback left off), otherwise just the first
  /// visible group. [_buildGroupsColumn] and [_currentLiveChannels] both
  /// read through this instead of the raw field so the highlighted row
  /// always matches the list actually being shown.
  String? _effectiveLiveGroup(PlaylistManager playlist) {
    if (_selectedGroup != null) return _selectedGroup;
    final groups = playlist.tvGroups.where((g) => !g.isHidden).toList();
    if (groups.isEmpty) return null;
    final playback = context.read<PlaybackService>();
    // See PlaybackService.isSilentlyResuming's doc comment — a cold-start
    // background resume shouldn't auto-scroll here to a group the user
    // never actually asked to see yet.
    if (playback.isSilentlyResuming) return groups.first.title;
    final playing = playback.currentChannel;
    if (playing != null && groups.any((g) => g.title == playing.group)) {
      return playing.group;
    }
    return groups.first.title;
  }

  /// Scrolls/focuses the Live TV list back to whatever's actually playing.
  /// Popping the fullscreen player leaves the underlying list's scroll
  /// position and remembered focus technically intact, but a handful of
  /// things can invalidate them while covered (the list re-filtering, an
  /// EPG-driven rebuild, etc.) — rather than chase each of those down,
  /// this just re-asserts the one thing that's supposed to be true
  /// whenever this screen becomes visible again: the playing channel's
  /// row is what's in view and focused.
  Future<void> _restoreLiveFocus() async {
    // The Favorites tab's default ("All") view no longer has any live list
    // mounted at all (see _buildLiveRegion) — nothing below is meaningful
    // there, and requesting focus on a channel row's FocusNode that isn't
    // actually attached to anything is exactly the kind of "focus steals
    // itself back unexpectedly later" bug this app has hit before.
    if (_tab == 'Favorites' && _selectedGroup == null) {
      _col0Scope.requestFocus();
      return;
    }
    final playback = context.read<PlaybackService>();
    final channel = playback.currentChannel;
    // Every early return below used to just do nothing — fine in theory
    // (there's nothing *specific* to scroll/focus), but it left Flutter's
    // own implicit pop-focus-restoration to fend for itself with no
    // deliberate target, which is exactly the expensive-default-search ANR
    // already fixed for the Movies/TV Shows case in didPopNext. Confirmed
    // on real hardware: a channel that exists (plays fine) but isn't found
    // in this tab's own filtered list — e.g. one some IPTV providers send
    // with no valid category, so it never appears in any real group's
    // list — hits exactly this path. Same cheap fallback as that fix.
    if (channel == null) {
      _col0Scope.requestFocus();
      return;
    }
    final playlist = context.read<PlaylistManager>();
    final channels = _currentLiveChannels(playlist);
    final index = channels.indexWhere((c) => c.id == channel.id);
    if (index < 0) {
      _col0Scope.requestFocus();
      return;
    }

    if (_liveListController.hasClients) {
      final target = (index * _liveRowHeightEstimate)
          .clamp(0, _liveListController.position.maxScrollExtent)
          .toDouble();
      // jumpTo, not animateTo — this coarse estimate can be a huge
      // distance from wherever the list happens to be sitting (e.g. still
      // scrolled near the top from an earlier tab switch, while the
      // playing channel is far down a list of hundreds/thousands of live
      // channels). animateTo forces Flutter to build+lay out every row it
      // passes through fast enough to finish within its fixed duration —
      // confirmed on real hardware as the actual cause of an ANR-length
      // freeze on a large channel list. jumpTo sets the offset instantly,
      // no intermediate rows built; the short animateTo/ensureVisible
      // refinement below is a small enough distance to stay cheap.
      _liveListController.jumpTo(target);
    }
    if (!mounted) return;
    // The coarse jump above is only an estimate (rows can grow to two
    // lines) — refine with the real row's own position once it's close
    // enough to the viewport to have actually been built.
    final targetContext = _currentChannelFocusNode.context;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(targetContext,
          duration: const Duration(milliseconds: 150));
    }
    if (mounted) _currentChannelFocusNode.requestFocus();
  }

  Future<void> _selectChannel(Channel channel) async {
    final playback = context.read<PlaybackService>();
    // A deliberate tap always ends the cold-start suppression window,
    // even if it's for a *different* channel than the one silently
    // resuming — otherwise isSilentlyResuming would stay true (it's
    // unaffected by which channel play() below actually switches to) and
    // keep suppressing the groups-column jump for a selection the user
    // very much did make on purpose.
    playback.clearSilentResume();
    // Awaited deliberately — PlayerScreen's own initState also calls
    // play() (guarded to no-op if this channel's already current), but
    // that guard only works if THIS call has actually finished setting
    // currentChannel/controller first. Firing this and pushing
    // immediately let both calls race to create/dispose the video
    // controller concurrently — reported as the fullscreen player
    // showing solid black while the exact same stream played fine in an
    // inline preview built later, once the race had settled.
    await playback.play(channel);
    if (!mounted) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
  }

  /// Right, once there's no further column to move into, jumps straight to
  /// fullscreen on whatever's actually playing (PlaybackService's
  /// currentChannel) — not whichever row the D-pad cursor happens to be
  /// sitting on. No-ops if nothing's playing yet.
  void _goFullscreenIfPlaying() {
    final channel = context.read<PlaybackService>().currentChannel;
    if (channel == null) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
  }

  void _openMovie(Channel channel) {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MovieDetailScreen(channel: channel)));
  }

  void _openSeries(XtreamSeries series) {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsMenuScreen()));
  }

  void _openSearch() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SearchScreen(initialScope: _tab)));
  }

  /// Re-syncs every enabled playlist — Xtream ones via a full catalog
  /// sync (one confirm covers all of them), M3U ones via a plain re-fetch
  /// of their flat list.
  Future<void> _refreshPlaylist(BuildContext context) async {
    final playlist = context.read<PlaylistManager>();
    if (playlist.profiles.isEmpty) return;

    if (playlist.profiles.any((p) => p.enabled && p.isXtream)) {
      // Shared with Settings > Clear Cache — see its doc comment for why
      // this needed to become a reusable helper rather than living here.
      final didSync = await confirmAndRunFullCatalogSync(context, playlist);
      if (didSync && mounted) _showUpdateToast();
    }

    final m3uProfiles =
        playlist.profiles.where((p) => p.enabled && !p.isXtream).toList();
    if (m3uProfiles.isEmpty || !context.mounted) return;

    // M3U mode: no per-category concept to re-sync, just a plain re-fetch
    // of the flat list — still confirms first since a stray remote press
    // on this menu entry shouldn't kick off a re-fetch unintentionally.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update content now?'),
        content:
            const Text('Re-checks your M3U playlist URL(s) for new content.'),
        actions: [
          ModeButton(
              label: 'Cancel',
              selected: false,
              onTap: () => Navigator.of(context).pop(false)),
          ModeButton(
              label: 'Update',
              selected: false,
              onTap: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    for (final profile in m3uProfiles) {
      await playlist.loadPlaylist(profile.id);
    }
  }

  /// Some Xtream providers cap concurrent connections per login — just
  /// backgrounding/minimizing the app doesn't release that slot, but
  /// disabling the playlist does (same mechanism as the manual toggle in
  /// Content Manager: stop touching the server, keep the cached
  /// credentials/catalog). Confirmed first since it's a deliberate
  /// "free this login up for another device" action, not an accidental
  /// tap consequence.
  Future<void> _confirmHardExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit and free up this login?'),
        content: const Text(
          'This disconnects your login here so it can be used on another '
          'device, then fully closes NoXPlayer. Your channels/movies will '
          'need to reload next time you open it.',
        ),
        actions: [
          ModeButton(
            label: 'Cancel',
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: 'Exit',
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true) _hardExit();
  }

  void _hardExit() {
    // Disables every currently-enabled playlist (not just one, now that
    // more than one can exist) — see this button's own dialog copy:
    // freeing up "this login" for another device meant *every* login
    // this device was actively holding a connection slot on.
    final playlist = context.read<PlaylistManager>();
    for (final profile in playlist.profiles.where((p) => p.enabled)) {
      playlist.setPlaylistEnabled(profile.id, false);
    }
    SystemNavigator.pop();
  }

  void _showUpdateToast() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Content updated'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final epg = context.watch<EpgService>();
    final prefs = context.watch<AppPreferences>();

    // Streaming-app convention: always dark on the TV screen, regardless of
    // the phone's light/dark setting, but still keyed off the user's chosen
    // cyberpunk palette so Settings > Theme actually drives this screen and
    // not just the Settings menu itself. Material's own tonal derivation
    // gives accessible contrast colors (onPrimary etc.); the secondary/
    // tertiary override makes the second accent deliberate instead of
    // algorithmically derived from the same single hue.
    final darkScheme = ColorScheme.fromSeed(
      seedColor: prefs.palette.primary,
      brightness: Brightness.dark,
    ).copyWith(
        secondary: prefs.palette.secondary, tertiary: prefs.palette.secondary);

    final isBrowseTab = _tab == 'Movies' || _tab == 'TV Shows';

    return Theme(
      data: ThemeData(colorScheme: darkScheme, useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Same bright, saturated two-color diagonal used across every
            // Settings screen (see SettingsGradientBackground's doc
            // comment) — was a muted 3-stop alpha-blend-onto-black here,
            // which read as "still basically black/grey" next to the
            // Settings redesign. Reusing the shared widget instead of a
            // second copy of the same gradient math keeps both screens in
            // sync automatically if the recipe ever changes again.
            const Positioned.fill(child: SettingsGradientBackground()),
            SafeArea(
              minimum: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _TvTopBar(
                      showClock: prefs.showClock,
                      isLoading: playlist.isLoading),
                  const CatalogWarmupBanner(),
                  Expanded(
                    child: (playlist.error != null && playlist.channels.isEmpty)
                        ? Center(
                            child: FilledButton(
                                onPressed: _openSettings,
                                child: const Text('Open Settings')),
                          )
                        : CallbackShortcuts(
                            // The 4-column Live TV/Favorites layout gets full
                            // explicit column-switching. The Movies/TV Shows
                            // browse view only has two columns (tabs, browse),
                            // and needs Left/Right free inside the browse
                            // column for poster-to-poster movement — but it
                            // still needs an explicit Right from the tabs rail
                            // to *enter* that column in the first place,
                            // since default traversal couldn't reliably jump
                            // there either (same class of bug as the groups
                            // column getting "stuck").
                            // Movies/TV Shows are 3 columns now (tabs, groups
                            // shortcut rail, browse) instead of the 4-column
                            // Live TV/Favorites layout (tabs, groups, list,
                            // preview) — but the same per-depth pattern:
                            // Left/Right always switch columns except inside
                            // the poster grid itself, where Left/Right move
                            // card-to-card (see _handleBrowseLeft for the
                            // "nowhere further left" escape).
                            bindings: isBrowseTab
                                ? switch (_focusDepth) {
                                    0 => <ShortcutActivator, VoidCallback>{
                                        const SingleActivator(
                                                LogicalKeyboardKey.arrowRight):
                                            () => _moveColumnFocus(1, 2),
                                      },
                                    1 => <ShortcutActivator, VoidCallback>{
                                        const SingleActivator(
                                                LogicalKeyboardKey.arrowLeft):
                                            () => _moveColumnFocus(-1, 2),
                                        const SingleActivator(
                                                LogicalKeyboardKey.arrowRight):
                                            _enterBrowseColumn,
                                      },
                                    _ => <ShortcutActivator, VoidCallback>{
                                        const SingleActivator(
                                                LogicalKeyboardKey.arrowLeft):
                                            _handleBrowseLeft,
                                      },
                                  }
                                : <ShortcutActivator, VoidCallback>{
                                    // 3 columns now (tabs, groups, the merged
                                    // live-list-over-video region) — the list
                                    // panel is a plain vertical list like the
                                    // groups column, so Left/Right always
                                    // switching columns (never intra-row) is
                                    // safe here, same as before the merge.
                                    const SingleActivator(
                                            LogicalKeyboardKey.arrowLeft):
                                        () => _moveColumnFocus(-1, 2),
                                    // Already in the last column: Right has
                                    // nowhere further to go, so it becomes a
                                    // shortcut straight to fullscreen on
                                    // whatever's currently playing instead of
                                    // a dead end — otherwise finding your way
                                    // back to fullscreen meant re-selecting
                                    // the same channel from the list again.
                                    const SingleActivator(
                                            LogicalKeyboardKey.arrowRight):
                                        _focusDepth == 2
                                            ? _goFullscreenIfPlaying
                                            : () => _moveColumnFocus(1, 2),
                                  },
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _collapsible(
                                  depth: 0,
                                  expandedWidth: 160,
                                  child: FocusTraversalGroup(
                                    child: FocusScope(
                                      node: _col0Scope,
                                      onFocusChange: (has) {
                                        if (has) _onColumnFocus(0);
                                      },
                                      child: _buildTabsColumn(
                                          collapsed: _focusDepth > 0),
                                    ),
                                  ),
                                ),
                                const VerticalDivider(width: 1),
                                if (isBrowseTab) ...[
                                  _collapsible(
                                    depth: 1,
                                    expandedWidth: 260,
                                    child: FocusTraversalGroup(
                                      child: FocusScope(
                                        node: _col1Scope,
                                        onFocusChange: (has) {
                                          if (has) _onColumnFocus(1);
                                        },
                                        child: _buildBrowseGroupsColumn(
                                            playlist,
                                            collapsed: _focusDepth > 1),
                                      ),
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  Expanded(
                                    child: FocusTraversalGroup(
                                      child: FocusScope(
                                        node: _col2Scope,
                                        onFocusChange: (has) {
                                          if (has) _onColumnFocus(2);
                                        },
                                        child: _buildMainArea(playlist, epg),
                                      ),
                                    ),
                                  ),
                                ] else ...[
                                  _collapsible(
                                    depth: 1,
                                    expandedWidth: 260,
                                    child: FocusTraversalGroup(
                                      child: FocusScope(
                                        node: _col1Scope,
                                        onFocusChange: (has) {
                                          if (has) _onColumnFocus(1);
                                        },
                                        child: _buildGroupsColumn(playlist,
                                            collapsed: _focusDepth > 1),
                                      ),
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  Expanded(
                                    child: FocusTraversalGroup(
                                      child: FocusScope(
                                        node: _col2Scope,
                                        onFocusChange: (has) {
                                          if (has) _onColumnFocus(2);
                                        },
                                        child: _buildLiveRegion(playlist, epg),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A column that animates between [expandedWidth] and a narrow icon-only
  /// strip once D-pad focus has moved past it (`_focusDepth > depth`).
  Widget _collapsible({
    required int depth,
    required double expandedWidth,
    required Widget child,
    double collapsedWidth = 56,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _focusDepth > depth ? collapsedWidth : expandedWidth,
      child: child,
    );
  }

  Widget _buildTabsColumn({required bool collapsed}) {
    return ListView(
      children: [
        _SelectableRow(
          icon: Icons.search,
          label: 'Search',
          selected: false,
          collapsed: collapsed,
          onTap: _openSearch,
        ),
        const Divider(height: 16, color: Colors.white24),
        for (final tab in _tabs)
          _SelectableRow(
            icon: _tabIcons[tab]!,
            label: tab,
            selected: _tab == tab,
            collapsed: collapsed,
            onTap: () => _onTabChanged(tab),
          ),
        const Divider(height: 16, color: Colors.white24),
        _SelectableRow(
          icon: Icons.playlist_add_check,
          label: 'Update Content',
          selected: false,
          collapsed: collapsed,
          onTap: () => _refreshPlaylist(context),
        ),
        _SelectableRow(
          icon: Icons.settings,
          label: 'Settings',
          selected: false,
          collapsed: collapsed,
          onTap: _openSettings,
        ),
        const Divider(height: 16, color: Colors.white24),
        // Deliberately at the very bottom, one row on its own — this kills
        // the app, so it shouldn't be one accidental press away from the
        // tab list above it.
        _SelectableRow(
          icon: Icons.power_settings_new,
          label: 'Exit App',
          selected: false,
          collapsed: collapsed,
          onTap: _confirmHardExit,
        ),
      ],
    );
  }

  /// Builds each visible group's row via [rowBuilder], inserting a
  /// [_PlaylistDividerRow] wherever two consecutive groups belong to
  /// different playlists — see that widget's doc comment. Only used by
  /// the Live TV and Movies/TV Shows groups columns (per the user's own
  /// scoping: "the same in movies and shows... in favourites it don't
  /// matter" — that column mixes all three group kinds by design already,
  /// so a playlist boundary isn't the distinction that matters there).
  /// No-ops back to a plain row list when every group belongs to the same
  /// playlist — the ordinary single-playlist case, nothing to mark.
  List<Widget> _groupRowsWithPlaylistDividers(
    List<M3uGroup> groups,
    PlaylistManager playlist, {
    required bool collapsed,
    required Widget Function(M3uGroup group) rowBuilder,
  }) {
    final distinctPlaylistIds = groups.map((g) => g.playlistId).toSet();
    final widgets = <Widget>[];
    String? lastPlaylistId;
    for (final group in groups) {
      if (distinctPlaylistIds.length > 1 &&
          lastPlaylistId != null &&
          group.playlistId != lastPlaylistId) {
        widgets.add(_PlaylistDividerRow(
          name: playlist.playlistNameFor(group.playlistId),
          collapsed: collapsed,
        ));
      }
      lastPlaylistId = group.playlistId;
      widgets.add(rowBuilder(group));
    }
    return widgets;
  }

  Widget _buildGroupsColumn(PlaylistManager playlist,
      {required bool collapsed}) {
    if (_tab == 'Favorites') {
      // Was a static "Pinned channels" placeholder — this is the actual
      // filter now: the names of groups favorited as a whole (see
      // _showGroupOptions), so you can jump to just one group's favorites
      // instead of everything landing in one flat list.
      final favoritedGroupTitles = playlist.allFavoritedGroupTitles.toList()
        ..sort();
      // Keyed by tab — same fix, and same reason, as
      // _buildBrowseGroupsColumn's own ListView key.
      return ListView(
        key: const ValueKey('Favorites'),
        children: [
          _SelectableRow(
            icon: Icons.apps,
            label: 'All',
            selected: _selectedGroup == null,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            onTap: () => _onGroupSelected(null),
          ),
          for (final title in favoritedGroupTitles)
            _SelectableRow(
              icon: Icons.grid_view_rounded,
              label: title,
              selected: _selectedGroup == title,
              collapsed: collapsed,
              fontSize: _groupFontSize,
              onTap: () => _onGroupSelected(title),
            ),
          if (favoritedGroupTitles.isEmpty && !collapsed)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Long-press a group elsewhere to favorite the whole thing.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
        ],
      );
    }

    final groups = playlist.tvGroups.where((g) => !g.isHidden).toList();
    // No "All" row — see _effectiveLiveGroup's doc comment for why an
    // unfiltered dumping-ground was actively confusing to land back in.
    final effectiveGroup = _effectiveLiveGroup(playlist);

    // Keyed by tab — same fix, and same reason, as
    // _buildBrowseGroupsColumn's own ListView key.
    return ListView(
      key: const ValueKey('TV'),
      children: [
        _SelectableRow(
          icon: Icons.star,
          label: 'Favourites',
          selected: effectiveGroup == _favoritesGroupSentinel,
          collapsed: collapsed,
          fontSize: _groupFontSize,
          onTap: () => _onGroupSelected(_favoritesGroupSentinel),
        ),
        ..._groupRowsWithPlaylistDividers(
          groups,
          playlist,
          collapsed: collapsed,
          rowBuilder: (group) => _GroupRow(
            icon: Icons.grid_view_rounded,
            label: group.title,
            selected: effectiveGroup == group.title,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            isFavorited:
                playlist.isGroupFavorited(group.playlistId, group.title),
            isPendingHide: _pendingHideGroups
                .contains(_groupKey(group.playlistId, group.title)),
            onTap: () =>
                _onGroupSelected(group.title, playlistId: group.playlistId),
            onLongPress: () => _showGroupOptions(group.playlistId, group.title),
          ),
        ),
      ],
    );
  }

  /// Groups rail for Movies/TV Shows — a fast way to jump to a category
  /// (see [_scrollToBrowseGroup]), brought back after removing it turned
  /// out to make finding a specific category slower, not simpler: without
  /// it, finding one meant scrolling through the whole poster catalog by
  /// hand instead of scanning a short list of names. Only lists categories
  /// that actually have a row to jump to right now — one that's still
  /// loading in the background isn't selectable here until it appears in
  /// the catalog below, at which point it shows up here too.
  Widget _buildBrowseGroupsColumn(PlaylistManager playlist,
      {required bool collapsed}) {
    final groups = (_tab == 'Movies'
            ? playlist.vodGroups
                .where((g) => !g.isHidden && g.channels.isNotEmpty)
            : playlist.seriesGroups.where((g) =>
                !g.isHidden &&
                playlist
                    .visibleSeries(
                        playlistId: g.playlistId, categoryName: g.title)
                    .isNotEmpty))
        .toList();

    // Keyed by tab — reported directly, live: simply *scrolling* down the
    // groups column (never tapping/selecting a group at all) in Movies,
    // then switching to TV Shows, still landed the D-pad focus partway
    // down TV Shows' own list instead of at the top. Replacing the
    // ancestor FocusScopeNode on tab change (see _onTabChanged) wasn't
    // enough on its own: with no key distinguishing "row 15 in Movies"
    // from "row 15 in TV Shows", Flutter's own element reconciliation
    // treats them as the *same* conceptual widget at the same position
    // and reuses its Element (and the FocusNode that Element's Focus/
    // InkWell owns internally) rather than disposing and recreating it —
    // and FocusManager's primary-focus pointer follows that FocusNode
    // object itself, not any particular ancestor scope, so reparenting it
    // under a brand-new scope doesn't un-focus it either. A key tied to
    // the tab forces Flutter to genuinely discard and rebuild this whole
    // subtree — every row's Element and FocusNode included — instead of
    // patching it in place, whenever the tab actually changes.
    return ListView(
      key: ValueKey(_tab),
      children: [
        // Pinned above the real categories, same shape as the Live TV
        // column's own "Favourites" entry — not a category, a view.
        _SelectableRow(
          icon: Icons.new_releases,
          label: "What's New",
          selected: _showWhatsNew,
          collapsed: collapsed,
          fontSize: _groupFontSize,
          onTap: () => setState(() => _showWhatsNew = true),
        ),
        _SelectableRow(
          icon: Icons.apps,
          label: 'All',
          selected: false,
          collapsed: collapsed,
          fontSize: _groupFontSize,
          onTap: () => _leaveWhatsNewThen(_scrollBrowseToTop),
        ),
        ..._groupRowsWithPlaylistDividers(
          groups,
          playlist,
          collapsed: collapsed,
          rowBuilder: (group) => _GroupRow(
            icon: Icons.grid_view_rounded,
            label: group.title,
            selected: false,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            isFavorited:
                playlist.isGroupFavorited(group.playlistId, group.title),
            isPendingHide: _pendingHideGroups
                .contains(_groupKey(group.playlistId, group.title)),
            onTap: () => _leaveWhatsNewThen(
                () => _scrollToBrowseGroup(group.playlistId, group.title)),
            onLongPress: () => _showGroupOptions(group.playlistId, group.title),
          ),
        ),
      ],
    );
  }

  Widget _buildMainArea(PlaylistManager playlist, EpgService epg) {
    if (_tab == 'Movies') return _buildMoviesBrowse(playlist);
    return _buildShowsBrowse(playlist);
  }

  // --- Live TV / Favorites: translucent list over the live video ----------
  //
  // The channel list used to be an opaque column next to a separate video
  // preview column. Merged into one region instead: the video plays
  // full-bleed behind everything, and the channel list floats over its
  // left portion on a solid dark scrim — translucent enough that the live
  // stream is visibly playing behind it, opaque enough that channel names
  // stay clearly readable. A real blur (`BackdropFilter`) would look more
  // "glass", but blurring a live video texture every frame is real GPU
  // cost — not worth risking on the weaker Formuler/Firestick hardware
  // this app has spent this whole session getting stable.

  Widget _buildLiveRegion(PlaylistManager playlist, EpgService epg) {
    // Kick off the live channel list's first load the moment this tab is
    // actually shown — see ensureLiveChannelsLoaded's doc comment for why
    // it's no longer loaded eagerly on launch. Fire-and-forget/no-op once
    // loaded or already loading, same shape as the Movies/TV Shows
    // category kick-off in _buildMoviesBrowse.
    unawaited(playlist.ensureLiveChannelsLoaded());

    // The Favorites tab's default ("All") view used to fall through to the
    // live-list-plus-video UI below, fed by a list that merged individually-
    // favorited live channels AND movies together — wrong for a movie (tap
    // tried to "play" it inline instead of opening its detail screen) and
    // confusing with both types jumbled into one list. Individually-
    // favorited live channels are reachable via the TV tab's own pinned
    // "Favourites" entry instead (_favoritesGroupSentinel, unaffected by
    // this) — this tab's default view now shows favorited movies/shows only.
    if (_tab == 'Favorites' && _selectedGroup == null) {
      return _buildFavoritesOverview(playlist);
    }

    // A favorited movies/TV-shows group selected from the Favorites tab
    // isn't playable as a plain channel tap-to-fullscreen the way a live
    // group is — it needs the actual movie/series catalog UI (posters,
    // tap through to the detail screen). Reported as "click on one of
    // those groups, it won't work" — it was routing through the live
    // channel list either way regardless of what kind of group it was.
    if (_tab == 'Favorites' &&
        _selectedGroup != null &&
        _selectedGroup != _favoritesGroupSentinel) {
      final resolved = _favoriteGroupCategory(playlist, _selectedGroup!);
      if (resolved != null &&
          (resolved.category == 'vod' || resolved.category == 'series')) {
        return _buildFavoriteGroupCatalog(
            playlist, resolved.category, resolved.playlistId, _selectedGroup!);
      }
    }

    final playback = context.watch<PlaybackService>();
    // Only a genuinely live channel belongs in this preview — a movie/
    // episode isn't stopped just because its fullscreen view was left
    // (deliberately, so a phone's MiniPlayerBar / the live island can
    // resume it), so `currentChannel` can easily be a VOD item while
    // browsing this tab. Reported live: backing out of a movie made it
    // start playing inline here, in a pane that's supposed to be "what's
    // live right now" — confusing on a tab that has nothing to do with
    // movies at all.
    // See PlaybackService.isSilentlyResuming's doc comment — a cold-start
    // background resume shouldn't make this pane jump straight to it
    // (and start fetching its EPG) before the user has actually looked
    // for it; it stays on the plain placeholder below until they do, even
    // though the stream itself is already loading regardless.
    final rawChannel =
        playback.isSilentlyResuming ? null : playback.currentChannel;
    // rawChannel.rawId, not rawChannel.id — Channel.isLiveId expects the
    // raw, unprefixed id.
    final channel = rawChannel != null && Channel.isLiveId(rawChannel.rawId)
        ? rawChannel
        : null;

    // A thin rounded frame around the whole pane — same "frosted glass"
    // language as SettingsPanel/the new gradient background, so this reads
    // as a deliberate card floating on the gradient instead of a plain
    // rectangle with hard edges directly on the coloured background.
    // `Container.clipBehavior` (not a separate `ClipRRect`) so the border
    // and the rounding are one paint operation instead of two, and so the
    // channel-list scrim's own top-left/bottom-left corners (its
    // `Positioned` touches this Stack's edges directly) pick up the same
    // rounding for free. Reported as looking unpolished next to the
    // brighter Settings redesign — this pane is the one part of the main
    // screen that's still full-bleed video.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.5),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: channel == null
                ? const Center(
                    child: Text('Select a channel to start watching'))
                // The video itself is a glance, not a scrub surface —
                // excluding it from focus stops the D-pad from getting
                // stuck on its internal Slider (Left/Right seek instead
                // of moving focus back to the lists).
                //
                // Was conditionally swapped for a plain ColoredBox while
                // `_coveredByPushedRoute` (i.e. whenever the fullscreen
                // player is on top) — a fix for a *theory* about two
                // simultaneous consumers of the same video texture, which
                // turned out to be wrong (the actual fullscreen black
                // screen persisted after that fix shipped). Worse: real
                // hardware logs during the black screen showed "Could not
                // find corresponding native window for surface" — a real
                // Android error meaning the decoder tried to render into a
                // surface that had already been torn down. Unmounting this
                // exact widget the instant the fullscreen player mounts is
                // a very plausible cause of exactly that: it tears down
                // this consumer's handle on the shared video texture at
                // the precise moment the new one needs it. Left mounted
                // (just visually covered) like it always used to be.
                // NOT torn down on entering/leaving fullscreen for the same
                // channel (this key doesn't change then, so no remount
                // happens; the crash risk noted above stays fully avoided).
                //
                // Keyed by channel id for a *different* reason: this same
                // shared-controller architecture (one VideoPlayerHdrController
                // in PlaybackService, reused across this pane, the fullscreen
                // player, and the live island pill) turned out to cause a
                // real, reproducible bug of its own — this pane going stale
                // on a channel switch, still showing the previous channel's
                // last frame while the new stream is genuinely already
                // playing elsewhere (confirmed absent on the pre-Live-Island
                // 3.20.1 build, so this shared-controller design is the
                // actual cause, not a pre-existing platform-view issue).
                // Forcing Flutter to fully tear down and recreate this pane's
                // Element/platform view whenever the *live* channel id
                // actually changes — same fix already applied at the other
                // two VideoPlayerPane call sites (home_screen.dart,
                // player_screen.dart) — is the deliberate risk being taken
                // here: it only remounts on a genuine channel change, never
                // on a fullscreen enter/exit for the same channel, so it
                // shouldn't reintroduce the concurrent-consumer race above —
                // but this is the one call site that race was originally
                // found on, so treat this as the higher-risk half of the fix
                // if a freeze reappears in a different shape.
                : ExcludeFocus(
                    child: VideoPlayerPane(
                        key: ValueKey(channel.id), showEpgBar: false),
                  ),
          ),
          if (channel != null)
            Positioned(
              // A couple px further in than before — right up against the
              // pane's own new rounded corner (above), an 8px inset let the
              // button's circular edge clip visually into the curve.
              top: 12,
              right: 12,
              child: IconButton.filledTonal(
                icon: const Icon(Icons.fullscreen),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlayerScreen(channel: channel))),
              ),
            ),
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: 380,
            child: Container(
              color: Colors.black.withValues(alpha: 0.62),
              child: Column(
                children: [
                  Expanded(child: _buildLiveList(playlist)),
                  if (channel != null)
                    SizedBox(
                        height: 170,
                        child: _ProgramDetails(channel: channel, epg: epg)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleFavoriteWithFeedback(BuildContext context, Channel channel) {
    context.read<PlaylistManager>().toggleFavorite(channel);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          channel.isFavorite ? 'Added to Favorites' : 'Removed from Favorites'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _toggleSeriesFavoriteWithFeedback(
      BuildContext context, XtreamSeries series) {
    context.read<PlaylistManager>().toggleSeriesFavorite(series);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          series.isFavorite ? 'Added to Favorites' : 'Removed from Favorites'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Individually-favorited movies/TV shows as two poster-grid sections —
  /// the Favorites tab's default ("All") view. Individually-favorited live
  /// channels are deliberately excluded here; they stay reachable via the
  /// TV tab's own pinned "Favourites" entry instead (see [_buildLiveRegion]).
  Widget _buildFavoritesOverview(PlaylistManager playlist) {
    final storage = context.read<StorageService>();
    final movies = playlist.favoriteMovies;
    final isXtream = playlist.isXtream;
    final series = isXtream ? playlist.favoriteSeries : null;
    final showChannels = isXtream ? null : playlist.favoriteShowChannels;
    final showsEmpty = isXtream ? series!.isEmpty : showChannels!.isEmpty;

    if (movies.isEmpty && showsEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No favorited movies or TV shows yet.\nHold Select on a poster to add one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SectionLabel('Movies')),
        if (movies.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('No favorited movies yet.',
                style: TextStyle(color: Colors.white54)),
          )
        else
          _posterGrid(
            movies,
            (c) => PosterCard(
              title: c.name,
              imageUrl: c.logoUrl,
              rating: c.rating,
              watched: storage.isFullyWatched(c.id),
              progressFraction: storage.getWatchedFraction(c.id),
              isFavorite: c.isFavorite,
              onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
              onTap: () => _openMovie(c),
              onFocusGained: () {},
            ),
            shrinkWrap: true,
          ),
        const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SectionLabel('TV Shows')),
        if (showsEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('No favorited TV shows yet.',
                style: TextStyle(color: Colors.white54)),
          )
        else if (isXtream)
          _posterGrid(
            series!,
            (s) => PosterCard(
              title: s.name,
              imageUrl: s.coverUrl,
              rating: s.rating,
              isFavorite: s.isFavorite,
              onToggleFavorite: () =>
                  _toggleSeriesFavoriteWithFeedback(context, s),
              onTap: () => _openSeries(s),
              onFocusGained: () {},
            ),
            shrinkWrap: true,
          )
        else
          _posterGrid(
            showChannels!,
            (c) => PosterCard(
              title: c.name,
              imageUrl: c.logoUrl,
              isFavorite: c.isFavorite,
              onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
              onTap: () => _openMovie(c),
              onFocusGained: () {},
            ),
            shrinkWrap: true,
          ),
      ],
    );
  }

  /// Poster grid for a single favorited movies/TV-shows group, filling the
  /// same region the live list+video normally occupies on this tab.
  Widget _buildFavoriteGroupCatalog(PlaylistManager playlist, String category,
      String playlistId, String title) {
    final storage = context.read<StorageService>();
    final Widget grid;
    if (category == 'vod') {
      final group = playlist.vodGroups.firstWhere(
        (g) => g.title == title && g.playlistId == playlistId,
        orElse: () =>
            M3uGroup(title: title, playlistId: playlistId, channels: const []),
      );
      grid = _posterGrid(
          group.channels,
          (c) => PosterCard(
                title: c.name,
                imageUrl: c.logoUrl,
                rating: c.rating,
                watched: storage.isFullyWatched(c.id),
                progressFraction: storage.getWatchedFraction(c.id),
                isFavorite: c.isFavorite,
                onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
                onTap: () => _openMovie(c),
                onFocusGained: () {},
              ));
    } else {
      final series =
          playlist.visibleSeries(playlistId: playlistId, categoryName: title);
      grid = _posterGrid(
          series,
          (s) => PosterCard(
                title: s.name,
                imageUrl: s.coverUrl,
                rating: s.rating,
                isFavorite: s.isFavorite,
                onToggleFavorite: () =>
                    _toggleSeriesFavoriteWithFeedback(context, s),
                onTap: () => _openSeries(s),
                onFocusGained: () {},
              ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SectionLabel(title)),
        Expanded(child: grid),
      ],
    );
  }

  Widget _posterGrid<T>(List<T> items, Widget Function(T) posterBuilder,
      {bool shrinkWrap = false}) {
    if (items.isEmpty)
      return const Center(child: Text('No items in this group.'));
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: PosterCard.width + 12,
        mainAxisExtent: PosterCard.height + 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => posterBuilder(items[i]),
    );
  }

  Widget _buildLiveList(PlaylistManager playlist) {
    final channels = _currentLiveChannels(playlist);

    if (channels.isEmpty) {
      return Center(
        child: Text(
          _selectedGroup == _favoritesGroupSentinel
              ? 'No favorite channels yet — press Down while watching one to add it.'
              : 'No channels found.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return Consumer<PlaybackService>(
      builder: (context, playback, _) => ListView.builder(
        controller: _liveListController,
        itemCount: channels.length,
        itemBuilder: (context, i) {
          final channel = channels[i];
          final isSelected = playback.currentChannel?.id == channel.id;
          // The trailing star used to be independently D-pad-focusable (a
          // plain IconButton) — reported directly: moving down the list
          // would land the cursor on the star instead of the next channel,
          // so "select" toggled favorite instead of playing. Long-press
          // does what tapping the star used to (matches the group-favorite
          // gesture elsewhere), and the star itself is excluded from focus
          // traversal so D-pad Up/Down only ever stops on the row itself.
          // `_SelectableRow`'s own `onLongPress` only fires from a touch/
          // mouse long-press though (InkWell.onLongPress is touch-only) —
          // HoldToActivate adds the equivalent for a *held* remote Select
          // key, which is the case that actually matters on real hardware.
          return HoldToActivate(
            onTap: () => _selectChannel(channel),
            onHold: () => _toggleFavoriteWithFeedback(context, channel),
            child: _SelectableRow(
              selected: isSelected,
              focusNode: isSelected ? _currentChannelFocusNode : null,
              onTap: () => _selectChannel(channel),
              onLongPress: () => _toggleFavoriteWithFeedback(context, channel),
              leading: SizedBox(
                width: 40,
                height: 40,
                child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: channel.logoUrl!,
                        fit: BoxFit.contain,
                        memCacheWidth:
                            (40 * MediaQuery.of(context).devicePixelRatio)
                                .round(),
                        memCacheHeight:
                            (40 * MediaQuery.of(context).devicePixelRatio)
                                .round(),
                        errorWidget: (_, __, ___) => const Icon(Icons.tv))
                    : const Icon(Icons.tv),
              ),
              label: channel.name,
              // rawId, not the composite `id` — see
              // PlaylistManager.knownChannelIdsFor's doc comment.
              subtitle: _CurrentProgramLine(channelId: channel.rawId),
              trailing: ExcludeFocus(
                child: IconButton(
                  icon: Icon(
                      channel.isFavorite ? Icons.star : Icons.star_border,
                      color:
                          channel.isFavorite ? Colors.amber : Colors.white70),
                  onPressed: () =>
                      _toggleFavoriteWithFeedback(context, channel),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // --- Movies / TV Shows: poster-row browse ---------------------------------
  //
  // No group-picker column — the browse view already organizes everything
  // by category via row headers, so a separate "pick a group" step was
  // just showing an empty row until that one category happened to be
  // fetched. Straight from the tab into the catalog instead.

  /// A "Continue Watching" row built from [PlaybackService.recentlyPlayed],
  /// filtered to items of the right content type (movies vs. episodes, via
  /// their `xt_vod_`/`xt_ep_` id prefix from [XtreamApiService]) that
  /// actually have a saved resume position. Null when there's nothing to
  /// resume, so callers can skip it entirely rather than render an empty row.
  Widget? _buildContinueWatchingRow(
      {required String idPrefix, required void Function(Channel) onTap}) {
    final playback = context.watch<PlaybackService>();
    final storage = context.read<StorageService>();
    var items = playback.recentlyPlayed
        .where((c) =>
            c.rawId.startsWith(idPrefix) && storage.getLastPosition(c.id) > 0)
        .toList();

    // Episodes: one card per *show*, not per episode. recentlyPlayed is
    // newest-first, so the first episode seen for a given series is the
    // one actually being resumed — without this, finishing episode 4 and
    // starting episode 5 of the same show showed up as two separate
    // cards, and the older one no longer even reflected where playback
    // actually was.
    final isEpisodes = idPrefix == 'xt_ep_';
    if (isEpisodes) {
      final seenSeries = <int>{};
      items = [
        for (final c in items)
          if (c.seriesId == null || seenSeries.add(c.seriesId!)) c
      ];
    }

    if (items.isEmpty) return null;
    return KeyedSubtree(
      key: _continueWatchingRowKey,
      child: _CategoryRow<Channel>(
        title: 'Continue Watching',
        items: items,
        itemBuilder: (c, index) {
          // A show resumes into its season/episode list (so the user can
          // actually see what's next and how far along they are), not
          // straight back into playback the way a movie does.
          final asSeries = isEpisodes && c.seriesId != null;
          final title = asSeries ? (c.seriesName ?? c.name) : c.name;
          final imageUrl =
              asSeries ? (c.seriesCoverUrl ?? c.logoUrl) : c.logoUrl;
          return PosterCard(
            title: title,
            imageUrl: imageUrl,
            rating: c.rating,
            watched: storage.isFullyWatched(c.id),
            progressFraction: storage.getWatchedFraction(c.id),
            focusNode: index == 0 ? _continueWatchingFirstFocusNode : null,
            onTap: () => asSeries
                ? _openSeries(XtreamSeries(
                    seriesId: c.seriesId!,
                    playlistId: c.playlistId,
                    name: c.seriesName ?? c.name,
                    categoryId: '',
                    coverUrl: c.seriesCoverUrl,
                  ))
                : onTap(c),
            onFocusGained: () {
              _updateBrowseFocus(title, imageUrl);
              _ensureRowVisible(_continueWatchingRowKey);
            },
          );
        },
      ),
    );
  }

  Widget _buildMoviesBrowse(PlaylistManager playlist) {
    // Temporary diagnostic — see PlaylistManager.ensureCategoryLoaded's
    // matching comment. Pins down whether a ~10s gap seen between
    // category-load batches is because this build method itself is only
    // being re-entered every ~10s (a rebuild-triggering problem upstream
    // of ensureCategoriesLoaded), or because it's called constantly but
    // something inside the loading path is silently stalling.
    debugPrint('BuildMovies at ${DateTime.now().toIso8601String()}');
    // !isHidden matters here, not just in the groups quick-jump column —
    // without it, a category filtered out via the content filter or Group
    // Management still showed up in the actual catalog, just missing from
    // the shortcut list pointing at it.
    final storage = context.read<StorageService>();
    final visibleGroups = playlist.vodGroups.where((g) => !g.isHidden).toList();
    // Kick off the first load for every visible category that isn't
    // loaded yet (fire-and-forget, concurrency-capped — see
    // ensureCategoriesLoaded's doc comment for why a plain per-category
    // loop here caused a real ANR on a brand-new provider with hundreds of
    // categories). Needed since disabling the automatic background warm-up
    // (a real ANR fix on a large catalog) otherwise left nothing to ever
    // trigger a category's *first* load on a plain relaunch: this row list
    // only shows categories that already have items, and the groups
    // quick-jump column requires the same — with nothing pre-populating
    // them, Movies/TV Shows was stuck forever on "Loading movie
    // categories...". Grouped by playlistId first — ensureCategoriesLoaded
    // now targets one specific playlist's session, so a merged list
    // spanning more than one playlist needs one call per playlist.
    for (final entry
        in _groupByPlaylist(visibleGroups.where((g) => g.channels.isEmpty))) {
      unawaited(playlist.ensureCategoriesLoaded(
          entry.playlistId, entry.groups.map((g) => g.title), 'vod'));
    }
    if (_showWhatsNew) {
      return _WhatsNewCarousel<Channel>(
        loadItems: playlist.whatsNewVod,
        titleOf: (c) => c.name,
        imageUrlOf: (c) => c.logoUrl,
        onOpen: _openMovie,
        playFocusNode: _whatsNewPlayFocusNode,
        emptyText: 'No recently added movies yet',
      );
    }
    final groupsWithItems =
        visibleGroups.where((g) => g.channels.isNotEmpty).toList();
    final continueRow =
        _buildContinueWatchingRow(idPrefix: 'xt_vod_', onTap: _openMovie);
    return _buildBrowseScaffold(
      rows: [
        if (continueRow != null) continueRow,
        for (final group in groupsWithItems)
          KeyedSubtree(
            key: _keyForGroup(group.playlistId, group.title),
            child: _CategoryRow<Channel>(
              // The real category size (which can be well past the
              // _maxItemsPerCategory render cap that group.channels.length
              // is limited to) when known — see
              // PlaylistManager.vodCategoryTotalCount's doc comment.
              title:
                  '${group.title} (${playlist.vodCategoryTotalCount(group.playlistId, group.title) ?? group.channels.length})',
              items: group.channels,
              itemBuilder: (c, index) => PosterCard(
                title: c.name,
                imageUrl: c.logoUrl,
                rating: c.rating,
                watched: storage.isFullyWatched(c.id),
                progressFraction: storage.getWatchedFraction(c.id),
                focusNode: index == 0
                    ? _firstPosterFocusNodeForGroup(
                        group.playlistId, group.title)
                    : null,
                isFavorite: c.isFavorite,
                onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
                onTap: () => _openMovie(c),
                onFocusGained: () {
                  _updateBrowseFocus(c.name, c.logoUrl);
                  _ensureRowVisible(
                      _keyForGroup(group.playlistId, group.title));
                },
              ),
            ),
          ),
      ],
      emptyText: groupsWithItems.isEmpty ? 'Loading movie categories...' : null,
    );
  }

  /// Splits a merged group list back out by playlist — used wherever an
  /// operation (`ensureCategoriesLoaded`) targets one specific playlist's
  /// session and needs one call per playlist rather than one call for a
  /// list that might span several.
  Iterable<({String playlistId, List<M3uGroup> groups})> _groupByPlaylist(
      Iterable<M3uGroup> groups) {
    final byId = <String, List<M3uGroup>>{};
    for (final g in groups) {
      byId.putIfAbsent(g.playlistId, () => []).add(g);
    }
    return byId.entries.map((e) => (playlistId: e.key, groups: e.value));
  }

  Widget _buildShowsBrowse(PlaylistManager playlist) {
    // Temporary diagnostic — see _buildMoviesBrowse's matching comment.
    debugPrint('BuildShows at ${DateTime.now().toIso8601String()}');
    final groups = playlist.seriesGroups.where((g) => !g.isHidden).toList();
    final rows = <Widget>[];
    // Episodes resume straight into playback (no detail screen in between)
    // — the user already picked this episode once, "Continue Watching"
    // means "keep watching it", not "go re-browse its season".
    final continueRow =
        _buildContinueWatchingRow(idPrefix: 'xt_ep_', onTap: _selectChannel);
    if (continueRow != null) rows.add(continueRow);
    // See the identical kick-off in _buildMoviesBrowse (concurrency-capped
    // via ensureCategoriesLoaded — a plain per-category loop here fired
    // every category's network fetch at once on a brand-new provider,
    // confirmed to cause a real ANR). Grouped by playlist — see
    // _groupByPlaylist's doc comment.
    final emptyGroups = groups.where((g) => playlist
        .visibleSeries(playlistId: g.playlistId, categoryName: g.title)
        .isEmpty);
    for (final entry in _groupByPlaylist(emptyGroups)) {
      unawaited(playlist.ensureCategoriesLoaded(
          entry.playlistId, entry.groups.map((g) => g.title), 'series'));
    }
    if (_showWhatsNew) {
      return _WhatsNewCarousel<XtreamSeries>(
        loadItems: playlist.whatsNewSeries,
        titleOf: (s) => s.name,
        imageUrlOf: (s) => s.coverUrl,
        onOpen: _openSeries,
        playFocusNode: _whatsNewPlayFocusNode,
        emptyText: 'No recently added shows yet',
      );
    }
    for (final group in groups) {
      final items = playlist.visibleSeries(
          playlistId: group.playlistId, categoryName: group.title);
      if (items.isEmpty) continue;
      rows.add(KeyedSubtree(
        key: _keyForGroup(group.playlistId, group.title),
        child: _CategoryRow<XtreamSeries>(
          // See _buildMoviesBrowse's identical fix for why this isn't
          // just items.length.
          title:
              '${group.title} (${playlist.seriesCategoryTotalCount(group.playlistId, group.title) ?? items.length})',
          items: items,
          itemBuilder: (s, index) => PosterCard(
            title: s.name,
            imageUrl: s.coverUrl,
            rating: s.rating,
            focusNode: index == 0
                ? _firstPosterFocusNodeForGroup(group.playlistId, group.title)
                : null,
            isFavorite: s.isFavorite,
            onToggleFavorite: () =>
                _toggleSeriesFavoriteWithFeedback(context, s),
            onTap: () => _openSeries(s),
            onFocusGained: () {
              _updateBrowseFocus(s.name, s.coverUrl);
              _ensureRowVisible(_keyForGroup(group.playlistId, group.title));
            },
          ),
        ),
      ));
    }
    return _buildBrowseScaffold(
      rows: rows,
      emptyText: rows.isEmpty ? 'Loading TV show categories...' : null,
    );
  }

  Widget _buildBrowseScaffold({required List<Widget> rows, String? emptyText}) {
    return Column(
      children: [
        _BrowseHero(title: _focusedTitle, imageUrl: _focusedImageUrl),
        Expanded(
          child: emptyText != null
              ? Center(child: Text(emptyText))
              : ListView.builder(
                  controller: _browseScrollController,
                  itemCount: rows.length,
                  itemBuilder: (context, i) => rows[i],
                ),
        ),
      ],
    );
  }
}

/// A tab/group/channel row styled with a solid highlight bar when selected,
/// instead of relying on default `ListTile` selected-tint (which reads as
/// too subtle at 10-foot viewing distance). Collapses to an icon-only
/// square when [collapsed].
class _SelectableRow extends StatefulWidget {
  const _SelectableRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.collapsed = false,
    this.icon,
    this.leading,
    this.subtitle,
    this.trailing,
    this.fontSize,
    this.focusNode,
  });

  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData? icon;
  final Widget? leading;
  final Widget? subtitle;
  final Widget? trailing;

  /// Only needed by the currently-playing channel row (see
  /// `_restoreLiveFocus`), so it can be re-focused explicitly after
  /// returning from fullscreen — every other row leaves this null and gets
  /// its own internal node from `InkWell` as usual.
  final FocusNode? focusNode;

  /// Defaults to the ambient text style's size when null (tabs/channel
  /// list rows) — group rows pass a smaller explicit size instead.
  final double? fontSize;

  @override
  State<_SelectableRow> createState() => _SelectableRowState();
}

class _SelectableRowState extends State<_SelectableRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    // Focus (where the D-pad cursor currently is) and "selected" (this is
    // the channel actually playing, which stays true while focus has moved
    // on to browse something else) are different facts and were rendered
    // identically — a solid primary fill — which read as "multiple things
    // highlighted at once" whenever something was playing in the
    // background while the cursor sat elsewhere. Only the live D-pad
    // cursor gets the solid fill now; "currently playing" gets a quieter
    // tinted/outlined treatment instead.
    final isPlaying = widget.selected && !_focused;
    // A flat primary fill on focus read as one more grey/purple box, but
    // `Ink`'s gradient decoration turned out to have a real cost: on this
    // hardware (weak enough that Impeller is disabled elsewhere in the
    // app) it showed a brief white/grey flash whenever a row rebuilt
    // during scrolling or navigation — `Ink` re-registers its paint with
    // the nearest Material a frame behind a plain `color`. A blended flat
    // color computed once still reads as "the palette", not just primary,
    // with none of that risk.
    // Minimalist's `scheme.primary`/`.secondary` are opaque-ish white/
    // white70 (see `buildPaletteColorScheme`) — blending them the same way
    // as every other palette would read as a solid near-white block, not
    // the "glass" look. Same translucent-white-fill + solid-white-text
    // pattern as `_tvButtonStyle`/`TvSwitchListTile` use elsewhere.
    final useGlass = isMinimal && _focused;
    final focusedColor = isMinimal
        ? Colors.white.withValues(alpha: 0.16)
        : Color.lerp(scheme.primary, scheme.secondary, 0.5)!;
    final unfocusedColor = isPlaying
        ? scheme.primary.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.04);
    final focusedForeground = isMinimal ? Colors.white : scheme.onPrimary;
    final foregroundColor = _focused
        ? focusedForeground
        : (isPlaying ? scheme.primary : Colors.white);
    final iconColor = _focused
        ? focusedForeground
        : (isPlaying ? scheme.primary : Colors.white70);
    final leadingWidget =
        widget.leading ?? Icon(widget.icon, color: iconColor, size: 20);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: MinimalGlassFocus(
        active: useGlass,
        borderRadius: 8,
        child: Material(
          color: (_focused && !useGlass) ? focusedColor : unfocusedColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            // A persistent marker for "this is actually the active tab /
            // now playing", independent of D-pad focus — confirmed on
            // hardware as a real gap: once focus moved to a different row,
            // there was no visible difference between "the cursor is
            // resting here" and "this is genuinely selected", since both
            // states used the identical solid fill. Reported directly: the
            // cursor sat on Movies while TV Shows was still the real
            // active tab (its content was still on screen) and Movies
            // looked selected instead. A border persists through focus
            // changes, unlike the fill.
            side: widget.selected
                ? BorderSide(color: scheme.primary, width: 2)
                : BorderSide.none,
          ),
          child: InkWell(
            focusNode: widget.focusNode,
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onFocusChange: (f) {
              setState(() => _focused = f);
              if (f) _ensureVisible(context);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: widget.collapsed
                  ? Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          leadingWidget,
                          if (isPlaying)
                            Positioned(
                              right: -3,
                              top: -3,
                              child: Icon(Icons.circle,
                                  size: 8, color: scheme.primary),
                            ),
                        ],
                      ),
                    )
                  : Row(
                      children: [
                        leadingWidget,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  if (isPlaying) ...[
                                    Icon(Icons.play_arrow,
                                        size: 14, color: scheme.primary),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: Text(
                                      widget.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: foregroundColor,
                                        fontSize: widget.fontSize,
                                        fontWeight: (_focused || isPlaying)
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        // The Live TV list floats translucent
                                        // over the video now — a shadow keeps
                                        // the name readable no matter how
                                        // bright/busy whatever's playing
                                        // behind it is. Harmless on the solid
                                        // backgrounds this row is also used
                                        // on (tabs, groups).
                                        shadows: const [
                                          Shadow(
                                              color: Colors.black,
                                              blurRadius: 4)
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (widget.subtitle != null)
                                DefaultTextStyle.merge(
                                  style: TextStyle(
                                    color: _focused
                                        ? focusedForeground.withValues(
                                            alpha: 0.85)
                                        : Colors.white54,
                                  ),
                                  child: widget.subtitle!,
                                ),
                            ],
                          ),
                        ),
                        if (widget.trailing != null) widget.trailing!,
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks a transition between two playlists' groups in a merged column —
/// reported directly: with two playlists enabled, their groups landed in
/// one flat list with nothing showing where one ended and the other
/// began. Deliberately not focusable/selectable (this is a label, not a
/// row) and not shown at all in [collapsed] mode — there's no room for a
/// name in the icon-only strip, so it collapses to a plain divider line
/// instead of trying to cram text in.
class _PlaylistDividerRow extends StatelessWidget {
  const _PlaylistDividerRow({required this.name, required this.collapsed});

  final String name;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return const Divider(height: 16, color: Colors.white24);
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          name.isEmpty ? 'Playlist' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: 12,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

/// A real category row (unlike "All"/"Favourites", which are pseudo-entries
/// with no group-level actions) — long-press brings up "add/remove
/// favorites" and "hide" for the whole group.
///
/// Deliberately its own widget rather than adding this to [_SelectableRow]:
/// touch long-press is trivial (`GestureDetector.onLongPress` already
/// works), but there's no equivalent for a D-pad — Flutter doesn't have a
/// "key held for N ms" primitive, so this hand-rolls one from raw
/// KeyDownEvent/KeyUpEvent timing instead of reusing `InkWell`'s built-in
/// Enter/Select activation (which fires immediately on key-down and can't
/// be delayed to distinguish a tap from a hold). Keeping that experiment
/// contained to group rows means every other list in the app (tabs,
/// channels, settings) keeps using the already-proven `_SelectableRow`
/// untouched.
class _GroupRow extends StatefulWidget {
  const _GroupRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    required this.onLongPress,
    this.isFavorited = false,
    this.isPendingHide = false,
    this.fontSize,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool isFavorited;
  final bool isPendingHide;
  final double? fontSize;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _focused = false;
  Timer? _longPressTimer;
  bool _longPressFired = false;

  static const _longPressDuration = Duration(milliseconds: 550);

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isActivateKey = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA;
    if (!isActivateKey) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _longPressFired = false;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPressDuration, () {
        _longPressFired = true;
        widget.onLongPress();
      });
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _longPressTimer?.cancel();
      if (!_longPressFired) widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMinimal = context.watch<AppPreferences>().palette.isMinimal;
    final highlighted = widget.selected || _focused;
    final useGlass = isMinimal && _focused;
    // Same translucent-white-fill + solid-white-text swap as
    // `_SelectableRow`'s own isMinimal branch — see its doc comment.
    final focusedForeground = isMinimal ? Colors.white : scheme.onPrimary;
    final backgroundColor = (_focused && !useGlass)
        ? scheme.primary
        : widget.selected
            ? scheme.primary.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.04);
    final foregroundColor = highlighted ? focusedForeground : Colors.white;
    final iconColor = highlighted ? focusedForeground : Colors.white70;

    final iconWidget = Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(widget.icon, color: iconColor, size: 20),
        if (widget.isFavorited)
          Positioned(
            right: -4,
            top: -4,
            child: Icon(Icons.star,
                size: 12,
                color: highlighted ? focusedForeground : Colors.amber),
          ),
      ],
    );

    return Opacity(
      opacity: widget.isPendingHide ? 0.4 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Focus(
          onKeyEvent: _handleKeyEvent,
          onFocusChange: (f) {
            setState(() => _focused = f);
            if (f) _ensureVisible(context);
          },
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: MinimalGlassFocus(
              active: useGlass,
              borderRadius: 8,
              child: Material(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: widget.collapsed
                      ? Center(child: iconWidget)
                      : Row(
                          children: [
                            iconWidget,
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: foregroundColor,
                                  fontSize: widget.fontSize,
                                  fontWeight: highlighted
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One horizontally-scrolling row of [PosterCard]s under a category title
/// — the Netflix/Apple-TV "browse" pattern. Builds cards lazily as they
/// scroll into view — a category can hold thousands of items.
class _CategoryRow<T> extends StatelessWidget {
  const _CategoryRow(
      {required this.title, required this.items, required this.itemBuilder});

  final String title;
  final List<T> items;

  /// Takes the index too — the caller (see [_buildMoviesBrowse]/
  /// [_buildShowsBrowse]) gives the first card in each row a dedicated
  /// [FocusNode] so the groups quick-jump can focus it directly.
  final Widget Function(T item, int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SectionLabel(
              title,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
          ),
          SizedBox(
            // Was 210 — ~20% smaller per feedback that the catalog read
            // too large.
            height: PosterCard.height,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              itemCount: items.length,
              // Flutter's default (250px, ~2 cards) only starts building/
              // decoding a card just barely before it's visible, so a
              // steady scroll still shows the grey-then-fade-in pop-in
              // right at the edge of the screen. Roughly 5 cards' worth
              // gives posters a head start decoding before they're seen —
              // some extra memory (the image cache ceiling still bounds
              // the total), traded for a visibly smoother scroll.
              scrollCacheExtent:
                  const ScrollCacheExtent.pixels(PosterCard.width * 5),
              itemBuilder: (context, i) => itemBuilder(items[i], i),
            ),
          ),
        ],
      ),
    );
  }
}

/// Big backdrop header showing whatever poster card currently has D-pad
/// focus, with its title overlaid — mirrors the hero-banner pattern from
/// Apple TV / Android TV browse screens.
class _BrowseHero extends StatelessWidget {
  const _BrowseHero({required this.title, required this.imageUrl});

  final String? title;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      // Was 200 — tall enough that its bottom-edge title overlapped the
      // Continue Watching row's own label right below it once you moved
      // focus into the catalog.
      height: 130,
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // Was a custom-painted gradient border (GradientBoxBorder) — a
        // Canvas shader repainting every time this rebuilds (every focus
        // change while scrolling) turned out to be part of the same
        // flicker cost as _SelectableRow's Ink change. A blended flat
        // color border keeps the duo-tone edge with a plain, cheap Border.
        border: Border.all(
            color: Color.lerp(scheme.primary, scheme.secondary, 0.5)!,
            width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.grey.shade900),
          if (imageUrl != null && imageUrl!.isNotEmpty)
            CachedNetworkImage(
              imageUrl: imageUrl!,
              key: ValueKey(imageUrl),
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Color.alphaBlend(scheme.primary.withValues(alpha: 0.35),
                      Colors.black.withValues(alpha: 0.85)),
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            bottom: 16,
            right: 20,
            child: Row(
              children: [
                Container(width: 4, height: 22, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title ?? 'Browse',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Movies/TV Shows tabs' default view: the handful of titles the
/// provider added most recently, as an auto-advancing slideshow that fills
/// the content area, in [_BrowseHero]'s visual language scaled up from a
/// header strip to a full page.
///
/// Generic over the item type for the same reason [_CategoryRow] is — the
/// movies and TV shows variants differ only in which field holds the title
/// and the artwork, not in any of the paging/focus behavior below.
class _WhatsNewCarousel<T> extends StatefulWidget {
  const _WhatsNewCarousel({
    required this.loadItems,
    required this.titleOf,
    required this.imageUrlOf,
    required this.onOpen,
    required this.playFocusNode,
    required this.emptyText,
  });

  /// A loader, deliberately not an already-created `Future`: this widget's
  /// parent rebuilds on every `PlaylistManager` notification, and taking a
  /// future directly would hand the `FutureBuilder` below a brand-new one
  /// each time — flashing back to the loading state over and over while
  /// the catalog is busy.
  final Future<List<T>> Function() loadItems;

  final String Function(T item) titleOf;
  final String? Function(T item) imageUrlOf;
  final void Function(T item) onOpen;

  /// Owned by `_TvHomeScreenState` — see its own doc comment on why the
  /// Play button's focus is requested from out there rather than
  /// autofocused from in here.
  final FocusNode playFocusNode;

  final String emptyText;

  @override
  State<_WhatsNewCarousel<T>> createState() => _WhatsNewCarouselState<T>();
}

class _WhatsNewCarouselState<T> extends State<_WhatsNewCarousel<T>>
    with RouteAware {
  static const _advanceInterval = Duration(seconds: 4);

  final PageController _pageController = PageController();
  late final Future<List<T>> _itemsFuture;
  Timer? _timer;
  int _index = 0;
  int _itemCount = 0;

  @override
  void initState() {
    super.initState();
    _itemsFuture = widget.loadItems().then((items) {
      if (mounted) {
        _itemCount = items.length;
        _startTimer();
      }
      return items;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// Something now covers this screen (a movie/series detail screen, the
  /// fullscreen player). An auto-advance that keeps firing `setState` on a
  /// covered-but-still-mounted carousel is pure waste for as long as that
  /// route is up — the same "timer outlives what it's actually for" bug
  /// class already fixed for the player's seek buttons, avoided here by
  /// design rather than patched afterwards.
  @override
  void didPushNext() => _timer?.cancel();

  @override
  void didPopNext() => _startTimer();

  void _startTimer() {
    _timer?.cancel();
    if (_itemCount < 2) return;
    _timer = Timer.periodic(_advanceInterval, (_) => _goTo(_index + 1));
  }

  /// Modulo, not `nextPage`/`previousPage`: those stop dead at either end,
  /// and a slideshow that quietly stops advancing after the 5th title
  /// reads as broken.
  void _goTo(int target) {
    if (_itemCount == 0 || !_pageController.hasClients) return;
    _pageController.animateToPage(
      target % _itemCount,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  void _step(int delta) {
    _goTo(_index + delta);
    // Restarted, not left running: a deliberate press shouldn't be
    // overridden a fraction of a second later by the next auto-tick.
    _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<T>>(
      future: _itemsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: Text('Loading...'));
        }
        final items = snapshot.data ?? <T>[];
        if (items.isEmpty) return Center(child: Text(widget.emptyText));
        return Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: items.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) =>
                    _buildPage(context, items[i], blurred: i == _index),
              ),
            ),
            _buildDots(context, items.length),
            _buildNavRow(context, items),
          ],
        );
      },
    );
  }

  Widget _buildPage(BuildContext context, T item, {required bool blurred}) {
    final scheme = Theme.of(context).colorScheme;
    final imageUrl = widget.imageUrlOf(item);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Color.lerp(scheme.primary, scheme.secondary, 0.5)!,
              width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // A blurred, cover-fit copy of the same poster fills the wide
            // backdrop behind it — the crisp copy in front (below) stays
            // BoxFit.contain and untouched, so the actual poster is never
            // stretched or cropped; this just gives the empty letterboxed
            // space either side of a portrait poster something to look at
            // instead of flat grey, same idea as a Plex/Netflix hero panel.
            //
            // Only ever applied to the currently-focused page, never the
            // one or two neighbors PageView.builder keeps built for a
            // smooth swipe — a GPU blur over a full-bleed image is
            // expensive, and having 2-3 of them compositing at once
            // (every 4s, on every auto-advance) is a real crash risk on
            // weaker TV-box/Fire-Stick GPUs, not just a jank concern.
            if (blurred && imageUrl != null && imageUrl.isNotEmpty)
              RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            if (blurred && imageUrl != null && imageUrl.isNotEmpty)
              DecoratedBox(
                decoration:
                    BoxDecoration(color: Colors.black.withValues(alpha: 0.35)),
              ),
            if (imageUrl != null && imageUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: imageUrl,
                key: ValueKey(imageUrl),
                // contain, not _BrowseHero's cover: filling an area this
                // large with a portrait poster would crop it down to a
                // thin band through the middle.
                fit: BoxFit.contain,
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color.alphaBlend(scheme.primary.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.85)),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: Row(
                children: [
                  Container(width: 4, height: 26, color: scheme.secondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.titleOf(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDots(BuildContext context, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == _index ? scheme.primary : Colors.white24,
              ),
            ),
        ],
      ),
    );
  }

  /// Three real focusable stops in a row, so moving between titles and
  /// actually starting one is a single continuous D-pad motion: arrow over
  /// to the title you want, a Right press or two lands on Play, Select.
  /// Deliberately not "press Select on the artwork itself" — the artwork
  /// isn't focusable at all here. Left/Right *between* these three is
  /// ordinary directional traversal (they're laid out horizontally), same
  /// as every other button row in this app.
  Widget _buildNavRow(BuildContext context, List<T> items) {
    final current = items[_index.clamp(0, items.length - 1)];
    return Padding(
      // Extra bottom clearance: LiveResumeHint (the "Hold -> to resume"
      // pill for a live channel paused in the background) is a global
      // overlay fixed at 24px from the very bottom of the screen,
      // regardless of which tab is showing — this row would otherwise
      // sit directly under it.
      padding: const EdgeInsets.only(top: 12, bottom: 64),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 130,
            child: ModeButton(
              icon: Icons.chevron_left,
              label: 'Previous',
              selected: false,
              onTap: () => _step(-1),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 160,
            child: ModeButton(
              icon: Icons.play_arrow,
              label: 'Play',
              selected: false,
              focusNode: widget.playFocusNode,
              onTap: () => widget.onOpen(current),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 130,
            child: ModeButton(
              icon: Icons.chevron_right,
              label: 'Next',
              selected: false,
              onTap: () => _step(1),
            ),
          ),
        ],
      ),
    );
  }
}

/// Just the app name/clock — Search, Update Content, and Settings live in
/// the tabs rail now (below Favorites), not as top-right icon buttons.
/// Those buttons were effectively unreachable by remote: nothing in the
/// main content area ever handed D-pad focus up to them, so they needed a
/// mouse/touch to use at all. The tabs rail is already a single reliably
/// D-pad-navigable list, so putting them there instead — with Search
/// pinned at the very top of it, "at the top and accessible from
/// everywhere" the way a search entry point should be — costs nothing and
/// actually works with a remote.
class _TvTopBar extends StatelessWidget {
  const _TvTopBar({required this.showClock, required this.isLoading});

  final bool showClock;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    // Deliberately the palette's own colors, not `Theme.of(context)
    // .colorScheme` — for the Minimalist palette specifically, that
    // scheme's primary/secondary are a neutral white/light-gray (see
    // `withTvThemeIfNeeded`), which would otherwise turn the wordmark
    // plain white too. Every other palette's `primary`/`secondary` are
    // already identical to what the scheme derives from them, so this
    // changes nothing for them.
    final palette = context.watch<AppPreferences>().palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) =>
                LinearGradient(colors: [palette.primary, palette.secondary])
                    .createShader(bounds),
            child: const Text(
              AppConstants.appName,
              // Was bumped to 64 thinking this was the launcher banner text
              // — it wasn't, that's a separate Android TV banner asset.
              // Back to the original in-app header size.
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold),
            ),
          ),
          if (showClock) ...[
            const SizedBox(width: 16),
            _TvClockText(
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Colors.white70)),
          ],
          const Spacer(),
          if (isLoading) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white70),
            ),
            const SizedBox(width: 8),
            const Text('Updating…',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _TvClockText extends StatefulWidget {
  const _TvClockText({this.style});
  final TextStyle? style;

  @override
  State<_TvClockText> createState() => _TvClockTextState();
}

class _TvClockTextState extends State<_TvClockText> {
  @override
  void initState() {
    super.initState();
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 30));
      if (!mounted) return false;
      setState(() {});
      return true;
    });
  }

  @override
  Widget build(BuildContext context) =>
      Text(DateFormat('HH:mm').format(DateTime.now()), style: widget.style);
}

class _CurrentProgramLine extends StatelessWidget {
  const _CurrentProgramLine({required this.channelId});
  final String channelId;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final current = epg.getCurrentProgram(channelId);
    if (current == null)
      return const Text('No program data', style: TextStyle(fontSize: 12));
    return Text(current.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12));
  }
}

/// Right-panel program info card — current show, time range with a
/// progress bar, description, and the next show.
class _ProgramDetails extends StatelessWidget {
  const _ProgramDetails({required this.channel, required this.epg});

  final Channel channel;
  final EpgService epg;

  @override
  Widget build(BuildContext context) {
    // rawId, not the composite `id` — see
    // PlaylistManager.knownChannelIdsFor's doc comment.
    final current = epg.getCurrentProgram(channel.rawId);
    final next = epg.getNextProgram(channel.rawId);
    final timeFormat = DateFormat('HH:mm');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(channel.name,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          if (current != null) ...[
            Text(current.title,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 4),
            Builder(builder: (context) {
              final now = DateTime.now();
              final totalMs =
                  current.stop.difference(current.start).inMilliseconds;
              final elapsedMs = now.difference(current.start).inMilliseconds;
              final ratio =
                  totalMs == 0 ? 0.0 : (elapsedMs / totalMs).clamp(0.0, 1.0);
              return Row(
                children: [
                  Text(
                      '${timeFormat.format(current.start)} - ${timeFormat.format(current.stop)}',
                      style: const TextStyle(color: Colors.white70)),
                  const SizedBox(width: 12),
                  Expanded(child: LinearProgressIndicator(value: ratio)),
                ],
              );
            }),
            if (current.description != null) ...[
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(current.description!,
                      style: const TextStyle(color: Colors.white70)),
                ),
              ),
            ],
          ] else
            const Text('No program data available',
                style: TextStyle(color: Colors.white70)),
          if (next != null) ...[
            const SizedBox(height: 8),
            Text('Next: ${next.title} (${timeFormat.format(next.start)})',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}
