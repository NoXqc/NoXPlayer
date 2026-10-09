import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/m3u_group.dart';
import '../models/xtream_series.dart';
import '../services/app_preferences.dart';
import '../services/desktop_mini_player.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../services/viewer_profile_service.dart';
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
import 'group_catalog_screen.dart';
import 'desktop_multiview_screen.dart';
import 'desktop_player_screen.dart';
import 'multiview_screen.dart';
import 'movie_detail_screen.dart';
import 'player_screen.dart';
import 'profile_picker_screen.dart';
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
  bool _retrying = false;

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

  /// A true landscape TMDB backdrop for whatever's currently focused, when
  /// one's already been enriched — see `_BrowseHero`'s doc comment for why
  /// this is kept separate from [_focusedImageUrl] (a portrait poster/logo)
  /// rather than folded into one fallback chain.
  String? _focusedBackdropUrl;

  /// The stable id of whatever's currently focused in the Movies/TV Shows
  /// browse grid — `_updateBrowseFocus`'s de-dupe key (title alone isn't
  /// unique enough across playlists) and the dwell timer's "is this
  /// still the same thing" guard once it fires.
  String? _focusedId;
  String? _focusedDescription;
  Timer? _descriptionDwellTimer;
  static const _kDescriptionDwell = Duration(milliseconds: 400);

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

  /// The groups column's own top row — whichever of Favourites/"All"/
  /// "What's New" renders first for the currently active tab (only one of
  /// those three ever mounts at once, so one shared node is safe).
  /// Requested directly instead of trusting `_col1Scope.requestFocus()`'s
  /// own "fall back to the first focusable descendant" behavior (see
  /// [_moveColumnFocus]) — reported directly as unreliable for this
  /// column specifically: the first Right press from the tabs rail left
  /// no visible D-pad cursor anywhere in the groups list at all, and
  /// Up/Down afterward behaved as though focus had actually landed
  /// somewhere mid-list rather than at the top (Up moved further down,
  /// Down jumped to the top) — consistent with focus having landed on the
  /// scope node itself rather than any real row.
  final FocusNode _firstGroupRowFocusNode =
      FocusNode(debugLabel: 'first-group-row');

  /// True once a Left press at the leftmost poster in the browse grid has
  /// found nowhere further left to go, but hasn't yet been confirmed by a
  /// second such press — see [_handleBrowseLeft]. Requiring two in a row
  /// stops one slightly-too-eager Left press from accidentally bouncing
  /// all the way out of the catalog and back to the tabs rail.
  bool _leftEdgeArmed = false;
  Timer? _leftEdgeArmTimer;

  /// Whichever programme block last took focus in the Timeline Guide —
  /// lifted up here (not kept inside [_TimelineGuide]) because the header
  /// that describes it, [_GuideNowPanel], sits above the guide as a
  /// sibling, not inside it. Null until the guide is first navigated,
  /// which is when [_GuideNowPanel] falls back to the playing channel's
  /// own live programme instead.
  Channel? _guideFocusedChannel;
  EpgProgram? _guideFocusedProgram;

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

  /// Row identities in on-screen order for whichever browse tab last
  /// built (see [_buildMoviesBrowse]/[_buildShowsBrowse]) — null for the
  /// Continue Watching row when present, `(playlistId, title)` for each
  /// category row after it. Rebuilt on every call (cheap: a list of
  /// tuples), consumed by [_moveBrowseRowFocus] so Up/Down between rows is
  /// an explicit jump to the target row's known first-poster node instead
  /// of relying on Flutter's default directional search across every
  /// poster in every currently-built row. That default search is exactly
  /// what [_handleBrowseLeft] and the groups-column quick-jump
  /// deliberately avoid for the same reason — reported directly as the
  /// whole browse view becoming unresponsive to Up/Down (Back still
  /// worked) once a provider's real catalog — hundreds of categories,
  /// each its own row — replaced far smaller test data.
  List<({String playlistId, String title})?> _browseRowKeys = [];

  /// Index into [_browseRowKeys] for whichever row currently has D-pad
  /// focus — kept up to date by every poster's `onFocusGained` in
  /// [_buildMoviesBrowse]/[_buildShowsBrowse], not just each row's first
  /// card, so Up/Down still resolves correctly after moving right within
  /// a row.
  int? _focusedBrowseRowIndex;

  /// Whether Movies/TV Shows is currently showing the "What's New"
  /// carousel instead of the normal poster catalog. Opt-in, not the
  /// default — always false on entering either tab (see [_onTabChanged]),
  /// set true only by tapping the pinned "What's New" row in the groups
  /// column, and cleared again by picking "All" or a real category.
  bool _showWhatsNew = false;

  /// The carousel's Play button, owned here (like
  /// [_groupFirstPosterFocusNodes]/[_continueWatchingFirstFocusNode]) so
  /// [_enterBrowseColumn] can hand D-pad focus straight to it. Deliberately
  /// not `autofocus` inside the carousel itself: that fires as soon as the
  /// widget is built — i.e. the instant the tab is switched, while focus is
  /// still meant to be on the tabs rail — and would drag the cursor into
  /// the content column unasked.
  ///
  /// One node per content type, not shared — Movies' and TV Shows'
  /// carousels are two separate `_WhatsNewCarousel` widget instances (only
  /// one ever actually mounted at a time, but still two distinct Elements
  /// over the app's lifetime), and a single `FocusNode` is only ever meant
  /// to be attached to one `Focus`/`InkWell` Element at a time. Release
  /// builds strip the assertion that would catch a bad attach/detach
  /// ordering here, so this was a real, silent crash risk, not just a
  /// style nit.
  final FocusNode _moviesWhatsNewPlayFocusNode =
      FocusNode(debugLabel: 'whats-new-play-movies');
  final FocusNode _showsWhatsNewPlayFocusNode =
      FocusNode(debugLabel: 'whats-new-play-shows');

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
  /// [category] is 'vod'/'series' for a Movies/TV Shows group (enables the
  /// "Expand catalog" option — see [GroupCatalogScreen]'s doc comment) or
  /// null for a Live TV group, which has no poster-grid concept to expand
  /// into.
  Future<void> _showGroupOptions(String playlistId, String title,
      {String? category}) async {
    final playlist = context.read<PlaylistManager>();
    final isFavorited = playlist.isGroupFavorited(playlistId, title);
    final isPending = _pendingHideGroups.contains(_groupKey(playlistId, title));

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [
          if (category != null)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('expand'),
              child: const Text('Expand catalog'),
            ),
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
    if (!mounted) return;

    switch (choice) {
      case 'expand':
        // Flutter's default "restore previous focus on pop" doesn't land
        // back correctly here — reported directly: back from the catalog
        // landed on the tabs column instead of staying on groups. Likely
        // the SimpleDialog-then-push combination (unlike _openMovie/
        // _openSeries, pushed directly from a tap with no dialog in
        // between) confuses it. Explicit beats default, same as every
        // other focus problem already fixed in this app: re-enter the
        // groups column on return rather than trusting restoration.
        Navigator.of(context)
            .push(MaterialPageRoute(
                builder: (_) => GroupCatalogScreen(
                    category: category!, playlistId: playlistId, title: title)))
            .then((_) {
          if (!mounted) return;
          setState(() => _focusDepth = 1);
          _col1Scope.requestFocus();
        });
      case 'favorite':
        playlist.setGroupFavorited(playlistId, title, !isFavorited);
      case 'hide':
        _startPendingHide(playlistId, title);
      case 'cancel_hide':
        _cancelPendingHide(playlistId, title);
    }
  }

  /// Timeline Guide equivalent of [_showGroupOptions] — reported directly:
  /// holding Select on a programme block doesn't do anything, because
  /// (unlike the plain live list, where the focused row *is* the channel)
  /// the focused thing here is a specific time slot, not the channel
  /// itself, so there was nothing for a bare hold-to-favorite gesture to
  /// act on. A menu instead of a single hold action for a second reason
  /// the user raised directly: a single hold gesture on a channel could
  /// mean either "favourite" or "hide" here, unlike the plain list where
  /// hold has only ever meant one thing.
  Future<void> _showChannelOptions(Channel channel) async {
    final playlist = context.read<PlaylistManager>();
    final isFavorited = channel.isFavorite;
    final isHidden = playlist.isChannelHidden(channel);

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('favorite'),
            child: Text(
                isFavorited ? 'Remove from Favourites' : 'Add to Favourites'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('hide'),
            child: Text(isHidden ? 'Unhide this channel' : 'Hide this channel'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    switch (choice) {
      case 'favorite':
        _toggleFavoriteWithFeedback(context, channel);
      case 'hide':
        // Un-hiding (not hiding) is exactly the direct, non-Settings
        // bypass this gate exists for — a restricted viewer could
        // otherwise un-hide a channel from this long-press menu without
        // ever touching Settings or the PIN pad at all. Hiding a channel
        // only makes things stricter, so it stays ungated either way.
        if (isHidden) {
          final unlocked =
              await context.read<ViewerProfileService>().requireUnlock(context);
          if (!unlocked || !mounted) return;
        }
        _toggleHiddenWithFeedback(context, channel);
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

  /// The plain live list's first row, when it isn't also the currently-
  /// playing channel (which already owns [_currentChannelFocusNode]) —
  /// see [_onGroupSelected]'s own doc comment for why this exists:
  /// without an explicit target, switching groups left the list's scroll
  /// offset and D-pad focus memory wherever they'd physically been in the
  /// *previous* group's list instead of resetting to the new one's first
  /// channel.
  final FocusNode _firstLiveChannelFocusNode =
      FocusNode(debugLabel: 'first-live-channel-row');

  /// Imperative access to the Timeline Guide's own State — lets
  /// [didPopNext] and the Up/Down key bindings below call
  /// [_TimelineGuideState.restoreFocusToChannel]/`.moveVertical` directly.
  /// A GlobalKey (not a plain field reference) because [_buildLiveRegion]
  /// creates a fresh [_TimelineGuide] widget on every rebuild — the key
  /// is what keeps Flutter reusing the same underlying State instead of
  /// a new one each time. Not `final`: swapped out for a brand new
  /// `GlobalKey` (in a `setState`) when that State's own
  /// `onWindowStale` fires — the one deliberate exception to "keeps
  /// reusing the same State", forcing exactly the fresh remount that
  /// call is asking for. See `_TimelineGuideState._windowStart`'s doc
  /// comment for why that's ever needed at all.
  GlobalKey<_TimelineGuideState> _timelineGuideKey = GlobalKey();

  /// The Timeline guide's own filter toggle button
  /// (`_TimelineFilterButton`, rendered above its channel column).
  /// Deliberately a *separate* node from `_timelineFilterFieldFocusNode`
  /// below — sharing one node across the button/`TextField` swap was tried
  /// first and confirmed broken on real hardware (the Formuler's on-screen
  /// keyboard never opened, through two different workarounds) because a
  /// `TextField` only reliably opens a real platform text-input connection
  /// off a genuine focus-*gain* event, and a node that's already focused
  /// before the `TextField` even mounts never produces one. Two separate
  /// nodes plus a fresh `autofocus: true` on the field itself (same
  /// pattern `SearchScreen`'s own `TextField` already uses successfully on
  /// this exact device) sidesteps the whole problem instead of fighting it.
  final FocusNode _timelineFilterButtonFocusNode =
      FocusNode(debugLabel: 'timeline-filter-button');
  final FocusNode _timelineFilterFieldFocusNode =
      FocusNode(debugLabel: 'timeline-filter-field');
  final TextEditingController _timelineFilterController =
      TextEditingController();

  /// Whether the Timeline guide's per-group channel filter bar is showing
  /// in place of the live preview box — see `_buildTimelineFilterBar`.
  bool _timelineFilterActive = false;

  /// Current filter text — applied only to the Timeline guide's own
  /// channel list (`_filteredLiveChannelsForGuide`), never the plain
  /// "Live" list view.
  String _timelineFilterQuery = '';

  /// Backs [_TimelineVirtualKeyboard] on real TV/remote-control devices —
  /// see `_buildTimelineFilterBar`'s own doc comment for why this exists
  /// instead of just the `TextField` above. `hasFocus` is true if *any*
  /// key in the grid currently has it, which is what the `arrowDown`/
  /// `onReachedTop` focus-coordination below actually needs (unlike a
  /// single `FocusNode`, which only reports true for one specific key).
  final FocusScopeNode _timelineKeyboardScope =
      FocusScopeNode(debugLabel: 'timeline-keyboard');

  /// One [FocusNode] per key, index-matched to `_TimelineVirtualKeyboard
  /// ._keyRows` so row/column arithmetic in its own `_moveFocus` and the
  /// "focus the first key" calls below line up by index — same shape as
  /// `pin_pad.dart`'s `_nodes`/`_keyValues`. Built once here (not inside
  /// the keyboard widget itself) so requesting focus on the first key
  /// from outside (opening the filter, or Up from the guide's top row)
  /// doesn't need a `GlobalKey`/`State` reference into the keyboard.
  late final List<List<FocusNode>> _timelineKeyboardNodes = List.generate(
      _TimelineVirtualKeyboard.keyRows.length,
      (r) => List.generate(_TimelineVirtualKeyboard.keyRows[r].length,
          (_) => FocusNode(debugLabel: 'timeline-keyboard-key')));

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
    _descriptionDwellTimer?.cancel();
    setState(() {
      _tab = tab;
      _selectedGroup = null;
      _focusedTitle = null;
      _focusedImageUrl = null;
      _focusedBackdropUrl = null;
      _focusedId = null;
      _focusedDescription = null;
      _focusDepth = 0;
      // Opt-in only, not the default view — groups + Continue Watching
      // come up first on entering either tab, same as before this
      // feature existed. The pinned "What's New" row in the groups
      // column (see _buildBrowseGroupsColumn) is still there for anyone
      // who wants to switch into the carousel deliberately.
      _showWhatsNew = false;
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
    setState(() {
      _selectedGroup = group;
      // Otherwise the Timeline Guide's header keeps describing a program
      // from whichever group was focused before this switch, until the
      // D-pad happens to land on something in the new one.
      _guideFocusedChannel = null;
      _guideFocusedProgram = null;
    });
    if (group == null) return;
    if (group == _favoritesGroupSentinel) {
      // Only reachable from the Live TV tab's own pinned "Favourites" row
      // (see _buildGroupsColumn) — same explicit reset every real live
      // group already gets below, see _resetLiveListFocus's own doc
      // comment. This case used to return immediately above without it,
      // which — combined with the content list having no key to force a
      // genuine remount across groups (see _buildLiveList's own ListView
      // .builder) — meant Flutter could silently reuse the previous
      // group's still-focused row Element for this list's row 0 instead
      // of creating a fresh one. If a Select press's key-*up* for
      // whatever row picked "Favourites" arrived after that reuse already
      // happened, it could land on the reused row's own now-stale
      // `HoldToActivate` state instead, auto-"pressing" it — reported
      // directly as the first favourite channel launching into fullscreen
      // on its own, with nothing actually tapped.
      _resetLiveListFocus();
      return;
    }
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
      } else {
        _resetLiveListFocus();
      }
      return;
    }
    if (_tab == 'TV') {
      _resetLiveListFocus();
      return;
    }
    context
        .read<PlaylistManager>()
        .ensureCategoryLoaded(playlistId!, group, _categoryForTab(_tab));
  }

  /// Explicit reset instead of leaving the plain live list's scroll
  /// offset/D-pad focus wherever they physically were in the *previous*
  /// group — reported directly: picking a new group left the list
  /// scrolled to roughly how far down the old one had been browsed,
  /// landing on an unrelated channel instead of the new group's first
  /// one. Same "explicit beats whatever's left over" fix as
  /// [_scrollToBrowseGroup] uses for Movies/TV Shows, and
  /// `_TimelineGuideState.didUpdateWidget`'s matching fix for the other
  /// live guide layout.
  void _resetLiveListFocus() {
    if (_liveListController.hasClients) _liveListController.jumpTo(0);
    final playlist = context.read<PlaylistManager>();
    final channels = _currentLiveChannels(playlist);
    if (channels.isEmpty) return;
    final playback = context.read<PlaybackService>();
    final firstIsPlaying = playback.currentChannel?.id == channels.first.id;
    (firstIsPlaying ? _currentChannelFocusNode : _firstLiveChannelFocusNode)
        .requestFocus();
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

    // Looked up in the actually-rendered row list (_browseRowKeys), not
    // re-derived here from a separately filtered/mapped title list plus a
    // manual Continue Watching offset — the two could drift apart
    // (reported directly: picking a group landed the scroll at the very
    // bottom of the whole catalog, not on the group actually tapped).
    // Matching on (playlistId, title) together, not title alone, also
    // can't be fooled by two different playlists sharing a category name.
    final index = _browseRowKeys.indexWhere(
        (k) => k != null && k.playlistId == playlistId && k.title == title);
    if (index < 0) return;

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
    // _categoryRowHeight is an exact value now, not a guess (every row is
    // pinned to it — see that getter's own doc comment for the drift bug
    // this replaced), so the jumpTo above should already land precisely.
    // This is just a cheap belt-and-suspenders correction against the
    // row's own real on-screen position, same as `_restoreLiveFocus` does
    // for the live channel list — effectively a no-op once it's already
    // exactly right, but costs nothing to keep.
    _ensureRowVisible(_keyForGroup(playlistId, title));
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
    // [_moviesWhatsNewPlayFocusNode]/[_showsWhatsNewPlayFocusNode]).
    // Falls back to the column's own scope if the carousel is still
    // loading/empty and has no Play button mounted.
    if (_showWhatsNew) {
      final playNode = _tab == 'Movies'
          ? _moviesWhatsNewPlayFocusNode
          : _showsWhatsNewPlayFocusNode;
      if (playNode.context != null) {
        playNode.requestFocus();
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

  /// Title/backdrop image commit immediately on every focus change, same
  /// as before — [fetchDescription] is the only part that waits, and
  /// only when [id] isn't already cached from an earlier fetch this
  /// session (either from here or from opening the detail screen
  /// directly — see `PlaylistManager`'s description cache). Debounced
  /// (not fetched on every single focus change) so scrolling quickly
  /// through a row of posters doesn't fire a network request per poster
  /// passed over — same cancel-and-restart `Timer` idiom already used in
  /// `search_screen.dart` for exactly this "wait for things to settle"
  /// reason.
  void _updateBrowseFocus({
    required PlaylistManager playlist,
    required String id,
    required String title,
    String? imageUrl,
    String? backdropUrl,
    required Future<String?> Function() fetchDescription,
  }) {
    if (_focusedId == id) return;
    _descriptionDwellTimer?.cancel();
    final cached = playlist.hasCachedDescription(id);
    setState(() {
      _focusedId = id;
      _focusedTitle = title;
      _focusedImageUrl = imageUrl;
      _focusedBackdropUrl = backdropUrl;
      _focusedDescription = cached ? playlist.peekCachedDescription(id) : null;
    });
    if (cached) return;
    _descriptionDwellTimer = Timer(_kDescriptionDwell, () async {
      String? description;
      try {
        description = await fetchDescription();
      } catch (_) {
        // Leave it blank rather than cache a transient failure — a retry
        // is still possible next time this title is focused.
        return;
      }
      if (!mounted || _focusedId != id) return;
      playlist.cacheDescription(id, description);
      setState(() => _focusedDescription = description);
    });
  }

  void _onColumnFocus(int depth) {
    if (_focusDepth != depth) setState(() => _focusDepth = depth);
  }

  /// Records which browse row currently has focus — see
  /// [_browseRowKeys]'s doc comment. Deliberately not wrapped in
  /// `setState`: nothing on screen depends on this value directly, it's
  /// only read later by [_moveBrowseRowFocus].
  void _setFocusedBrowseRow(int index) => _focusedBrowseRowIndex = index;

  /// Explicit Up/Down between browse rows — see [_browseRowKeys]'s doc
  /// comment for why this exists instead of leaving it to default
  /// traversal. Always lands on the target row's first poster, same
  /// convention already established by the groups-column quick-jump
  /// ([_scrollToBrowseGroup]/[_enterBrowseColumn]) rather than trying to
  /// preserve column position — scrolling the target into view is handled
  /// by the existing `onFocusGained` → `_ensureRowVisible` path once that
  /// node actually takes focus, same as it already does for every other
  /// way of landing on a row.
  void _moveBrowseRowFocus(int delta) {
    final current = _focusedBrowseRowIndex ?? 0;
    final target = current + delta;
    if (target < 0 || target >= _browseRowKeys.length) return;
    final key = _browseRowKeys[target];
    if (key == null) {
      _continueWatchingFirstFocusNode.requestFocus();
    } else {
      _firstPosterFocusNodeForGroup(key.playlistId, key.title).requestFocus();
    }
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
    if (target == 2 &&
        (_timelineGuideKey.currentState?.focusEntry() ?? false)) {
      return;
    }
    // See _firstGroupRowFocusNode's own doc comment — only when nothing's
    // already focused in the groups column (so returning to a previously-
    // browsed group still restores where you left off, same as before).
    if (target == 1 && _col1Scope.focusedChild == null) {
      _firstGroupRowFocusNode.requestFocus();
      return;
    }
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
    _descriptionDwellTimer?.cancel();
    _leftEdgeHintOverlay?.remove();
    _browseScrollController.dispose();
    _liveListController.dispose();
    _currentChannelFocusNode.dispose();
    _firstLiveChannelFocusNode.dispose();
    _col0Scope.dispose();
    _col1Scope.dispose();
    _col2Scope.dispose();
    for (final node in _groupFirstPosterFocusNodes.values) {
      node.dispose();
    }
    _firstGroupRowFocusNode.dispose();
    _timelineFilterButtonFocusNode.dispose();
    _timelineFilterFieldFocusNode.dispose();
    _timelineFilterController.dispose();
    _timelineKeyboardScope.dispose();
    for (final row in _timelineKeyboardNodes) {
      for (final node in row) {
        node.dispose();
      }
    }
    _continueWatchingFirstFocusNode.dispose();
    _moviesWhatsNewPlayFocusNode.dispose();
    _showsWhatsNewPlayFocusNode.dispose();
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
      // The Timeline Guide has no equivalent of the plain list's
      // dedicated _currentChannelFocusNode — _restoreLiveFocus only ever
      // does anything for that plain list's own rows, so it silently
      // no-ops in Timeline mode and leaves Flutter's own implicit
      // pop-focus-restoration to fend for itself, landing back wherever
      // the D-pad happened to be *before* Select was pressed instead of
      // the channel actually playing. Reported directly: "hitting left
      // to go back to guide... doesn't bring us back to the current
      // channel but where we last were before."
      if (context.read<AppPreferences>().guideViewMode == 'timeline') {
        final channel = context.read<PlaybackService>().currentChannel;
        if (channel != null) {
          _timelineGuideKey.currentState?.restoreFocusToChannel(channel.id);
        } else {
          _col0Scope.requestFocus();
        }
      } else {
        _restoreLiveFocus();
      }
      return;
    }
    // Popping fullscreen *or* a movie/series detail screen while sitting
    // on a Movies/TV Shows tab used to leave focus restoration entirely
    // to Flutter's own implicit handling after the pop — fine on a small
    // catalog, but confirmed on real hardware to cause the exact same
    // class of ANR as the fullscreen right-arrow bug (an expensive
    // default focus search, this time triggered by the pop itself rather
    // than a keypress) once the Movies/TV Shows catalog is large. Always
    // landing on the tabs rail instead (a cheap, deliberate target
    // regardless of catalog size) fixed the ANR, but reported directly as
    // its own regression: backing out of a title always jumped all the
    // way back to the tabs rail instead of back to the catalog row it was
    // opened from. [_lastOpenedBrowseGroup] gives this an equally cheap,
    // deliberate target for that specific row instead — the same
    // explicit `_scrollToBrowseGroup` jump the groups rail itself already
    // uses, never Flutter's own default search — so this keeps the ANR
    // fix while actually landing back where the user was.
    final openedFrom = _lastOpenedBrowseGroup;
    _lastOpenedBrowseGroup = null;
    if (openedFrom != null) {
      _scrollToBrowseGroup(openedFrom.playlistId, openedFrom.title);
    } else {
      _col0Scope.requestFocus();
    }
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

  /// [_currentLiveChannels], narrowed by [_timelineFilterQuery] — applied
  /// only at the Timeline guide's own `channels:` argument, never inside
  /// [_currentLiveChannels] itself, so the plain "Live" list view (which
  /// also calls that method) is unaffected. Same case-insensitive
  /// substring match `SearchScreen` uses for its own channel results.
  List<Channel> _filteredLiveChannelsForGuide(PlaylistManager playlist) {
    final channels = _currentLiveChannels(playlist);
    final q = _timelineFilterQuery.trim().toLowerCase();
    if (q.isEmpty) return channels;
    return channels.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  void _openTimelineFilter() {
    // Non-TV (phone/Windows): no manual focus/keyboard plumbing needed —
    // _buildTimelineFilterBar's TextField carries its own autofocus: true
    // on _timelineFilterFieldFocusNode, a fresh node never focused before
    // this exact moment. That's the same pattern SearchScreen's own
    // TextField already relies on to open the keyboard reliably there —
    // see _timelineFilterButtonFocusNode's doc comment for why an earlier
    // shared-node approach (manual requestFocus/unfocus/refocus/
    // TextInput.show, none of it worked) was abandoned in favor of this.
    //
    // Real TV/remote devices get _TimelineVirtualKeyboard instead (see
    // _buildTimelineFilterBar) — no system keyboard involved at all, so
    // this explicitly focuses its first key once the grid has mounted.
    setState(() => _timelineFilterActive = true);
    if (context.read<AppPreferences>().isTelevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _timelineKeyboardNodes.first.first.requestFocus();
      });
    }
  }

  /// [toGuide]: Back pressed while focus is actually in the keyboard
  /// closes the filter *UI* and drops focus straight into the guide
  /// below, rather than back onto the toggle button — requested directly,
  /// since landing back on the button after deliberately backing out of
  /// typing reads as a dead end rather than "take me to what I was just
  /// looking at." [clearQuery] (default true) also resets the query in
  /// that case — Back here means "quit filtering," not "keep the filter
  /// applied but hide the keyboard."
  void _closeTimelineFilter({bool toGuide = false, bool clearQuery = true}) {
    if (clearQuery) _timelineFilterController.clear();
    setState(() {
      _timelineFilterActive = false;
      if (clearQuery) _timelineFilterQuery = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (toGuide) {
        _timelineGuideKey.currentState?.focusEntry();
      } else {
        _timelineFilterButtonFocusNode.requestFocus();
      }
    });
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
    // pendingResumeChannel too, not just currentChannel — on a true cold
    // launch nothing has actually started playing yet (the "Nothing
    // playing" / "Hold > to resume" pill state, see LiveResumeHint's own
    // _resumableChannel getter, same fallback), so currentChannel alone
    // was still null at exactly the moment this screen's first build asks
    // the question, and fell straight through to `groups.first.title`
    // regardless of the fix below — confirmed directly: still opened the
    // first real group, not Favourites, even after that fix landed.
    final playing = playback.currentChannel ?? playback.pendingResumeChannel;
    if (playing != null) {
      // A favorited channel lands on the pinned "Favourites" entry, not
      // its own real provider group — same priority already established
      // for returning from fullscreen (see didPopNext's stayOnFavorites),
      // just missing from this fallback. Reported directly: a cold launch
      // that auto-resumes a favorited channel opened its real group
      // instead of Favourites. Checked before the real-group match below,
      // which would otherwise always win — every channel, favorited or
      // not, has a real group to match against.
      if (playlist.favoriteLiveChannels.any((c) => c.id == playing.id)) {
        return _favoritesGroupSentinel;
      }
      if (groups.any((g) => g.title == playing.group)) {
        return playing.group;
      }
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
    // Windows has no PlaybackService-compatible player at all (see
    // DesktopPlayerScreen's own doc comment) — a completely separate,
    // standalone screen/player instance, bypassing PlaybackService (and
    // therefore Continue Watching/resume/backup-server retry) entirely
    // rather than routing through the shared mobile player architecture.
    if (Platform.isWindows) {
      // Abandon whatever's minimized first — reported directly as two
      // channels' audio playing at once otherwise: picking a channel
      // here is an unrelated, fresh selection, not a resume, so any
      // previously-minimized session has to be torn down rather than
      // left running forever with nothing pointed at it anymore. See
      // DesktopMiniPlayer.clear's own doc comment.
      DesktopMiniPlayer.instance.clear();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DesktopPlayerScreen(channel: channel)));
      return;
    }
    final playback = context.read<PlaybackService>();
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
  /// Timeline guide's Left: step one 30-minute slot back in time, and
  /// only once the guide's time window has no earlier slot left fall back
  /// to the usual "press again to leave for the groups" edge behaviour.
  void _handleTimelineLeft() {
    final moved = _timelineGuideKey.currentState?.moveHorizontal(-1) ?? false;
    if (!moved) _handleBrowseLeft();
  }

  void _goFullscreenIfPlaying() {
    final channel = context.read<PlaybackService>().currentChannel;
    if (channel == null) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
  }

  /// The catalog row a movie/series was just opened from — see
  /// [didPopNext]'s own doc comment for why. Set right before the push,
  /// consumed (and cleared) by the very next [didPopNext]; a `null` here
  /// (Continue Watching, or anywhere else with no real category row to go
  /// back to) just keeps the old "land on the tabs rail" fallback.
  ({String playlistId, String title})? _lastOpenedBrowseGroup;

  void _openMovie(Channel channel,
      {String? groupPlaylistId, String? groupTitle}) {
    _lastOpenedBrowseGroup = (groupPlaylistId != null && groupTitle != null)
        ? (playlistId: groupPlaylistId, title: groupTitle)
        : null;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MovieDetailScreen(channel: channel)));
  }

  void _openSeries(XtreamSeries series,
      {String? groupPlaylistId, String? groupTitle}) {
    _lastOpenedBrowseGroup = (groupPlaylistId != null && groupTitle != null)
        ? (playlistId: groupPlaylistId, title: groupTitle)
        : null;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  /// The single choke point every path into Settings on this layout goes
  /// through — see `ViewerProfileService.requireUnlock`'s doc comment for
  /// why Settings is gated as one whole, not screen-by-screen inside it.
  Future<void> _openSettings() async {
    final unlocked =
        await context.read<ViewerProfileService>().requireUnlock(context);
    if (!unlocked || !mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsMenuScreen()));
  }

  void _openProfilePicker() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ProfilePickerScreen()));
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
    // A restricted viewer gets a plain close, no confirmation and no
    // playlist-disabling — the "free up this login" framing below doesn't
    // apply to them, and disabling every playlist here would combine badly
    // with Settings being PIN-gated: the next person to open the app would
    // find every playlist disabled with no ungated way back in. Only the
    // *active* viewer's restricted status matters here, not whether any
    // restricted profile exists at all — Main (or any other unrestricted
    // profile) exiting the app behaves exactly as it always has.
    if (context.read<ViewerProfileService>().isActiveRestricted) {
      _closeApp();
      return;
    }
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
    _closeApp();
  }

  /// `SystemNavigator.pop()` is a mobile-oriented API — on Android it maps
  /// directly to finishing the Activity, but Flutter's Windows desktop
  /// embedder doesn't reliably implement it as "close the window" at all.
  /// Confirmed directly: the sidebar's new plain "Close" row did nothing
  /// with it, right after `windowManager.minimize()` (a real, properly
  /// supported native call from the same plugin) was confirmed working —
  /// `windowManager.close()` is the equivalent reliable call for actually
  /// closing the window. Used here too (not just the dedicated Close row)
  /// so `_hardExit`'s own final step — and the restricted-viewer plain-
  /// close path above — both close the window for real on Windows,
  /// instead of silently leaving it open after disabling every playlist.
  void _closeApp() {
    if (Platform.isWindows) {
      windowManager.close();
    } else {
      SystemNavigator.pop();
    }
  }

  /// A window can't be minimized while it's *in* `fullScreen` mode at all
  /// — confirmed directly: a bare `windowManager.minimize()` call did
  /// nothing. Exiting fullscreen first is what actually makes the
  /// minimize take effect; `main.dart`'s own `onWindowRestore` listener
  /// is what re-enters fullscreen once the window comes back (clicking
  /// the taskbar icon), not anything tied to this specific screen.
  Future<void> _minimizeWindow() async {
    await windowManager.setFullScreen(false);
    await windowManager.minimize();
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
    // not just the Settings menu itself. Goes through the same shared
    // buildPaletteColorScheme every other palette-aware screen uses (see
    // its own doc comment) rather than reimplementing the seeding/override
    // here a second time — this screen (top bar, sidebar, live list) is
    // exactly the surface a second copy would silently diverge from.
    final darkScheme = buildPaletteColorScheme(prefs.palette, Brightness.dark);

    final isBrowseTab = _tab == 'Movies' || _tab == 'TV Shows';
    // Only meaningful on the Live TV/Favorites side (the browse tabs have
    // their own poster grid and no concept of this setting) — see
    // _buildLiveRegion for where it actually swaps the content, and the
    // Left/Right binding override just below for why the depth-2 column's
    // own key handling needs to know about it too.
    final showTimelineGuide = !isBrowseTab && prefs.guideViewMode == 'timeline';

    return Theme(
      data: ThemeData(colorScheme: darkScheme, useMaterial3: true),
      // Back walks out one column at a time — content -> groups -> tabs —
      // and only exits the app from the tabs column (it used to exit
      // straight from anywhere, including deep inside the guide).
      child: PopScope(
        canPop: _focusDepth == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // Back while focus is literally inside the Timeline keyboard
          // closes it and drops into the guide instead of the normal
          // column-by-column walk below — requested directly. Clears the
          // query too (not just the keyboard UI) — Back here means
          // "quit filtering," not "keep it applied but hide the keyboard."
          if (_timelineKeyboardScope.hasFocus) {
            _closeTimelineFilter(toGuide: true);
            return;
          }
          _moveColumnFocus(-1, 2);
        },
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
                      child: (playlist.error != null &&
                              playlist.channels.isEmpty)
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (playlist.error != null)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 16),
                                        child: Text(playlist.error!,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error)),
                                      ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        OutlinedButton(
                                          onPressed: _retrying
                                              ? null
                                              : () async {
                                                  setState(
                                                      () => _retrying = true);
                                                  await playlist
                                                      .retryFailedConnections();
                                                  if (mounted) {
                                                    setState(() =>
                                                        _retrying = false);
                                                  }
                                                },
                                          child: _retrying
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2))
                                              : const Text('Retry'),
                                        ),
                                        const SizedBox(width: 12),
                                        FilledButton(
                                            onPressed: _openSettings,
                                            child: const Text('Open Settings')),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
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
                                              LogicalKeyboardKey
                                                  .arrowRight): () =>
                                              _moveColumnFocus(1, 2),
                                        },
                                      1 => <ShortcutActivator, VoidCallback>{
                                          const SingleActivator(
                                                  LogicalKeyboardKey.arrowLeft):
                                              () => _moveColumnFocus(-1, 2),
                                          const SingleActivator(
                                                  LogicalKeyboardKey
                                                      .arrowRight):
                                              _enterBrowseColumn,
                                        },
                                      _ => <ShortcutActivator, VoidCallback>{
                                          const SingleActivator(
                                                  LogicalKeyboardKey.arrowLeft):
                                              _handleBrowseLeft,
                                          // See _browseRowKeys'/
                                          // _moveBrowseRowFocus's doc
                                          // comments — explicit row-to-row
                                          // jump instead of default
                                          // traversal's expensive search
                                          // across every cached row's
                                          // posters.
                                          const SingleActivator(
                                                  LogicalKeyboardKey.arrowDown):
                                              () => _moveBrowseRowFocus(1),
                                          const SingleActivator(
                                                  LogicalKeyboardKey.arrowUp):
                                              () => _moveBrowseRowFocus(-1),
                                        },
                                    }
                                  : <ShortcutActivator, VoidCallback>{
                                      // 3 columns now (tabs, groups, the merged
                                      // live-list-over-video region) — the list
                                      // panel is a plain vertical list like the
                                      // groups column, so Left/Right always
                                      // switching columns (never intra-row) is
                                      // safe here, same as before the merge.
                                      //
                                      // The timeline guide is the one exception: at depth 2 while
                                      // it's showing, Left and Right step the view one 30-minute
                                      // slot (see _TimelineGuideState.moveHorizontal) rather than
                                      // moving column. Left falls back to the "press again to leave
                                      // for the groups" escape (_handleBrowseLeft) only at the edge
                                      // of the guide's window; the Back button is the quick way out.
                                      const SingleActivator(
                                              LogicalKeyboardKey.arrowLeft):
                                          (_focusDepth == 2 &&
                                                  showTimelineGuide)
                                              ? _handleTimelineLeft
                                              : () => _moveColumnFocus(-1, 2),
                                      // Already in the last column: Right has
                                      // nowhere further to go, so it becomes a
                                      // shortcut straight to fullscreen on
                                      // whatever's currently playing instead of
                                      // a dead end — otherwise finding your way
                                      // back to fullscreen meant re-selecting
                                      // the same channel from the list again.
                                      // In the timeline guide, Right steps
                                      // the view one 30-minute slot instead
                                      // (see moveHorizontal).
                                      const SingleActivator(LogicalKeyboardKey
                                          .arrowRight): (_focusDepth == 2 &&
                                              showTimelineGuide)
                                          ? () => _timelineGuideKey.currentState
                                              ?.moveHorizontal(1)
                                          : _focusDepth == 2
                                              ? _goFullscreenIfPlaying
                                              : () => _moveColumnFocus(1, 2),
                                      // Default directional traversal picks
                                      // Up/Down by on-screen rect overlap,
                                      // which reliably lands on the wrong
                                      // block once a row's programmes are
                                      // much wider/narrower than its
                                      // neighbours' — reported directly on
                                      // real hardware (moving off a long
                                      // block landed near the *end* of its
                                      // span in the next row, not "now").
                                      // See _TimelineGuideState.moveVertical.
                                      if (_focusDepth == 2 &&
                                          showTimelineGuide) ...{
                                        // Down from the filter button or
                                        // field (two separate nodes — see
                                        // _timelineFilterButtonFocusNode's
                                        // doc comment for why) enters the
                                        // guide via focusEntry() instead of
                                        // moveVertical(1), which operates on
                                        // a row index that's meaningless
                                        // until the guide's actually been
                                        // entered once.
                                        const SingleActivator(
                                            LogicalKeyboardKey
                                                .arrowDown): () =>
                                            (_timelineFilterButtonFocusNode
                                                        .hasFocus ||
                                                    _timelineFilterFieldFocusNode
                                                        .hasFocus ||
                                                    _timelineKeyboardScope
                                                        .hasFocus)
                                                ? _timelineGuideKey.currentState
                                                    ?.focusEntry()
                                                : _timelineGuideKey.currentState
                                                    ?.moveVertical(1),
                                        const SingleActivator(
                                                LogicalKeyboardKey.arrowUp):
                                            () => _timelineGuideKey.currentState
                                                ?.moveVertical(-1),
                                      },
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
                                          child:
                                              _buildLiveRegion(playlist, epg),
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
        // Windows only — requested directly, citing TiviMate's own
        // multiview (works fine even on a Fire Stick) and that a Windows
        // PC has far more headroom than any box this app otherwise
        // targets. See DesktopMultiviewScreen's own doc comment for why
        // this doesn't extend to mobile/TV: `media_kit`'s texture-based
        // rendering is what actually makes several simultaneous players
        // safe, and only Windows has that player at all.
        // TiviMate's own multiview runs fine even on older Fire Sticks —
        // requested directly, so this isn't Windows-only the way most of
        // this session's other desktop-specific work has been. Windows
        // keeps its mouse-driven, media_kit-backed screen; every other
        // platform gets a separate, remote-first one built around
        // video_player_hdr instead (there is no cross-platform video
        // engine in this app — see pubspec.yaml's media_kit comment).
        _SelectableRow(
          icon: Icons.grid_view,
          label: 'Multiview',
          selected: false,
          collapsed: collapsed,
          onTap: () {
            if (Platform.isWindows) {
              DesktopMiniPlayer.instance.clear();
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const DesktopMultiviewScreen()));
            } else {
              // PlaybackService's own background-kept-alive live channel
              // (the mobile "island"/resume hint — deliberately still
              // playing after backing out of fullscreen, and almost
              // always populated anyway since the app auto-resumes the
              // last channel on launch) is a separate player system from
              // this screen's own controllers, same as DesktopMiniPlayer
              // is on Windows. Reported directly as its audio bleeding
              // through on top of whichever multiview cell has audio
              // focus — stopping it here is the same fix as the Windows
              // branch above, just a different background player.
              unawaited(context.read<PlaybackService>().stop());
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MultiviewScreen()));
            }
          },
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
          icon: Icons.account_circle_outlined,
          label: context.watch<ViewerProfileService>().active.name,
          selected: false,
          collapsed: collapsed,
          onTap: _openProfilePicker,
        ),
        _SelectableRow(
          icon: Icons.settings,
          label: 'Settings',
          selected: false,
          collapsed: collapsed,
          onTap: _openSettings,
        ),
        const Divider(height: 16, color: Colors.white24),
        // Windows only — the app always launches fullscreen there now
        // (see main.dart's WindowOptions) with the title bar hidden
        // entirely, so there's no OS minimize *or* close button at all
        // anymore. Reported directly, in two parts: "Exit App" was the
        // only way to leave the foreground at all (it deliberately
        // disables every playlist too — see _hardExit's own doc comment,
        // a real feature, "free up this login for another device," not
        // something to lose for an ordinary minimize/close), and with no
        // title bar, Alt+F4 became the *only* way to close the window
        // short of that. Minimize/Close are the lightweight alternatives:
        // Minimize just sends the window to the taskbar, Close just quits
        // normally via _closeApp (the same call `_hardExit` ends with,
        // minus the playlist-disabling step) — neither touches playback
        // or playlists.
        if (Platform.isWindows) ...[
          _SelectableRow(
            icon: Icons.remove,
            label: 'Minimize',
            selected: false,
            collapsed: collapsed,
            onTap: _minimizeWindow,
          ),
          _SelectableRow(
            icon: Icons.close,
            label: 'Close',
            selected: false,
            collapsed: collapsed,
            onTap: _closeApp,
          ),
        ],
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
            focusNode: _firstGroupRowFocusNode,
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
          focusNode: _firstGroupRowFocusNode,
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
          focusNode: _firstGroupRowFocusNode,
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
            onLongPress: () => _showGroupOptions(group.playlistId, group.title,
                category: _tab == 'Movies' ? 'vod' : 'series'),
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

  void _onGuideFocusChanged(Channel channel, EpgProgram? program) {
    setState(() {
      _guideFocusedChannel = channel;
      _guideFocusedProgram = program;
    });
  }

  /// The small live-preview box both guide views use — the Timeline
  /// guide's own top-left corner box, and (reused, not duplicated) the
  /// plain "Live" guide's inline preview pane. Shows whatever's actually
  /// playing, or an informational card for whatever's minimized, or
  /// "Nothing playing". [channel] is `PlaybackService.currentChannel`,
  /// always null on Windows — that service is never touched by
  /// `DesktopPlayerScreen`/`DesktopMiniPlayer` (see their own doc
  /// comments), so this box has to watch `DesktopMiniPlayer.instance
  /// .channel` directly there instead, or it permanently reads "Nothing
  /// playing"/"Select a channel to start watching" even with a live
  /// channel actually minimized (reported directly on both guide views,
  /// separately — this exact box, sitting right next to a working resume
  /// pill saying otherwise, reading as "the mini player doesn't work").
  Widget _buildTimelinePreviewBox(Channel? channel) {
    if (Platform.isWindows) {
      // A real video feed, unlike the first pass at this box — unlike
      // `video_player_hdr`'s platform views (see `LiveResumeHint`'s own
      // doc comment for the real multi-consumer rendering bug that caused
      // on mobile), `media_kit`'s texture-based rendering supports more
      // than one `Video` widget bound to the same controller at once, and
      // in practice only one is ever actually mounted at a time anyway —
      // this one unmounts (channel.value becomes null, via `take()`) in
      // the same frame `DesktopPlayerScreen`'s own mounts, never both at
      // once. `DesktopMiniPlayer.controller` is read-only here — this box
      // doesn't take ownership of the session, just renders it.
      return ValueListenableBuilder<Channel?>(
        valueListenable: DesktopMiniPlayer.instance.channel,
        builder: (context, minimized, _) {
          if (minimized == null) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tv_off, color: Colors.white54),
                  SizedBox(height: 6),
                  Text('Nothing playing',
                      style: TextStyle(color: Colors.white70)),
                ],
              ),
            );
          }
          final controller = DesktopMiniPlayer.instance.controller;
          return ExcludeFocus(
            child: InkWell(
              onTap: () {
                final session = DesktopMiniPlayer.instance.take();
                if (session == null) return;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DesktopPlayerScreen(
                          channel: minimized,
                          existingPlayer: session.$1,
                          existingController: session.$2,
                        )));
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null)
                    Video(controller: controller, controls: NoVideoControls)
                  else
                    const ColoredBox(color: Colors.black),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 20, 10, 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.8),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(minimized.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          const Text('Click to resume',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (channel == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off, color: Colors.white54),
            SizedBox(height: 6),
            Text('Nothing playing', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return ExcludeFocus(
      // Excluded from focus, not just tap-only — this box sits directly
      // above the grid's top row, and default D-pad traversal reaching Up
      // from there would otherwise land here instead of stopping cleanly
      // at the guide's own edge.
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel))),
        // Same channel-id key as the full-size pane in the non-timeline
        // branch below — see the long comment there for why (stale-frame
        // vs. texture-teardown race). showControls: false — the full
        // title/seek/play-pause bar this draws by default doesn't fit a
        // box this small; reported directly as "stuck on" permanently
        // covering most of the preview. Tapping the bare video now jumps
        // to fullscreen instead of a separate button.
        child: VideoPlayerPane(
            key: ValueKey(channel.id), showEpgBar: false, showControls: false),
      ),
    );
  }

  /// Replaces [_buildTimelinePreviewBox] (and the description panel next
  /// to it) while [_timelineFilterActive] — reclaims that row's screen
  /// space for the filter input itself. The Android TV system on-screen
  /// keyboard docks at the bottom of the screen, and the guide below this
  /// row is already fairly short; shrinking this row down to just the
  /// field (see the `SizedBox(height: 56, ...)` wrapping it in
  /// [_buildLiveRegion]) is the only real lever available to keep the
  /// now-narrower filtered row list visible above wherever the keyboard
  /// ends up — whether that's actually enough headroom on a given real
  /// device can only be confirmed on hardware, not here.
  /// Real TV/remote-control devices (`isTelevision`) get
  /// [_TimelineVirtualKeyboard] instead of the `TextField` below — see its
  /// own doc comment for why: the system on-screen keyboard proved
  /// unreliable on real hardware (Formuler, Fire Stick) even after fixing
  /// a real focus-steal bug that was also contributing to it. Phone
  /// (touch) and Windows (physical keyboard) already work correctly with
  /// the plain `TextField` and must keep doing so unchanged — gated on
  /// `isTelevision` specifically (a device-category fact set once at
  /// launch from a native Leanback/TV-UI-mode check), not `layoutMode`
  /// (a user-togglable preference a phone could have set to "TV" for
  /// other reasons while still only having touch input) or
  /// `Platform.isWindows` (doesn't distinguish Android TV from phone at
  /// all).
  Widget _buildTimelineFilterBar(Channel? channel) {
    final isTv = context.watch<AppPreferences>().isTelevision;
    if (!isTv) {
      return Container(
        clipBehavior: Clip.antiAlias,
        // Centered, not top-pinned — this box keeps the normal preview
        // row's full height rather than collapsing (see the Column
        // children construction in _buildLiveRegion), so without this the
        // filter bar would otherwise sit awkwardly at the very top of a
        // tall, mostly-empty box.
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.18), width: 1.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.white70, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _timelineFilterController,
                // A fresh node, never previously focused, with autofocus —
                // the one thing confirmed to actually open the keyboard
                // reliably here. See _timelineFilterButtonFocusNode's doc
                // comment for why this isn't the shared button node.
                focusNode: _timelineFilterFieldFocusNode,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Filter channels in this group...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: (value) =>
                    setState(() => _timelineFilterQuery = value),
              ),
            ),
            IconButton(
              tooltip: 'Close filter',
              icon: const Icon(Icons.close, color: Colors.white70, size: 18),
              onPressed: _closeTimelineFilter,
            ),
          ],
        ),
      );
    }
    // TV: half the width, translucent, with the live preview still
    // visible alongside (and faintly through) it — reported directly,
    // once the keyboard actually worked, that a full-width opaque panel
    // hid the still-playing video for no reason; nothing stops it from
    // staying visible underneath/beside a narrower, see-through one.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18), width: 1.5),
            ),
            child: _buildTimelinePreviewBox(channel),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18), width: 1.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            // No mainAxisSize here — it must fill the full tight height
            // this Container passes straight through so the Expanded
            // keyboard grid below has real, bounded constraints to size
            // itself against (see the TV layout bug this already caused
            // once, now fixed, in git history for this file).
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.search, color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _timelineFilterQuery.isEmpty
                            ? 'Filter channels in this group...'
                            : _timelineFilterQuery,
                        style: TextStyle(
                            color: _timelineFilterQuery.isEmpty
                                ? Colors.white54
                                : Colors.white),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close filter',
                      icon: const Icon(Icons.close,
                          color: Colors.white70, size: 18),
                      onPressed: _closeTimelineFilter,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _TimelineVirtualKeyboard(
                    scope: _timelineKeyboardScope,
                    nodes: _timelineKeyboardNodes,
                    onChar: (c) => setState(() => _timelineFilterQuery += c),
                    onSpace: () => setState(() => _timelineFilterQuery += ' '),
                    onBackspace: () => setState(() {
                      if (_timelineFilterQuery.isNotEmpty) {
                        _timelineFilterQuery = _timelineFilterQuery.substring(
                            0, _timelineFilterQuery.length - 1);
                      }
                    }),
                    onClose: _closeTimelineFilter,
                    onExitDown: () =>
                        _timelineGuideKey.currentState?.focusEntry(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

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
    final rawChannel = playback.currentChannel;
    // rawChannel.rawId, not rawChannel.id — Channel.isLiveId expects the
    // raw, unprefixed id.
    final channel = rawChannel != null && Channel.isLiveId(rawChannel.rawId)
        ? rawChannel
        : null;

    // Opt-in alternate view (Settings > Theme > "Guide view") — see
    // _TimelineGuide's own doc comment. Checked after the two branches
    // above, not before: a favorited movies/shows group still needs its
    // own catalog UI regardless of this setting, same as it would with
    // the normal live-list view.
    if (context.watch<AppPreferences>().guideViewMode == 'timeline') {
      // A reduced, fixed-size preview plus a description panel stacked
      // *above* the guide (ynoTV's layout), rather than the guide taking
      // the whole region with no video at all — reported on real hardware
      // as "the live stream player never reduced". A Column, not a Stack:
      // the guide's own channel-label column has to start below the
      // header, not run underneath it. The groups column is a sibling of
      // this whole region in the outer Row, so it stays full height.
      // While filtering, the preview box/description panel are replaced
      // entirely by _buildTimelineFilterBar — reclaiming that row's
      // screen space for the guide below it is the only real lever
      // available against the system on-screen keyboard eating into an
      // already-small guide area once it pops up (see
      // _buildTimelineFilterBar's own doc comment).
      final previewRow = _timelineFilterActive
          ? _buildTimelineFilterBar(channel)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Windows gets a proportionally wider video box (Expanded,
                // instead of a fixed 284px) to match its own taller preview
                // row below — a fixed width sized for the Android TV box's
                // fixed 160px-tall row would look like a thin sliver once that
                // row is several times taller on a resizable desktop window.
                Platform.isWindows
                    ? Expanded(
                        // flex 2:1 against the description panel's flex 1 below
                        // (was 2:3, i.e. 40% of the row) — requested directly:
                        // extend the mini player right by at least 50%; 2:1
                        // gives it roughly two-thirds of the row (a ~67%
                        // increase from 40%), well past that minimum, since the
                        // live program description next to it doesn't need to
                        // be nearly that wide to stay readable.
                        flex: 2,
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                                width: 1.5),
                          ),
                          child: _buildTimelinePreviewBox(channel),
                        ),
                      )
                    : Container(
                        width: 284,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.18),
                              width: 1.5),
                        ),
                        child: _buildTimelinePreviewBox(channel),
                      ),
                Expanded(
                  flex: 1,
                  child: _GuideNowPanel(
                    focusedChannel: _guideFocusedChannel,
                    focusedProgram: _guideFocusedProgram,
                    playingChannel: channel,
                    epg: epg,
                  ),
                ),
              ],
            );

      final guide = _TimelineGuide(
        key: _timelineGuideKey,
        channels: _filteredLiveChannelsForGuide(playlist),
        epg: epg,
        // Closes the filter (if it's open) before actually opening the
        // channel — reported directly: picking a channel while filtering,
        // going fullscreen, then backing out left the filter keyboard
        // stuck open, since nothing on that whole round trip ever touched
        // _timelineFilterActive on its own.
        onOpen: (channel) {
          if (_timelineFilterActive) _closeTimelineFilter();
          _selectChannel(channel);
        },
        onFocusChanged: _onGuideFocusChanged,
        onShowOptions: _showChannelOptions,
        onWindowStale: () => setState(() => _timelineGuideKey = GlobalKey()),
        filterFocusNode: _timelineFilterButtonFocusNode,
        onFilterToggle: _openTimelineFilter,
        // While filtering, focus belongs to whichever input is actually
        // showing (the virtual keyboard's first key on TV, the TextField
        // elsewhere); otherwise to the button. Only the button is actually
        // mounted above the guide when not filtering, so requesting focus
        // on the field/keyboard here while inactive would land nowhere —
        // neither widget exists yet in that state.
        onReachedTop: () {
          if (!_timelineFilterActive) {
            _timelineFilterButtonFocusNode.requestFocus();
          } else if (context.read<AppPreferences>().isTelevision) {
            _timelineKeyboardNodes.first.first.requestFocus();
          } else {
            _timelineFilterFieldFocusNode.requestFocus();
          }
        },
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        // The collapse to a taller keyboard-sized panel only applies on
        // real TV/remote devices — that's the one case using
        // _TimelineVirtualKeyboard (see _buildTimelineFilterBar), which
        // needs real room for its key grid. Gated on isTelevision
        // specifically, not Platform.isWindows: a phone with Layout
        // manually forced to "TV" still gets the plain TextField bar (see
        // _buildTimelineFilterBar) and must keep its normal layout too —
        // reported directly, of the Platform.isWindows-only version of
        // this check: "it takes the whole screen (eliminating the mini
        // player)... doesn't happen on Formuler," because Windows's normal
        // preview row is ~50% of the window (flex-based, see below) and
        // collapsing that to a small bar was a far more drastic, jarring
        // change than Android TV's fixed-160px starting point warranted.
        children:
            _timelineFilterActive && context.read<AppPreferences>().isTelevision
                ? [
                    SizedBox(height: 200, child: previewRow),
                    const Divider(height: 12),
                    Expanded(child: guide),
                  ]
                : Platform.isWindows
                    ? [
                        // Android TV's fixed 160px preview row read as the right
                        // ratio there (reported directly), but on a much taller,
                        // resizable PC window that same fixed height left the
                        // mini player tiny against a disproportionately dominant
                        // guide below it (roughly an 85/15 split in the guide's
                        // favor on a typical window). Flex-based instead of a
                        // fixed height, so it scales with the actual window
                        // instead of a constant tuned for a TV's screen — an even
                        // 50/50 split here cuts the guide's own share by well
                        // over 40% (85 -> 50) and gives the mini player a real,
                        // substantial size instead of the sliver it was, reported
                        // directly as still too small even after the preview
                        // itself got real video in it.
                        Expanded(flex: 1, child: previewRow),
                        const Divider(height: 12),
                        Expanded(flex: 1, child: guide),
                      ]
                    : [
                        SizedBox(height: 160, child: previewRow),
                        const Divider(height: 12),
                        Expanded(child: guide),
                      ],
      );
    }

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
            // `channel` (`PlaybackService.currentChannel`) is always null
            // on Windows — that service is never touched by
            // `DesktopPlayerScreen`/`DesktopMiniPlayer` (see their own
            // doc comments) — so this plain pane used to permanently read
            // "Select a channel to start watching" there even with a
            // live channel actually minimized, the exact same gap the
            // Timeline guide's own preview box had before it was fixed to
            // watch `DesktopMiniPlayer` directly. Reported directly as
            // the same bug on this ("Live", non-timeline) guide view —
            // reusing that already-fixed box here instead of duplicating
            // its Windows-vs-not branching a second time. See its own doc
            // comment for why rendering `DesktopMiniPlayer`'s video here
            // is safe (no second simultaneous stream/audio consumer):
            // `media_kit`'s texture-based rendering tolerates more than
            // one `Video` widget on the same controller, and in practice
            // only one is ever actually mounted at a time anyway.
            child: _buildTimelinePreviewBox(channel),
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

  /// Live TV only — for a duplicate feed within an otherwise-wanted group
  /// (e.g. the same channel offered in both HD and HEVC) that whole-group
  /// hiding can't target. `toggleChannelHidden` mutates the underlying
  /// Set synchronously before its own `await` (same shape as
  /// `toggleFavorite`/`Channel.isFavorite` above), so `isChannelHidden`
  /// already reflects the new state by the time the snackbar reads it.
  void _toggleHiddenWithFeedback(BuildContext context, Channel channel) {
    final playlist = context.read<PlaylistManager>();
    playlist.toggleChannelHidden(channel);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(playlist.isChannelHidden(channel)
          ? 'Hidden — find it again in Settings > Playlist Manager > '
              'Hidden Channels'
          : 'Unhidden'),
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
        // Keyed by which group is actually showing — without this,
        // switching groups (including the Live TV tab's own "Favourites"
        // entry) left Flutter free to reuse each row's Element/FocusNode
        // positionally across completely different channel lists, the
        // same class of cross-list focus leak already fixed elsewhere in
        // this file (the browse groups rail, the tabs-to-groups column
        // jump). Confirmed as the actual cause of a reused row's own
        // `HoldToActivate` state receiving a stray key-up event meant for
        // whatever was tapped in the groups column, auto-"pressing" it —
        // reported directly as the first favourite channel launching into
        // fullscreen on its own. A key here forces a genuinely fresh
        // Element (and fresh `HoldToActivate` state) every time.
        key: ValueKey(
            '$_tab::${_selectedGroup ?? _effectiveLiveGroup(playlist)}'),
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
              focusNode: isSelected
                  ? _currentChannelFocusNode
                  : (i == 0 ? _firstLiveChannelFocusNode : null),
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
              // epgId (rawId, or a manual override), not the composite `id`
              // — see
              // PlaylistManager.knownChannelIdsFor's doc comment.
              subtitle: _CurrentProgramLine(channelId: channel.epgId),
              trailing: ExcludeFocus(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // For a duplicate feed within this same group (e.g.
                    // the same channel in HD and HEVC) — see
                    // AppConstants.keyHiddenChannels's doc comment.
                    IconButton(
                      icon: const Icon(Icons.visibility_off_outlined,
                          color: Colors.white70),
                      tooltip: 'Hide this channel',
                      onPressed: () =>
                          _toggleHiddenWithFeedback(context, channel),
                    ),
                    IconButton(
                      icon: Icon(
                          channel.isFavorite ? Icons.star : Icons.star_border,
                          color: channel.isFavorite
                              ? Colors.amber
                              : Colors.white70),
                      onPressed: () =>
                          _toggleFavoriteWithFeedback(context, channel),
                    ),
                  ],
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
    final playlist = context.read<PlaylistManager>();
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
            cardWidth: _browsePosterWidth,
            cardPosterHeight: _browsePosterHeight,
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
              // asSeries alone isn't a safe "definitely a movie" proxy —
              // an episode with no resolvable seriesId still isn't a
              // movie, and would hit the wrong API call (get_vod_info on
              // an episode's raw id) if it fell into that branch below.
              if (asSeries) {
                final series = XtreamSeries(
                  seriesId: c.seriesId!,
                  playlistId: c.playlistId,
                  name: c.seriesName ?? c.name,
                  categoryId: '',
                  coverUrl: c.seriesCoverUrl,
                );
                _updateBrowseFocus(
                  playlist: playlist,
                  id: series.id,
                  title: title,
                  imageUrl: imageUrl,
                  backdropUrl: c.backdropUrl,
                  fetchDescription: () =>
                      playlist.getHeroSeriesDescription(series),
                );
              } else if (idPrefix == 'xt_vod_') {
                _updateBrowseFocus(
                  playlist: playlist,
                  id: c.id,
                  title: title,
                  imageUrl: imageUrl,
                  backdropUrl: c.backdropUrl,
                  fetchDescription: () => playlist.getHeroVodDescription(c),
                );
              } else {
                // An episode with no seriesId to resolve — nothing
                // sensible to fetch a plot for.
                _updateBrowseFocus(
                  playlist: playlist,
                  id: c.id,
                  title: title,
                  imageUrl: imageUrl,
                  backdropUrl: c.backdropUrl,
                  fetchDescription: () => Future.value(null),
                );
              }
              _ensureRowVisible(_continueWatchingRowKey);
              // Always row 0 when present — see _browseRowKeys' doc
              // comment, it's always inserted first.
              _setFocusedBrowseRow(0);
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
        imageUrlOf: (c) => c.posterUrl ?? c.logoUrl,
        backdropUrlOf: (c) => c.backdropUrl,
        onOpen: _openMovie,
        playFocusNode: _moviesWhatsNewPlayFocusNode,
        emptyText: 'No recently added movies yet',
      );
    }
    final groupsWithItems =
        visibleGroups.where((g) => g.channels.isNotEmpty).toList();
    final continueRow =
        _buildContinueWatchingRow(idPrefix: 'xt_vod_', onTap: _openMovie);
    // See _browseRowKeys' doc comment — parallel to `rows` below, same
    // order (Continue Watching first when present, then one entry per
    // category), rebuilt fresh on every call.
    _browseRowKeys = [
      if (continueRow != null) null,
      for (final group in groupsWithItems)
        (playlistId: group.playlistId, title: group.title),
    ];
    return _buildBrowseScaffold(
      rows: [
        if (continueRow != null) continueRow,
        for (final (groupIndex, group) in groupsWithItems.indexed)
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
                cardWidth: _browsePosterWidth,
                cardPosterHeight: _browsePosterHeight,
                focusNode: index == 0
                    ? _firstPosterFocusNodeForGroup(
                        group.playlistId, group.title)
                    : null,
                isFavorite: c.isFavorite,
                onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
                onTap: () => _openMovie(c,
                    groupPlaylistId: group.playlistId, groupTitle: group.title),
                onFocusGained: () {
                  _updateBrowseFocus(
                    playlist: playlist,
                    id: c.id,
                    title: c.name,
                    imageUrl: c.logoUrl,
                    backdropUrl: c.backdropUrl,
                    fetchDescription: () => playlist.getHeroVodDescription(c),
                  );
                  _ensureRowVisible(
                      _keyForGroup(group.playlistId, group.title));
                  _setFocusedBrowseRow(
                      (continueRow != null ? 1 : 0) + groupIndex);
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
    // See _browseRowKeys' doc comment — parallel to `rows`, same order.
    // Built imperatively alongside it (not derived from `groups` by
    // index) because empty groups are skipped below via `continue`, so a
    // group's position in `groups` doesn't match its actual row index.
    final rowKeys = <({String playlistId, String title})?>[
      if (continueRow != null) null,
    ];
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
        imageUrlOf: (s) => s.posterUrl ?? s.coverUrl,
        backdropUrlOf: (s) => s.backdropUrl,
        onOpen: _openSeries,
        playFocusNode: _showsWhatsNewPlayFocusNode,
        emptyText: 'No recently added shows yet',
      );
    }
    for (final group in groups) {
      final items = playlist.visibleSeries(
          playlistId: group.playlistId, categoryName: group.title);
      if (items.isEmpty) continue;
      final rowIndex = rowKeys.length;
      rowKeys.add((playlistId: group.playlistId, title: group.title));
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
            cardWidth: _browsePosterWidth,
            cardPosterHeight: _browsePosterHeight,
            focusNode: index == 0
                ? _firstPosterFocusNodeForGroup(group.playlistId, group.title)
                : null,
            isFavorite: s.isFavorite,
            onToggleFavorite: () =>
                _toggleSeriesFavoriteWithFeedback(context, s),
            onTap: () => _openSeries(s,
                groupPlaylistId: group.playlistId, groupTitle: group.title),
            onFocusGained: () {
              _updateBrowseFocus(
                playlist: playlist,
                id: s.id,
                title: s.name,
                imageUrl: s.coverUrl,
                backdropUrl: s.backdropUrl,
                fetchDescription: () => playlist.getHeroSeriesDescription(s),
              );
              _ensureRowVisible(_keyForGroup(group.playlistId, group.title));
              _setFocusedBrowseRow(rowIndex);
            },
          ),
        ),
      ));
    }
    _browseRowKeys = rowKeys;
    return _buildBrowseScaffold(
      rows: rows,
      emptyText: rows.isEmpty ? 'Loading TV show categories...' : null,
    );
  }

  Widget _buildBrowseScaffold({required List<Widget> rows, String? emptyText}) {
    return Column(
      children: [
        _BrowseHero(
            title: _focusedTitle,
            imageUrl: _focusedImageUrl,
            backdropUrl: _focusedBackdropUrl,
            description: _focusedDescription),
        Expanded(
          child: emptyText != null
              ? Center(child: Text(emptyText))
              : ListView.builder(
                  controller: _browseScrollController,
                  itemCount: rows.length,
                  // Every row is exactly _categoryRowHeight tall (see its
                  // own doc comment) — telling Flutter that explicitly
                  // lets it compute scroll geometry analytically instead
                  // of needing to lay out every row to know where they
                  // are, which is what makes _scrollToBrowseGroup's
                  // direct jumpTo to an unbuilt row exact.
                  itemExtent: _categoryRowHeight,
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
    // Every palette now gets the same contour + diagonal gradient-sheen
    // focus treatment — border + a dark->accent->dark gradient using this
    // palette's own `scheme.primary` as the accent — instead of a flat
    // solid fill, confirmed directly on real hardware as reading
    // "creamy"/pastel for Dark/Gold specifically, then extended to every
    // palette once that one looked right: "all palettes should reflect
    // these new themes... make sure all tabs all rows all groups guide
    // etc matched the gold theme." Minimalist's previous frosted-glass
    // blur treatment is retired in favor of this, for the same reason —
    // `useGlass` stays false now, and `scheme.primary` already resolves
    // to white for Minimalist (see `buildPaletteColorScheme`), so this
    // needs no palette-specific branching at all. The persistent
    // "selected" border below already gave this row a contour; this just
    // extends that same language to the live D-pad focus state too,
    // distinguishing the two via a soft glow (the outer Container near
    // the bottom) rather than a filled block.
    // Focus (where the D-pad cursor currently is) and "selected" (this is
    // the channel actually playing, which stays true while focus has moved
    // on to browse something else) are different facts and were rendered
    // identically — a solid primary fill — which read as "multiple things
    // highlighted at once" whenever something was playing in the
    // background while the cursor sat elsewhere. Only the live D-pad
    // cursor gets the solid fill now; "currently playing" gets a quieter
    // tinted/outlined treatment instead.
    final isPlaying = widget.selected && !_focused;
    final unfocusedColor =
        isPlaying ? Colors.transparent : Colors.white.withValues(alpha: 0.04);
    final focusedForeground = scheme.primary;
    final foregroundColor = _focused
        ? focusedForeground
        : (isPlaying ? scheme.primary : Colors.white);
    // `scheme.tertiary` — a dedicated icon/symbol-glyph accent, separate
    // from the text/border/gradient accent (`scheme.primary`) — see
    // `buildPaletteColorScheme`'s own doc comment for why (Habs: white
    // contour/text, blue icons).
    final iconColor =
        (_focused || isPlaying) ? scheme.tertiary : Colors.white70;
    final leadingWidget =
        widget.leading ?? Icon(widget.icon, color: iconColor, size: 20);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Container(
        // Always present (even with an empty shadow list) rather than
        // conditionally wrapped — MinimalGlassFocus's own doc comment just
        // below has the full story on why changing a focus widget's
        // ancestor shape between builds corrupts its FocusNode on real
        // hardware; the same rule applies one level up, here.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          // A flat `Colors.black87` fill here photographed as a much
          // bigger gold wash than it read live (the glow below bleeding
          // into a near-opaque black in a phone camera's auto-exposure) —
          // reported directly as still looking "filled". A real diagonal
          // sheen (dark -> accent-tinted -> dark), using this palette's own
          // `scheme.primary`, is what the owner actually asked for
          // ("shiny/mirror"); this paints it, and Material's own `color`
          // below turns transparent to let it show through only when
          // focused. Every palette uses this now, including Minimalist —
          // see this method's own history for why its previous distinct
          // frosted-glass treatment was retired in favor of the same look
          // everything else gets.
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
                      color: scheme.primary.withValues(alpha: 0.35),
                      blurRadius: 10)
                ]
              : const [],
        ),
        // MinimalGlassFocus's own blur special-case is retired now that
        // every palette uses the gradient-sheen above instead — see
        // ModeButton's identical comment for why the wrapper itself stays.
        child: MinimalGlassFocus(
          active: false,
          borderRadius: 8,
          child: Material(
            color: _focused ? Colors.transparent : unfocusedColor,
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
              // changes, unlike the fill — and now also shows it for the
              // live focus state itself, since that state no longer has a
              // solid fill of its own to lean on.
              side: _focused
                  ? BorderSide(color: scheme.primary, width: 2.5)
                  : widget.selected
                      ? BorderSide(color: scheme.primary, width: 1.5)
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                                    size: 8, color: scheme.tertiary),
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
                                          size: 14, color: scheme.tertiary),
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
    final highlighted = widget.selected || _focused;
    // Every palette now gets the same contour + gradient-sheen treatment
    // — see `_SelectableRow`'s doc comment for the full story. This is
    // the real playlist groups list specifically — confirmed directly as
    // the one place the original `_SelectableRow` contour fix never
    // reached, since this is a wholly separate widget (only the
    // "Favourites" pseudo-entry and the sidebar tabs go through
    // `_SelectableRow`; every actual group from the playlist renders
    // through here instead).
    final focusedForeground = scheme.primary;
    // Focused or merely selected, both are border-only now (see `side:`
    // below) rather than a filled block — see `_SelectableRow`'s doc
    // comment for the full story.
    final backgroundColor = (_focused || widget.selected)
        ? Colors.transparent
        : Colors.white.withValues(alpha: 0.04);
    final foregroundColor = highlighted ? focusedForeground : Colors.white;
    // `scheme.tertiary` — a dedicated icon/symbol-glyph accent, separate
    // from the text/border/gradient accent (`focusedForeground`) — see
    // `buildPaletteColorScheme`'s own doc comment for why (Habs: white
    // contour/text, blue icons).
    final iconColor = highlighted ? scheme.tertiary : Colors.white70;

    final iconWidget = Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(widget.icon, color: iconColor, size: 20),
        if (widget.isFavorited)
          Positioned(
            right: -4,
            top: -4,
            child: Icon(Icons.star,
                size: 12, color: highlighted ? scheme.tertiary : Colors.amber),
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
            child: Container(
              // Always present (even with an empty shadow list) rather
              // than conditionally wrapped — MinimalGlassFocus's own doc
              // comment just below has the full story on why changing a
              // focus widget's ancestor shape between builds corrupts its
              // FocusNode on real hardware.
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                // Same diagonal sheen as `_SelectableRow` — see its doc
                // comment for the full story (every palette, including
                // Minimalist, gets this now).
                gradient: _focused
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.black,
                          Color.lerp(
                              Colors.black, scheme.primaryContainer, 0.4)!,
                          Colors.black,
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      )
                    : null,
                boxShadow: _focused
                    ? [
                        BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.35),
                            blurRadius: 10)
                      ]
                    : const [],
              ),
              // MinimalGlassFocus's own blur special-case is retired now
              // that every palette uses the gradient-sheen above instead —
              // see ModeButton's identical comment for why the wrapper
              // itself stays.
              child: MinimalGlassFocus(
                active: false,
                borderRadius: 8,
                child: Material(
                  color: backgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    // Same persistent-marker reasoning as `_SelectableRow`'s
                    // own `side:` — see its doc comment.
                    side: _focused
                        ? BorderSide(color: scheme.primary, width: 2.5)
                        : widget.selected
                            ? BorderSide(color: scheme.primary, width: 1.5)
                            : BorderSide.none,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
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
      ),
    );
  }
}

/// Windows gets noticeably larger browse posters than the TV-tuned
/// defaults ([PosterCard.width]/[PosterCard.posterHeight]) — the same
/// 1.8x bump [_BrowseHero]'s own height uses, so the grid under that much
/// bigger hero banner doesn't still read as tuned for a TV screen. Plain
/// top-level getters, not `static const` like [PosterCard]'s own fields —
/// those need to stay compile-time constants (used as default parameter
/// values), which a `Platform.isWindows` check can't be.
// Was 1.8 — reduced ~30% per direct feedback that the first pass at
// this was too big.
const double _windowsPosterScale = 1.26;
double get _browsePosterWidth => Platform.isWindows
    ? PosterCard.width * _windowsPosterScale
    : PosterCard.width;
double get _browsePosterHeight => Platform.isWindows
    ? PosterCard.posterHeight * _windowsPosterScale
    : PosterCard.posterHeight;
double get _browseCardHeight =>
    _browsePosterHeight +
    (Platform.isWindows
        ? PosterCard.titleHeight * _windowsPosterScale
        : PosterCard.titleHeight);

/// [_CategoryRow]'s own section-title bar — a fixed height (not left to
/// whatever `SectionLabel`'s text happens to measure out to) specifically
/// so [_categoryRowHeight] below is an exact, enforced number rather than
/// a guess about font-metric-dependent text layout.
const double _categoryRowHeaderHeight = 40;
const double _categoryRowBottomPadding = 18;

/// Every `_CategoryRow` is *made* to be exactly this tall (see its own
/// `build`, which wraps its content in a `SizedBox` of this height) —
/// deliberately computed from the exact same values that actually
/// determine the row's real layout, not a separately hand-tuned constant
/// that can silently drift out of sync with them (confirmed as a real,
/// shipped bug: an old hand-picked value survived two later poster-size
/// changes, each shrinking the real row without this being updated to
/// match — reported directly, after a first fix attempt, as "math will
/// always be wrong if groups are added or removed"). `index * this` is
/// exactly where that row sits — used instead of `Scrollable.ensureVisible`
/// for [_TvHomeScreenState._scrollToBrowseGroup] because that approach
/// fundamentally can't reach a row the `ListView.builder` hasn't built
/// yet (its `GlobalKey.currentContext` is null until it scrolls near the
/// viewport). Also handed to that same `ListView.builder` as its
/// `itemExtent` (see `_buildBrowseScaffold`) — telling Flutter the exact,
/// true per-item height lets it compute scroll geometry (including
/// `maxScrollExtent`) analytically, without needing to lay out every
/// intervening row, which is what makes a direct, unbuilt-row `jumpTo`
/// exact instead of an estimate in the first place.
double get _categoryRowHeight =>
    _categoryRowBottomPadding + _categoryRowHeaderHeight + _browseCardHeight;

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
    // The *whole row* is pinned to _categoryRowHeight (header slot +
    // poster strip + bottom padding, exactly the values that make up
    // that getter) rather than letting it size to its own intrinsic
    // content — see _categoryRowHeight's own doc comment for why this
    // enforcement, not just a matching number elsewhere, is the actual
    // point: it's what makes that getter *true* instead of a guess.
    return SizedBox(
      height: _categoryRowHeight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: _categoryRowBottomPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: _categoryRowHeaderHeight,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SectionLabel(
                    title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
              ),
            ),
            SizedBox(
              // Was 210 — ~20% smaller per feedback that the catalog read
              // too large. Windows scales back up from there — see
              // _browseCardHeight's own doc comment.
              height: _browseCardHeight,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                itemCount: items.length,
                // Flutter's default (250px, ~2 cards) only starts
                // building/decoding a card just barely before it's
                // visible, so a steady scroll still shows the grey-then-
                // fade-in pop-in right at the edge of the screen. Roughly
                // 5 cards' worth gives posters a head start decoding
                // before they're seen — some extra memory (the image
                // cache ceiling still bounds the total), traded for a
                // visibly smoother scroll.
                scrollCacheExtent:
                    ScrollCacheExtent.pixels(_browsePosterWidth * 5),
                itemBuilder: (context, i) => itemBuilder(items[i], i),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Big backdrop header showing whatever poster card currently has D-pad
/// focus, with its title overlaid — mirrors the hero-banner pattern from
/// Apple TV / Android TV browse screens.
class _BrowseHero extends StatelessWidget {
  const _BrowseHero(
      {required this.title,
      required this.imageUrl,
      this.backdropUrl,
      this.description});

  final String? title;

  /// A portrait poster/logo — the safe fallback image when [backdropUrl]
  /// isn't available yet (used by Android/TV's full-bleed crop, which
  /// already reads fine at its small fixed height, and by Windows' own
  /// poster-beside-text layout, which exists specifically to avoid
  /// stretching a portrait image edge-to-edge).
  final String? imageUrl;

  /// A true landscape TMDB backdrop — see `Channel.backdropUrl`'s doc
  /// comment. When this is set, both platforms prefer it over [imageUrl]
  /// for the full-bleed background; Windows additionally switches its
  /// *whole layout* to the full-bleed style for it (see [build]) instead
  /// of the poster-beside-text compromise, since a real landscape image
  /// doesn't have that layout's stretching problem to work around in the
  /// first place.
  final String? backdropUrl;

  /// Null while nothing's been focused yet, while it's still being
  /// fetched (see `_TvHomeScreenState._updateBrowseFocus`'s debounce), or
  /// when the title genuinely has none — the description area just shows
  /// nothing in all three cases, same as leaving a field blank rather
  /// than showing a misleading "no description" for something that might
  /// still arrive a moment later.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      // Was 130 (before that, 200 — tall enough that its bottom-edge
      // title overlapped the Continue Watching row's own label right
      // underneath). Grown again for the description text below the
      // title now that it has one; the larger bottom margin below is the
      // same "don't collide with the row label" guard scaled up with it.
      // Windows got a fixed-pixel bump on top of that in two earlier
      // passes (680px total) — reported directly as sized for a 4K
      // monitor specifically (what this was actually being tuned
      // against) and wildly too tall on a plain 1080p one, where a fixed
      // pixel count is a much bigger fraction of the whole window. A
      // fraction of the actual available height instead — scales with
      // whatever this resizable window's real size is, 4K or 1080p or
      // anything between, rather than a constant tuned for one specific
      // screen. Clamped so a very short or very tall window still gets
      // something reasonable at either end.
      height: Platform.isWindows
          ? (MediaQuery.of(context).size.height * 0.32).clamp(220.0, 480.0)
          : 210,
      margin: const EdgeInsets.only(bottom: 18),
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
      // Windows only gets the full-bleed look when a real landscape
      // [backdropUrl] is actually available — without one, the only image
      // on hand is a portrait poster/logo, and stretching that edge-to-
      // edge across this whole wide banner is the exact "hand and a desk"
      // crop bug reported directly with a screenshot the first time this
      // was tried. The poster-beside-text layout exists purely as the
      // fallback for that case. Android/TV's much shorter, fixed 210px
      // height never made a poster crop read as broken the same way, so
      // it always uses the full-bleed style (now preferring a real
      // backdrop over the poster crop when one's available).
      child:
          Platform.isWindows && backdropUrl != null && backdropUrl!.isNotEmpty
              ? _buildBackdropHeroContent(scheme, big: true)
              : Platform.isWindows
                  ? _buildWindowsHeroContent(scheme)
                  : _buildBackdropHeroContent(scheme, big: false),
    );
  }

  Widget _buildWindowsHeroContent(ColorScheme scheme) {
    return ColoredBox(
      color: Colors.grey.shade900,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            // Standard poster aspect — matches PosterCard's own ~0.70
            // width:height ratio elsewhere in this app.
            aspectRatio: 2 / 3,
            child: imageUrl != null && imageUrl!.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: imageUrl!,
                    key: ValueKey(imageUrl),
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey.shade900),
                  )
                : Container(color: Colors.grey.shade900),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color.alphaBlend(scheme.primary.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.92)),
                    Color.alphaBlend(scheme.secondary.withValues(alpha: 0.2),
                        Colors.black.withValues(alpha: 0.8)),
                  ],
                ),
              ),
              // A scrollable, not a plain Column — at the larger text
              // sizes requested directly (title 44px, description 34px),
              // a long title/description plus this box's own responsive
              // (so, sometimes short) height made a fixed Column
              // genuinely overflow its bounds on a short window instead
              // of just looking cramped. This never engages at all once
              // everything actually fits — it only ever matters at the
              // small/large-text extremes.
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                            width: 5, height: 36, color: scheme.secondary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title ?? 'Browse',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 44,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: description == null
                          ? const SizedBox.shrink()
                          : Padding(
                              key: ValueKey(description),
                              padding: const EdgeInsets.only(left: 17),
                              child: Text(
                                description!,
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                                // Requested directly: "at least 32-38" — 34
                                // sits in the middle of that range.
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 34,
                                    height: 1.35),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Full-bleed, TiviMate-style hero — a real landscape backdrop behind a
  /// bottom-anchored gradient and title/description, text sized and
  /// padded larger ([big]) on Windows' much taller banner than Android/
  /// TV's compact 210px one. Prefers [backdropUrl] (a true landscape
  /// image, safe to `BoxFit.cover`) over [imageUrl] (a portrait poster/
  /// logo, used only until this item's own backdrop has been enriched) —
  /// see [backdropUrl]'s doc comment for why cropping a portrait image
  /// this way was the actual bug this exists to avoid repeating.
  Widget _buildBackdropHeroContent(ColorScheme scheme, {required bool big}) {
    final effectiveImageUrl = (backdropUrl != null && backdropUrl!.isNotEmpty)
        ? backdropUrl
        : imageUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.grey.shade900),
        if (effectiveImageUrl != null && effectiveImageUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: effectiveImageUrl,
            key: ValueKey(effectiveImageUrl),
            fit: BoxFit.cover,
            // Same reasoning as _WhatsNewCarousel's identical fix: this
            // banner is much wider/shorter than a 16:9 backdrop, so a
            // default center-aligned cover crops the subject (almost
            // always in the upper portion of backdrop key-art) off at
            // the shoulders. Anchoring to the top also happens to put
            // the bottom-anchored title/description gradient below right
            // over the part of the image already being cropped away.
            alignment: Alignment.topCenter,
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
                    Colors.black.withValues(alpha: big ? 0.92 : 0.85)),
              ],
            ),
          ),
        ),
        Positioned(
          left: big ? 28 : 20,
          bottom: big ? 24 : 16,
          right: big ? 28 : 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                      width: big ? 5 : 4,
                      height: big ? 36 : 22,
                      color: scheme.secondary),
                  SizedBox(width: big ? 12 : 10),
                  Expanded(
                    child: Text(
                      title ?? 'Browse',
                      maxLines: big ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: big ? 44 : 22,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              SizedBox(height: big ? 12 : 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: description == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(description),
                        padding: EdgeInsets.only(left: big ? 17 : 14),
                        child: Text(
                          description!,
                          // Bottom-anchored, not filling the whole banner
                          // the way the poster-beside-text layout's own
                          // scrollable column did — fewer lines keeps the
                          // text block short enough to actually fit above
                          // the bottom edge on a shorter window instead of
                          // needing to scroll to be readable at all.
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: big ? 34 : 14,
                              height: big ? 1.35 : 1.3),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// An opt-in view for the Movies/TV Shows tabs, reached via the pinned
/// "What's New" row in the groups column (not shown by default — see
/// [_TvHomeScreenState._showWhatsNew]): the handful of titles the
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
    this.backdropUrlOf,
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

  /// A true landscape TMDB backdrop, preferred over [imageUrlOf]'s
  /// portrait poster/logo when set — see `Channel.backdropUrl`'s doc
  /// comment. Optional (not every `_WhatsNewCarousel` instantiation needs
  /// to pass one, though both current ones do) since this carousel is
  /// generic over item type and some future one might have nothing of the
  /// kind to offer.
  final String? Function(T item)? backdropUrlOf;
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
                itemBuilder: (context, i) => _buildPage(context, items[i]),
              ),
            ),
            _buildDots(context, items.length),
            _buildNavRow(context, items),
          ],
        );
      },
    );
  }

  Widget _buildPage(BuildContext context, T item) {
    final scheme = Theme.of(context).colorScheme;
    final backdrop = widget.backdropUrlOf?.call(item);
    final imageUrl = (backdrop != null && backdrop.isNotEmpty)
        ? backdrop
        : widget.imageUrlOf(item);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        decoration: BoxDecoration(
          // A static gradient instead of a blurred copy of the poster —
          // a GPU blur over a full-bleed image crashed real Fire Stick
          // hardware twice (native-level: logcat's crash buffer showed
          // "crash_dump helper failed to exec" both times, consistent
          // with a GPU-driver failure rather than a Dart exception),
          // even after restricting it to only the active PageView page.
          // This still fills the letterboxed space either side of a
          // portrait poster with something intentional instead of flat
          // grey, at effectively zero rendering cost.
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.25), Colors.grey.shade900),
              Color.alphaBlend(scheme.secondary.withValues(alpha: 0.25),
                  Colors.grey.shade900),
            ],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Color.lerp(scheme.primary, scheme.secondary, 0.5)!,
              width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: imageUrl,
                key: ValueKey(imageUrl),
                // Was `contain` (letterboxed, with the gradient above
                // filling the bars either side) — changed back to `cover`
                // per direct request, to fill this whole slide the way
                // every other poster in this app already does by default
                // (see PosterCard.fit). Not the same hazard as the
                // scrapped blur effect above: that crashed real Fire
                // Stick hardware via a GPU blur *shader* specifically —
                // plain cropping is the same ordinary operation already
                // running crash-free across every poster grid in the app.
                fit: BoxFit.cover,
                // Backdrop key-art almost always puts its actual subject
                // (a face, a figure) in the upper portion of the frame —
                // this slide's box is much wider/shorter than the 16:9
                // source image, so a default center-aligned cover crops
                // evenly off the top *and* bottom, which on a backdrop
                // this short-and-wide cuts the subject off at the
                // shoulders. Reported directly, with a screenshot: a
                // barely-recognizable torso/arm crop, not a poster.
                // Anchoring to the top keeps the subject in frame and
                // crops the (usually empty sky/background) bottom
                // instead.
                alignment: Alignment.topCenter,
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
            shaderCallback: (bounds) => LinearGradient(colors: [
              palette.primary,
              if (palette.highlight != null) palette.highlight!,
              palette.secondary,
            ]).createShader(bounds),
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
    // epgId (rawId, or a manual override), not the composite `id`
    // — see
    // PlaylistManager.knownChannelIdsFor's doc comment.
    final current = epg.getCurrentProgram(channel.epgId);
    final next = epg.getNextProgram(channel.epgId);
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

/// The Timeline Guide's description header — the programme currently
/// focused in the grid, not only the one playing. Kept separate from
/// [_ProgramDetails] rather than parameterising it: that one always
/// describes a channel's *live* programme plus what's next, while this one
/// has to describe any block the D-pad lands on, including ones hours
/// ahead, where a progress bar would be meaningless.
class _GuideNowPanel extends StatelessWidget {
  const _GuideNowPanel({
    required this.focusedChannel,
    required this.focusedProgram,
    required this.playingChannel,
    required this.epg,
  });

  final Channel? focusedChannel;
  final EpgProgram? focusedProgram;
  final Channel? playingChannel;
  final EpgService epg;

  @override
  Widget build(BuildContext context) {
    final timeFormat = DateFormat('HH:mm');
    // Whichever channel the guide is actually focused on, even if that
    // row turned out to have no programme data (focusedProgram null but
    // focusedChannel set) — only falls back to whatever's playing when
    // nothing in the guide has been focused at all yet.
    final channel = focusedChannel ?? playingChannel;
    // epgId (rawId, or a manual override), not the composite `id`
    // — see
    // PlaylistManager.knownChannelIdsFor's doc comment.
    final program = focusedProgram ??
        (channel == null
            ? null
            : epg.getCurrentProgram(channel.epgId) ??
                epg.getNextProgram(channel.epgId));

    if (channel == null && program == null) {
      return const Center(
        child: Text('Focus a program to see details',
            style: TextStyle(color: Colors.white70)),
      );
    }

    final now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(program?.title ?? channel!.name,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          if (program != null && channel != null)
            Text(channel.name,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          if (program != null) ...[
            Row(
              children: [
                Text(
                    '${timeFormat.format(program.start)} - ${timeFormat.format(program.stop)}',
                    style: const TextStyle(color: Colors.white70)),
                if (program.isNowPlaying(now)) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Builder(builder: (context) {
                      final totalMs =
                          program.stop.difference(program.start).inMilliseconds;
                      final elapsedMs =
                          now.difference(program.start).inMilliseconds;
                      final ratio = totalMs == 0
                          ? 0.0
                          : (elapsedMs / totalMs).clamp(0.0, 1.0);
                      return LinearProgressIndicator(value: ratio);
                    }),
                  ),
                ],
              ],
            ),
            if (program.description != null) ...[
              const SizedBox(height: 6),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(program.description!,
                      style: const TextStyle(color: Colors.white70)),
                ),
              ),
            ],
          ] else
            const Text('No program data available',
                style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

/// Opt-in alternate Live TV view (Settings > Theme > "Guide view") — every
/// visible channel at once on a scrollable schedule grid, instead of one
/// channel's now/next at a time. Plugs into [_buildLiveRegion] in place of
/// the normal channel-list-over-video content; the column/focus-depth
/// structure around it is unchanged (still lives at `_focusDepth == 2`).
///
/// Deliberately a *fixed* time window (from shortly before "now" to a few
/// hours after), computed once at [initState] — not an infinitely
/// scrollable calendar. `EpgService.getPrograms` already holds each
/// channel's full multi-day schedule in memory, so nothing here needs to
/// fetch anything; this only ever decides what to draw from data that's
/// already there.
class _TimelineGuide extends StatefulWidget {
  const _TimelineGuide(
      {super.key,
      required this.channels,
      required this.epg,
      required this.onOpen,
      required this.onFocusChanged,
      required this.onShowOptions,
      required this.filterFocusNode,
      required this.onFilterToggle,
      this.onReachedTop,
      this.onWindowStale});

  final List<Channel> channels;
  final EpgService epg;
  final void Function(Channel channel) onOpen;
  final void Function(Channel channel, EpgProgram? program) onFocusChanged;

  /// Hold-Select on a block — see [_TvHomeScreenState._showChannelOptions].
  final void Function(Channel channel) onShowOptions;

  /// Backs the filter toggle button rendered above the channel column
  /// (`_TimelineFilterButton`). A dedicated node, not shared with the
  /// filter field's own — see
  /// `_TvHomeScreenState._timelineFilterButtonFocusNode`'s doc comment
  /// for why that sharing was tried and abandoned.
  final FocusNode filterFocusNode;

  /// Select on the filter button — see
  /// `_TvHomeScreenState._openTimelineFilter`.
  final VoidCallback onFilterToggle;

  /// Up pressed while already at the top row ([_TimelineGuideState
  /// .moveVertical]'s `targetRow < 0` case) — hands focus to whichever of
  /// the button/field is actually showing instead of the previous no-op.
  /// Confirmed safe to repurpose: nothing else ever lived above the guide
  /// for Up to reach (the preview box there is deliberately
  /// `ExcludeFocus`ed).
  final VoidCallback? onReachedTop;

  /// This instance's fixed [_TimelineGuideState._windowStart]/`_windowEnd`
  /// has gone (or is about to go) stale — see that field's own doc
  /// comment for why. The parent's only real fix is discarding this whole
  /// widget/State and mounting a fresh one (a new key), which is outside
  /// what this State can do to itself.
  final VoidCallback? onWindowStale;

  @override
  State<_TimelineGuide> createState() => _TimelineGuideState();
}

class _TimelineGuideState extends State<_TimelineGuide> with RouteAware {
  static const double _pixelsPerMinute = 6;
  static const Duration _windowBefore = Duration(hours: 1);
  static const Duration _windowAfter = Duration(hours: 5);
  static const double _rowHeight = 64;
  static const double _channelColumnWidth = 160;
  static const double _rulerHeight = 32;

  /// How often the "now" line (and every row's now/later styling) redraws
  /// — a `setState` tick, not a re-fetch of anything. Cheap enough that
  /// this doesn't need the same tight care as the actual data-loading
  /// timers elsewhere in this file, but still paused while covered (see
  /// [didPushNext]/[didPopNext]) on the same "don't run a timer for a
  /// screen nobody can see" principle as [_WhatsNewCarouselState].
  static const Duration _nowTickInterval = Duration(seconds: 30);

  /// Fixed for this State's whole lifetime, computed once in [initState]
  /// from whatever "now" was at that moment — every pixel offset, scroll
  /// position, and registered block's start/end in this whole class is
  /// relative to this. That's fine for how long a *typical* visit to the
  /// guide lasts, but this screen can legitimately be left open/playing
  /// for hours (reported directly: left the TV running, came back to the
  /// guide showing a "now" position hours in the past — the red "now"
  /// line had run clean off the right edge of this fixed window, with
  /// nothing re-deriving it because [_startNowTimer]'s own tick only
  /// ever `setState`s this same State, never rebuilds these `late final`
  /// fields). [_checkWindowStale] is this class's own half of the fix —
  /// it can't re-window itself in place (every scroll position, focused
  /// block, and cursor slot is keyed to the old one), so it just tells
  /// [_TimelineGuide.onWindowStale] to throw this whole widget away and
  /// mount a fresh one instead (the parent does that by swapping in a new
  /// `GlobalKey` for it), which gets a correctly fresh window for free
  /// through the exact same [initState] path a first-ever open takes.
  late final DateTime _windowStart;
  late final DateTime _windowEnd;
  late final double _totalWidth;
  bool _staleReported = false;

  // Two independent controller pairs (ruler mirrors the grid horizontally,
  // the channel-label column mirrors it vertically) rather than sharing
  // one `ScrollController` across scroll views — a single controller can
  // only usefully drive `jumpTo` across multiple attachments, actual drag
  // gestures on one view never move the others. Only the grid itself is
  // interactive; the ruler and label column just mirror it via listeners,
  // the same "one side drives, the other follows" shape as everywhere
  // else two things need to move in lockstep in this app.
  final ScrollController _gridHScroll = ScrollController();
  final ScrollController _rulerHScroll = ScrollController();
  final ScrollController _gridVScroll = ScrollController();
  final ScrollController _labelVScroll = ScrollController();

  /// Wraps the programme grid (see [build]) so [didUpdateWidget] can check
  /// whether focus is genuinely, currently inside the grid right now —
  /// `.hasFocus` is true if *any* block anywhere inside currently has it.
  /// Deliberately not inferred from [_focusedRowIndex] (tried first): that
  /// field only records the *last* row that was ever focused and is never
  /// cleared on blur, so once the guide had been browsed even once, it
  /// stayed truthy forever after — reported directly: opening the
  /// Timeline filter and typing stole focus back into the guide on every
  /// single keystroke, not just the first, because each wrongly-triggered
  /// `focusEntry()` call below re-set `_focusedRowIndex` itself, making
  /// the *next* keystroke's check true all over again.
  final FocusScopeNode _gridFocusScope =
      FocusScopeNode(debugLabel: 'timeline-grid');
  Timer? _nowTimer;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _windowStart = now.subtract(_windowBefore);
    _windowEnd = now.add(_windowAfter);
    _totalWidth =
        _windowEnd.difference(_windowStart).inMinutes * _pixelsPerMinute;
    _gridHScroll.addListener(_mirrorRuler);
    _gridVScroll.addListener(_mirrorLabels);
    _startNowTimer();
    // Opens scrolled to "now", not the window's start — matching what the
    // user actually wants to see first. jumpTo, not animateTo: an
    // animated scroll on a real device was confirmed elsewhere in this
    // file as the direct cause of an ANR-length freeze on a long list;
    // that lesson applies here just as much.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _gridHScroll.hasClients) {
        _gridHScroll.jumpTo(_xFor(_floorToSlot(DateTime.now()))
            .clamp(0.0, _gridHScroll.position.maxScrollExtent));
      }
    });
  }

  @override
  void didUpdateWidget(_TimelineGuide old) {
    super.didUpdateWidget(old);
    final oldGroup = old.channels.isEmpty ? null : old.channels.first.group;
    final newGroup =
        widget.channels.isEmpty ? null : widget.channels.first.group;
    // Length is also checked, not just group — the Timeline filter bar
    // narrows/widens this same group's own channel list without changing
    // its group at all, and would otherwise leave _focusedRowIndex/
    // _rowBlocks pointing at rows that no longer exist (or no longer mean
    // what they used to) in the filtered list.
    if (oldGroup == newGroup && old.channels.length == widget.channels.length) {
      return;
    }
    // Whether the guide's grid genuinely holds focus *right now* — not
    // whether _focusedRowIndex happens to be non-null, which only records
    // the *last* row ever focused and is never cleared on blur. That
    // first version caused exactly the bug this comment used to describe
    // fixing, except it kept happening on *every* keystroke, not just the
    // first: once the guide had been browsed even once this session (an
    // entirely normal thing to do before opening the filter),
    // _focusedRowIndex stayed non-null forever, so the very first
    // keystroke still wrongly called focusEntry() below — which itself
    // re-set _focusedRowIndex via the normal focus-tracking callback,
    // making the *next* keystroke's stale check true all over again, each
    // time. _gridFocusScope.hasFocus reports the real, current state
    // instead (true only while a block somewhere in the grid actually has
    // focus this instant), so it can't fall out of sync like that.
    final hadRowFocus = _gridFocusScope.hasFocus;
    // A different group's channel list was swapped in (not just the same
    // group's own content refreshing) — reset scroll/focus memory instead
    // of carrying over wherever the *previous* group had been scrolled
    // to. Reported directly: picking a new group from the groups column
    // left the guide scrolled down to roughly how far the old one had
    // been browsed, landing on an unrelated channel instead of the new
    // group's first one. jumpTo, not animateTo — same ANR-avoidance
    // reasoning as everywhere else in this file.
    if (_gridVScroll.hasClients) _gridVScroll.jumpTo(0);
    _focusedRowIndex = null;
    _focusedProgram = null;
    _cursorSlot = null;
    if (!hadRowFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusEntry();
    });
  }

  void _mirrorRuler() {
    if (_rulerHScroll.hasClients) _rulerHScroll.jumpTo(_gridHScroll.offset);
  }

  void _mirrorLabels() {
    if (_labelVScroll.hasClients) _labelVScroll.jumpTo(_gridVScroll.offset);
  }

  void _startNowTimer() {
    _nowTimer?.cancel();
    _nowTimer = Timer.periodic(_nowTickInterval, (_) {
      if (!mounted) return;
      _checkWindowStale();
      setState(() {});
    });
  }

  /// See [_windowStart]'s doc comment. Triggered with an hour of margin
  /// before "now" would actually leave the window — not right at the
  /// edge — so the remount happens while everything still looks fine,
  /// never as a visible jump cutting off whatever's on screen. Reports
  /// once per State (guarded by [_staleReported]): the parent's remount
  /// destroys this whole State shortly after anyway, and without the
  /// guard every 30s tick between here and that remount actually landing
  /// would call it again for nothing.
  void _checkWindowStale() {
    if (_staleReported) return;
    if (!DateTime.now()
        .isBefore(_windowEnd.subtract(const Duration(hours: 1)))) {
      _staleReported = true;
      widget.onWindowStale?.call();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => _nowTimer?.cancel();

  @override
  void didPopNext() {
    // Checked immediately, not just left to the next 30s tick — covering
    // fullscreen (this guide sitting covered, hence this timer paused)
    // for long enough to go stale itself.
    _checkWindowStale();
    _startNowTimer();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _nowTimer?.cancel();
    _gridHScroll.removeListener(_mirrorRuler);
    _gridVScroll.removeListener(_mirrorLabels);
    _gridHScroll.dispose();
    _rulerHScroll.dispose();
    _gridVScroll.dispose();
    _labelVScroll.dispose();
    _gridFocusScope.dispose();
    super.dispose();
  }

  double _xFor(DateTime t) =>
      t.difference(_windowStart).inMinutes * _pixelsPerMinute;

  /// Scrolls the grid vertically only as far as needed to bring
  /// [rowIndex] fully into view — flush against whichever edge it crossed,
  /// never re-aligned to the top. Runs before each block's own
  /// `Scrollable.ensureVisible`, whose default `alignment: 0.0` otherwise
  /// snapped the newly-focused row to the viewport's top on every step
  /// past the bottom edge: a whole page-flip per Down press, reported on
  /// real hardware as "the guide moves up instead of the selector going
  /// down". Once this has run, that call's vertical half is a no-op and
  /// it only ever handles the horizontal axis.
  void _ensureRowVisible(int rowIndex) {
    if (!_gridVScroll.hasClients) return;
    final top = rowIndex * _rowHeight;
    final bottom = top + _rowHeight;
    final pos = _gridVScroll.position;
    final viewTop = pos.pixels;
    final viewBottom = viewTop + pos.viewportDimension;
    if (top < viewTop) {
      _gridVScroll.jumpTo(top);
    } else if (bottom > viewBottom) {
      _gridVScroll.jumpTo(
          (bottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent));
    }
  }

  // Every currently-mounted programme block registers its own FocusNode
  // here on mount (see _ProgramBlockState.initState/dispose) — lets
  // moveVertical/restoreFocusToChannel below jump straight to a specific
  // block instead of trusting Flutter's default directional traversal.
  final Map<int, List<({DateTime start, DateTime end, FocusNode node})>>
      _rowBlocks = {};

  void _registerBlock(
      int rowIndex, DateTime start, DateTime end, FocusNode node) {
    (_rowBlocks[rowIndex] ??= []).add((start: start, end: end, node: node));
  }

  void _unregisterBlock(int rowIndex, FocusNode node) {
    _rowBlocks[rowIndex]?.removeWhere((b) => b.node == node);
  }

  /// Whichever block last took focus, as a row + the programme itself
  /// (not a fixed moment in time) — [moveVertical] derives its actual
  /// reference moment fresh, on every call, via [_referenceTime]. Two
  /// earlier attempts at a fixed reference both broke on a currently-
  /// airing programme that started well before "now" (a long block —
  /// its own `start` landed Down/Up on whatever aired back then instead
  /// of "now"; clamping to the scroll position instead landed on
  /// whatever a since-changed scroll offset happened to show, which
  /// drifted the *other* direction once `Scrollable.ensureVisible`
  /// re-aligned it for an over-wide block). Neither a stored time survives
  /// contact with "the wall clock keeps advancing while a block sits
  /// focused" anyway. [null] for a placeholder block with no real
  /// programme.
  int? _focusedRowIndex;
  EpgProgram? _focusedProgram;

  void _trackFocus(int rowIndex, EpgProgram? program) {
    _focusedRowIndex = rowIndex;
    _focusedProgram = program;
    if (_guideDrivenFocus) {
      _guideDrivenFocus = false;
      return;
    }
    // Focus arrived from outside the guide's own Up/Down/Left/Right
    // (a tap, or default traversal): adopt that block's column so the
    // next Up/Down stays on it.
    final now = DateTime.now();
    if (program == null || program.isNowPlaying(now)) {
      _cursorSlot = null;
    } else {
      final start =
          program.start.isBefore(_windowStart) ? _windowStart : program.start;
      _cursorSlot = _floorToSlot(start);
    }
  }

  /// The 30-minute column Left/Right have stepped to — the slot's start
  /// time. Null means the live slot (follows the clock; "now"). Left/
  /// Right step exactly one slot per press instead of hopping to the
  /// neighbouring programme, which for a long one could be an hour or
  /// more away (reported directly: "only move the guide by 30 min
  /// blocks, not the end of your current channel"). Up/Down then keep
  /// whatever column this names.
  DateTime? _cursorSlot;

  static const Duration _slot = Duration(minutes: 30);

  DateTime _floorToSlot(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % 30);

  /// The moment to look for blocks at, for [slot] (null = live/"now").
  DateTime _timeForSlot(DateTime? slot) {
    final now = DateTime.now();
    return (slot == null || slot == _floorToSlot(now)) ? now : slot;
  }

  /// Steps the guide one 30-minute slot left (-1) or right (+1): scrolls
  /// the view by that amount and focuses whichever block in the current
  /// row covers the new slot (which may be the very same long block —
  /// then only the view moves, and the sticky label keeps its title
  /// readable). Returns false when there's nowhere further that way (the
  /// edge of the guide's time window), so the caller can fall back to
  /// its own edge behaviour.
  bool moveHorizontal(int dir) {
    final rowIndex = _focusedRowIndex;
    if (rowIndex == null) return false;
    final now = DateTime.now();
    final program = _focusedProgram;
    final current = _cursorSlot ??
        _floorToSlot((program == null || program.isNowPlaying(now))
            ? now
            : (program.start.isBefore(_windowStart)
                ? _windowStart
                : program.start));
    final target = current.add(_slot * dir);
    if (target.isBefore(_floorToSlot(_windowStart)) ||
        !target.isBefore(_windowEnd)) {
      return false;
    }
    final live = target == _floorToSlot(now);
    _cursorSlot = live ? null : target;
    if (_gridHScroll.hasClients) {
      // The slot's own start, live slot included — aligning the live
      // one to "now" instead cut the current block off at the edge
      // (reported directly: it should show the whole 9:00-9:30 block).
      _gridHScroll.jumpTo(
          _xFor(target).clamp(0.0, _gridHScroll.position.maxScrollExtent));
    }
    final blocks = _rowBlocks[rowIndex];
    final best = blocks == null
        ? null
        : _bestBlockFor(blocks, _timeForSlot(_cursorSlot));
    if (best != null) {
      _focusBlock(best.node);
    }
    return true;
  }

  /// "Now" for a programme that's actually airing right now (recomputed
  /// fresh, never the stale value from whenever focus first landed on
  /// it) — that's the case that actually matters, since it's what makes
  /// Down/Up from a long "now playing" block land on the *other*
  /// channel's own currently-airing block instead of on whatever aired
  /// back when the focused block's own (possibly hours-old) start time
  /// was. A block deliberately drilled into via Left/Right (a future or
  /// past slot, not currently airing) instead keeps its own start —
  /// staying on that same time column is exactly what's wanted there.
  ///
  /// The time column is owned by [_cursorSlot] alone (null = live/"now"),
  /// never re-derived from whichever block a vertical move happened to
  /// land on. Deriving it from the landed block's own `start` made the
  /// column drift: landing on a row with a gap at "now" fell back to the
  /// nearest block (possibly hours away), and the *next* Up/Down then
  /// followed that block's start instead of the column the user was on.
  /// A focus that didn't come from the guide's own moves (touch, default
  /// traversal) re-seeds the column in [_trackFocus] instead.
  DateTime _referenceTime(EpgProgram? program) => _timeForSlot(_cursorSlot);

  /// Set right before the guide itself calls `requestFocus`, so
  /// [_trackFocus] can tell a guide-driven focus change (keep the column)
  /// from an external one (adopt the block's column). Cleared by the next
  /// [_trackFocus] or, if focus didn't actually change (already on that
  /// node), after the frame.
  bool _guideDrivenFocus = false;

  void _focusBlock(FocusNode node) {
    _guideDrivenFocus = true;
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _guideDrivenFocus = false;
    });
  }

  ({DateTime start, DateTime end, FocusNode node})? _bestBlockFor(
      List<({DateTime start, DateTime end, FocusNode node})> blocks,
      DateTime time) {
    if (blocks.isEmpty) return null;
    for (final b in blocks) {
      if (!b.start.isAfter(time) && b.end.isAfter(time)) return b;
    }
    // A gap at [time]: nearest block by distance to its *interval* (its
    // start or its end, whichever is closer) — not just its start, which
    // preferred a block hours ahead over the one that ended a minute ago.
    Duration gap(({DateTime start, DateTime end, FocusNode node}) b) =>
        time.isBefore(b.start)
            ? b.start.difference(time)
            : time.difference(b.end);
    return blocks.reduce((a, c) => gap(c) < gap(a) ? c : a);
  }

  /// Explicit Up/Down dispatch, bound in [_TvHomeScreenState.build] in
  /// place of default directional traversal. Default traversal picks the
  /// nearest widget by on-screen rect overlap, which reliably picks the
  /// wrong block once rows have very differently-sized programmes:
  /// focused on a channel's 2-hour block and pressing Down into a row
  /// full of 30-minute ones landed near the *end* of that 2-hour span
  /// instead of "now" — reported directly on real hardware. This tracks
  /// the actual moment in time the guide is "looking at" via
  /// [_trackFocus] and finds whichever block in the target row covers
  /// that same moment, so moving between rows stays on the same time
  /// column instead of following block geometry.
  void moveVertical(int delta) {
    final rowIndex = _focusedRowIndex;
    if (rowIndex == null) return;
    final targetRow = rowIndex + delta;
    if (targetRow < 0) {
      widget.onReachedTop?.call();
      return;
    }
    if (targetRow >= widget.channels.length) return;
    final time = _referenceTime(_focusedProgram);
    _ensureRowVisible(targetRow);
    final blocks = _rowBlocks[targetRow];
    final best = blocks == null ? null : _bestBlockFor(blocks, time);
    if (best != null) {
      _focusBlock(best.node);
      return;
    }
    // Target row wasn't already built (a rarer case for a single-row
    // move than for restoreFocusToChannel below, but possible right
    // after the guide first opens) — give layout one frame to build it
    // from the jump above, then retry once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final retry = _rowBlocks[targetRow];
      final retryBest = retry == null ? null : _bestBlockFor(retry, time);
      if (retryBest != null) _focusBlock(retryBest.node);
    });
  }

  /// Called when focus is moving into the guide from the groups column
  /// (see [_TvHomeScreenState._moveColumnFocus]): focuses the block at the
  /// current time column, in the row last focused (or the top visible
  /// row) — instead of letting the scope land on the leftmost block of
  /// the first row, which dragged the view back to the start of the
  /// window (reported directly). Returns false if there's nothing to
  /// focus, so the caller can fall back to plain scope focus.
  bool focusEntry() {
    if (widget.channels.isEmpty) return false;
    var rowIndex = _focusedRowIndex;
    if (rowIndex == null || rowIndex >= widget.channels.length) {
      rowIndex = _gridVScroll.hasClients
          ? (_gridVScroll.offset / _rowHeight)
              .ceil()
              .clamp(0, widget.channels.length - 1)
          : 0;
    }
    final row = rowIndex;
    final time = _referenceTime(_focusedProgram);
    _ensureRowVisible(row);
    final blocks = _rowBlocks[row];
    final best = blocks == null ? null : _bestBlockFor(blocks, time);
    if (best != null) {
      _focusBlock(best.node);
      return true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final retry = _rowBlocks[row];
      final r = retry == null ? null : _bestBlockFor(retry, time);
      if (r != null) _focusBlock(r.node);
    });
    return true;
  }

  /// Called after backing out of fullscreen (see
  /// [_TvHomeScreenState.didPopNext]) — the guide has no equivalent of
  /// the plain live list's dedicated "currently playing" FocusNode
  /// (`_currentChannelFocusNode`), so without this, leaving fullscreen
  /// just restored whatever was focused before Select was pressed, not
  /// the channel actually playing. Reported directly as "brings us back
  /// to where we last were, not the current channel."
  void restoreFocusToChannel(String channelId) {
    final rowIndex = widget.channels.indexWhere((c) => c.id == channelId);
    if (rowIndex < 0) return;
    _ensureRowVisible(rowIndex);
    // Always deferred, not tried synchronously first — unlike
    // moveVertical's single-row step, this jump can be arbitrarily far
    // from wherever the guide happened to be scrolled, so the target row
    // is very unlikely to already be built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final blocks = _rowBlocks[rowIndex];
      final best =
          blocks == null ? null : _bestBlockFor(blocks, DateTime.now());
      if (best == null) return;
      _cursorSlot = null;
      // Back to the current time, not wherever the focused block's own
      // left edge is — a long programme that began earlier used to drag
      // the view back to its start on return (reported directly: "brings
      // us back to the time the channel started, not the current time
      // block"). Same slot-aligned position the guide opens on.
      if (_gridHScroll.hasClients) {
        _gridHScroll.jumpTo(_xFor(_floorToSlot(DateTime.now()))
            .clamp(0.0, _gridHScroll.position.maxScrollExtent));
      }
      _focusBlock(best.node);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.channels.isEmpty) {
      return const Center(child: Text('No channels found.'));
    }
    final nowX = _xFor(DateTime.now()).clamp(0.0, _totalWidth);
    // Distinguishes "still fetching, give it a moment" from "this channel
    // genuinely has none" for a row with nothing to show — reported on
    // real hardware as every row rendering completely empty (nothing to
    // focus, so Down couldn't even reach past it) during the window
    // before EPG had loaded at all.
    final epgLoading = widget.epg.isLoading || widget.epg.lastUpdated == null;
    return Column(
      children: [
        SizedBox(
          height: _rulerHeight,
          child: Row(
            children: [
              _TimelineFilterButton(
                focusNode: widget.filterFocusNode,
                onPressed: widget.onFilterToggle,
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _rulerHScroll,
                    physics: const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: _totalWidth,
                      child: _TimeRuler(
                          windowStart: _windowStart,
                          windowEnd: _windowEnd,
                          pixelsPerMinute: _pixelsPerMinute),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _channelColumnWidth,
                child: ClipRect(
                  child: ListView.builder(
                    controller: _labelVScroll,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: widget.channels.length,
                    itemExtent: _rowHeight,
                    itemBuilder: (context, i) =>
                        _ChannelLabel(channel: widget.channels[i]),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: FocusScope(
                  node: _gridFocusScope,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _gridHScroll,
                    child: SizedBox(
                      width: _totalWidth,
                      height: widget.channels.length * _rowHeight,
                      child: Stack(
                        children: [
                          ListView.builder(
                            controller: _gridVScroll,
                            itemCount: widget.channels.length,
                            itemExtent: _rowHeight,
                            itemBuilder: (context, i) => _TimelineRow(
                              rowIndex: i,
                              channel: widget.channels[i],
                              programs: widget.epg
                                  .getPrograms(widget.channels[i].epgId),
                              windowStart: _windowStart,
                              windowEnd: _windowEnd,
                              pixelsPerMinute: _pixelsPerMinute,
                              onOpen: () => widget.onOpen(widget.channels[i]),
                              onShowOptions: () =>
                                  widget.onShowOptions(widget.channels[i]),
                              ensureRowVisible: _ensureRowVisible,
                              onFocusChanged: widget.onFocusChanged,
                              onFocusTracked: _trackFocus,
                              onRegisterBlock: _registerBlock,
                              onUnregisterBlock: _unregisterBlock,
                              hScroll: _gridHScroll,
                              epgLoading: epgLoading,
                            ),
                          ),
                          Positioned(
                            left: nowX,
                            top: 0,
                            bottom: 0,
                            child: const IgnorePointer(
                              child: SizedBox(
                                width: 2,
                                child: ColoredBox(color: Colors.redAccent),
                              ),
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
      ],
    );
  }
}

/// Hour/half-hour tick labels across the guide's fixed time window —
/// visually paired with the grid via [_TimelineGuideState._mirrorRuler],
/// not an independently-scrolled view of its own.
class _TimeRuler extends StatelessWidget {
  const _TimeRuler(
      {required this.windowStart,
      required this.windowEnd,
      required this.pixelsPerMinute});

  final DateTime windowStart;
  final DateTime windowEnd;
  final double pixelsPerMinute;

  @override
  Widget build(BuildContext context) {
    final timeFormat = DateFormat('h:mm a');
    final firstTick = DateTime(
            windowStart.year,
            windowStart.month,
            windowStart.day,
            windowStart.hour,
            windowStart.minute - windowStart.minute % 30)
        .add(const Duration(minutes: 30));
    final ticks = <DateTime>[
      for (var t = firstTick;
          t.isBefore(windowEnd);
          t = t.add(const Duration(minutes: 30)))
        t,
    ];
    return Stack(
      children: [
        for (final tick in ticks)
          Positioned(
            left: tick.difference(windowStart).inMinutes * pixelsPerMinute,
            top: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(timeFormat.format(tick),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            ),
          ),
      ],
    );
  }
}

/// Sits above the channel column, where [_TimelineGuideState]'s ruler row
/// previously had nothing but a bare spacer — opens
/// [_TvHomeScreenState._buildTimelineFilterBar] to narrow a large group's
/// channel list by name. Its own [FocusNode] is handed in by the parent
/// (see [_TimelineGuide.filterFocusNode]'s doc comment for why it's shared
/// with the filter text field rather than owned here).
class _TimelineFilterButton extends StatefulWidget {
  const _TimelineFilterButton(
      {required this.focusNode, required this.onPressed});

  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  State<_TimelineFilterButton> createState() => _TimelineFilterButtonState();
}

class _TimelineFilterButtonState extends State<_TimelineFilterButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Every palette now gets the same contour + diagonal sheen as
    // `_SelectableRow`/`_GroupRow` for this exact focus state — see
    // `_SelectableRow`'s doc comment for the full story. This button was
    // the one spot the original fix never reached, confirmed directly on
    // real hardware.
    return SizedBox(
      width: _TimelineGuideState._channelColumnWidth,
      height: _TimelineGuideState._rulerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        // HoldToActivate, not a plain InkWell — reported directly: Select
        // did nothing at all here, on real hardware, since this button's
        // very first version (even the plain-TextField one, before any
        // keyboard work). This is the exact already-solved problem
        // _ProgramBlockState's own identical wrapping exists for: this
        // app's remotes send a variety of different "Select"-equivalent
        // keys (select/enter/numpadEnter/gameButtonA) depending on the
        // device, and a plain InkWell's default keyboard activation
        // doesn't recognize all of them — HoldToActivate checks every
        // variant explicitly instead of relying on that default.
        child: HoldToActivate(
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: Focus(
            focusNode: widget.focusNode,
            onFocusChange: (f) => setState(() => _focused = f),
            child: InkWell(
              // requestFocus() explicitly, not left to InkWell's own tap
              // handling — confirmed elsewhere in this file
              // (_ProgramBlockState) that a tap does NOT reliably focus its
              // wrapping Focus node on its own here.
              onTap: () {
                widget.focusNode.requestFocus();
                widget.onPressed();
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                decoration: BoxDecoration(
                  color: _focused ? null : Colors.white.withValues(alpha: 0.06),
                  gradient: _focused
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.black,
                            Color.lerp(
                                Colors.black, scheme.primaryContainer, 0.4)!,
                            Colors.black,
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        )
                      : null,
                  border: Border.all(
                      color: _focused ? scheme.primary : Colors.white24),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                // `scheme.tertiary` — a dedicated icon/symbol-glyph
                // accent, separate from the border/gradient accent
                // (`scheme.primary`) — see `buildPaletteColorScheme`'s
                // own doc comment for why (Habs: white contour, blue
                // icons).
                child: Icon(Icons.search,
                    size: 16,
                    color: _focused ? scheme.tertiary : Colors.white70),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A D-pad-navigable on-screen keyboard for the Timeline guide's channel
/// filter on real TV/remote-control devices — see
/// `_TvHomeScreenState._buildTimelineFilterBar`'s doc comment for why this
/// exists instead of a `TextField` + system keyboard there (confirmed
/// unreliable on real hardware even after fixing a genuine focus-steal
/// bug that was also contributing to it). Modeled directly on
/// `lib/widgets/pin_pad.dart`'s already-proven pattern: explicit
/// `CallbackShortcuts` row/column arithmetic (never default Flutter
/// traversal — see CLAUDE.md's D-pad rule) via [_moveFocus], and no real
/// `TextField` anywhere in the grid at all, which also sidesteps Fire
/// OS's "TextField swallows Back while focused" bug (same reasoning
/// `pin_pad.dart`'s own doc comment gives for why it avoids one too).
class _TimelineVirtualKeyboard extends StatelessWidget {
  const _TimelineVirtualKeyboard({
    required this.scope,
    required this.nodes,
    required this.onChar,
    required this.onSpace,
    required this.onBackspace,
    required this.onClose,
    required this.onExitDown,
  });

  /// A-Z, 0-9, space/backspace/close — three uniform rows of 13 so the
  /// row/column arithmetic in [_moveFocus] stays as simple as
  /// `pin_pad.dart`'s own (no ragged rows to special-case, same reason
  /// its 4x3 grid is uniform).
  static const keyRows = [
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M'],
    ['N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'],
    [
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', //
      'space', 'back', 'close',
    ],
  ];

  /// Reports true if *any* key in the grid currently has focus — see its
  /// own field doc comment in `_TvHomeScreenState` for why the Up/Down
  /// focus-coordination with the guide needs this instead of a single
  /// node's `hasFocus`.
  final FocusScopeNode scope;

  /// Index-matched to [keyRows]; owned by `_TvHomeScreenState` (not this
  /// widget) so "focus the first key" can be requested from outside
  /// (opening the filter, or Up from the guide's top row) without a
  /// `GlobalKey`/`State` reference into this widget.
  final List<List<FocusNode>> nodes;

  final void Function(String char) onChar;
  final VoidCallback onSpace;
  final VoidCallback onBackspace;
  final VoidCallback onClose;

  /// Down from the bottom row — exits into the (now live-filtered) guide
  /// below instead of clamping, via the same `focusEntry()` path Up from
  /// the guide's top row already uses to come back here. See this
  /// widget's instantiation site for the exact callback wiring.
  final VoidCallback onExitDown;

  void _moveFocus(int rowDelta, int colDelta) {
    final current = FocusManager.instance.primaryFocus;
    for (var r = 0; r < nodes.length; r++) {
      for (var c = 0; c < nodes[r].length; c++) {
        if (nodes[r][c] != current) continue;
        final nr = r + rowDelta;
        if (nr >= nodes.length) {
          onExitDown();
          return;
        }
        final clampedR = nr.clamp(0, nodes.length - 1);
        final clampedC = (c + colDelta).clamp(0, nodes[clampedR].length - 1);
        nodes[clampedR][clampedC].requestFocus();
        return;
      }
    }
  }

  void _handleKey(String value) {
    switch (value) {
      case 'space':
        onSpace();
      case 'back':
        onBackspace();
      case 'close':
        onClose();
      default:
        onChar(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveFocus(-1, 0),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveFocus(1, 0),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _moveFocus(0, -1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _moveFocus(0, 1),
      },
      child: FocusScope(
        node: scope,
        child: Column(
          children: [
            for (var r = 0; r < keyRows.length; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var c = 0; c < keyRows[r].length; c++)
                      Expanded(
                        child: _TimelineKeyboardKey(
                          focusNode: nodes[r][c],
                          label: keyRows[r][c],
                          onPressed: () => _handleKey(keyRows[r][c]),
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
}

class _TimelineKeyboardKey extends StatefulWidget {
  const _TimelineKeyboardKey(
      {required this.focusNode, required this.label, required this.onPressed});

  final FocusNode focusNode;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_TimelineKeyboardKey> createState() => _TimelineKeyboardKeyState();
}

class _TimelineKeyboardKeyState extends State<_TimelineKeyboardKey> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = switch (widget.label) {
      'space' => 'Space',
      'back' => '⌫',
      'close' => '✕',
      final c => c,
    };
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: _focused ? scheme.primary : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        // HoldToActivate, not a plain InkWell's own keyboard activation —
        // see _TimelineFilterButton's identical doc comment for why: a
        // plain InkWell doesn't reliably respond to every "Select"-
        // equivalent key this app's real remotes send.
        child: HoldToActivate(
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: InkWell(
            // requestFocus() explicitly, not left to InkWell's own tap
            // handling — same reasoning as _TimelineFilterButton/
            // _ProgramBlockState elsewhere in this file.
            focusNode: widget.focusNode,
            onFocusChange: (f) => setState(() => _focused = f),
            onTap: () {
              widget.focusNode.requestFocus();
              widget.onPressed();
            },
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: Text(
                display,
                style: TextStyle(
                  fontSize: widget.label == 'space' ? 10 : 13,
                  fontWeight: FontWeight.w600,
                  color: _focused ? scheme.onPrimary : Colors.white70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The left column's per-row channel identity — purely informational, not
/// itself focusable; D-pad focus lives entirely on the programme blocks in
/// [_TimelineRow], same as the plain channel list never puts focus on a
/// row's logo.
class _ChannelLabel extends StatelessWidget {
  const _ChannelLabel({required this.channel});

  final Channel channel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _TimelineGuideState._rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: channel.logoUrl!,
                      fit: BoxFit.contain,
                      errorWidget: (_, __, ___) => const Icon(Icons.tv))
                  : const Icon(Icons.tv),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One channel's programmes for the visible window, each a real
/// [Positioned] focusable block sized to its actual duration — no nested
/// scrollable per row; the shared horizontal offset in
/// [_TimelineGuideState] already provides one. Left/Right and Up/Down
/// between blocks use plain default Flutter focus traversal (each block
/// is its own [Focus]/`InkWell`, no per-row [FocusScope] — nesting one per
/// row was tried elsewhere in this file for a similar row-of-rows layout
/// and confirmed to break Up/Down between rows entirely).
class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.rowIndex,
    required this.channel,
    required this.programs,
    required this.windowStart,
    required this.windowEnd,
    required this.pixelsPerMinute,
    required this.onOpen,
    required this.onShowOptions,
    required this.ensureRowVisible,
    required this.onFocusChanged,
    required this.onFocusTracked,
    required this.onRegisterBlock,
    required this.onUnregisterBlock,
    required this.hScroll,
    required this.epgLoading,
  });

  final int rowIndex;
  final Channel channel;
  final List<EpgProgram> programs;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pixelsPerMinute;
  final VoidCallback onOpen;
  final VoidCallback onShowOptions;
  final void Function(int rowIndex)? ensureRowVisible;
  final void Function(Channel channel, EpgProgram? program)? onFocusChanged;

  /// Feeds [_TimelineGuideState._trackFocus] — see its own doc comment.
  final void Function(int rowIndex, EpgProgram? program)? onFocusTracked;
  final void Function(
          int rowIndex, DateTime start, DateTime end, FocusNode node)
      onRegisterBlock;
  final void Function(int rowIndex, FocusNode node) onUnregisterBlock;

  /// Shared with every block in the grid — drives the sticky-label fix
  /// in [_ProgramBlockState] (each block reacts to the same horizontal
  /// scroll position independently).
  final ScrollController hScroll;

  /// Whether the EPG fetch hasn't completed at all yet — vs. having
  /// completed with genuinely nothing for this channel (a duplicate with
  /// no EPG mapping, commonly). Only changes which placeholder label an
  /// empty row shows below; doesn't affect real programme blocks.
  final bool epgLoading;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Deduped by (start, stop) — a provider/merged-EPG duplicate entry
    // (two programmes with identical start/stop for the same channel) used
    // to reach the Stack below with two equally-keyed Positioned children,
    // which Flutter's own key-uniqueness check throws on (reported live:
    // "Duplicate keys found", repeating on every rebuild of that channel's
    // row and corrupting the guide's element tree badly enough to cascade
    // into unrelated assertion failures elsewhere). First occurrence wins
    // — rendering both would just be two fully overlapping blocks anyway.
    final seenSlots = <String>{};
    final visible = programs
        .where(
            (p) => p.stop.isAfter(windowStart) && p.start.isBefore(windowEnd))
        .where((p) => seenSlots.add(
            '${p.start.millisecondsSinceEpoch}-${p.stop.millisecondsSinceEpoch}'))
        .toList();
    if (visible.isEmpty) {
      // A row with nothing to show used to render a totally empty Stack
      // — no focusable child at all, so the D-pad had nowhere to land on
      // that channel and Down couldn't move past it ("stuck in the black
      // void", reported on real hardware). One full-window placeholder
      // block keeps every row focusable regardless of EPG state, and
      // still opens the channel on Select like a real block would.
      final totalWidth =
          windowEnd.difference(windowStart).inMinutes * pixelsPerMinute;
      return SizedBox(
        height: _TimelineGuideState._rowHeight,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: _ProgramBlock(
            program: null,
            placeholderLabel:
                epgLoading ? 'Loading EPG…' : 'No program data available',
            isNow: false,
            onOpen: onOpen,
            onShowOptions: onShowOptions,
            blockLeft: 0,
            blockWidth: totalWidth,
            hScroll: hScroll,
            onRegister: (node) =>
                onRegisterBlock(rowIndex, windowStart, windowEnd, node),
            onUnregister: (node) => onUnregisterBlock(rowIndex, node),
            onFocusGained: () {
              ensureRowVisible?.call(rowIndex);
              onFocusChanged?.call(channel, null);
              onFocusTracked?.call(rowIndex, null);
            },
          ),
        ),
      );
    }
    double leftFor(EpgProgram p) => p.start.isBefore(windowStart)
        ? 0.0
        : p.start.difference(windowStart).inMinutes * pixelsPerMinute;
    double widthFor(EpgProgram p) =>
        (p.stop.isAfter(windowEnd) ? windowEnd : p.stop)
            .difference(p.start.isBefore(windowStart) ? windowStart : p.start)
            .inMinutes *
        pixelsPerMinute;
    return SizedBox(
      height: _TimelineGuideState._rowHeight,
      child: Stack(
        children: [
          for (final program in visible)
            Positioned(
              // Keyed by the programme's own span: a block's registered
              // start/end (see _registerBlock) is captured once at mount,
              // so after an EPG refresh an unkeyed block would be matched
              // by position to a *different* programme and keep answering
              // Up/Down lookups with the old one's times.
              key: ValueKey(
                  '${program.start.millisecondsSinceEpoch}-${program.stop.millisecondsSinceEpoch}'),
              left: leftFor(program),
              width: widthFor(program),
              top: 4,
              bottom: 4,
              child: _ProgramBlock(
                program: program,
                isNow: program.isNowPlaying(now),
                onOpen: onOpen,
                onShowOptions: onShowOptions,
                blockLeft: leftFor(program),
                blockWidth: widthFor(program),
                hScroll: hScroll,
                onRegister: (node) => onRegisterBlock(
                    rowIndex, program.start, program.stop, node),
                onUnregister: (node) => onUnregisterBlock(rowIndex, node),
                onFocusGained: () {
                  ensureRowVisible?.call(rowIndex);
                  onFocusChanged?.call(channel, program);
                  onFocusTracked?.call(rowIndex, program);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgramBlock extends StatefulWidget {
  const _ProgramBlock(
      {required this.program,
      required this.isNow,
      required this.onOpen,
      required this.onShowOptions,
      required this.blockLeft,
      required this.blockWidth,
      required this.hScroll,
      this.onFocusGained,
      this.placeholderLabel,
      this.onRegister,
      this.onUnregister});

  /// Null for a row with no EPG data at all — [placeholderLabel] is shown
  /// instead of a title, but this block is still focusable and selectable
  /// (Select still opens the channel) exactly like a real one.
  final EpgProgram? program;
  final String? placeholderLabel;
  final bool isNow;
  final VoidCallback onOpen;

  /// Hold-Select — see [_TvHomeScreenState._showChannelOptions]'s doc
  /// comment for why this needs to exist at all here (the focused thing
  /// is a time slot, not the channel itself, so a bare hold-to-favorite
  /// like the plain live list's had nothing to act on).
  final VoidCallback onShowOptions;
  final VoidCallback? onFocusGained;

  /// This block's own left/width within the shared horizontally-scrolled
  /// region — the same values [_TimelineRow] used to position its
  /// `Positioned` wrapper. Needed to keep the title visible once the
  /// block is wider than the viewport and has scrolled partway
  /// off-screen (see the sticky-label [ListenableBuilder] below).
  final double blockLeft;
  final double blockWidth;
  final ScrollController hScroll;

  /// Registers/unregisters this block's own [FocusNode] with
  /// [_TimelineGuideState] on mount/unmount — lets
  /// [_TimelineGuideState.moveVertical]/[_TimelineGuideState
  /// .restoreFocusToChannel] jump straight to a specific block instead of
  /// trusting default directional traversal (see [_TimelineGuideState
  /// .moveVertical]'s doc comment for why that's unreliable here).
  final void Function(FocusNode node)? onRegister;
  final void Function(FocusNode node)? onUnregister;

  @override
  State<_ProgramBlock> createState() => _ProgramBlockState();
}

class _ProgramBlockState extends State<_ProgramBlock> {
  bool _focused = false;
  final FocusNode _node = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.onRegister?.call(_node);
  }

  @override
  void didUpdateWidget(_ProgramBlock old) {
    super.didUpdateWidget(old);
    if (old.program?.start != widget.program?.start ||
        old.program?.stop != widget.program?.stop) {
      old.onUnregister?.call(_node);
      widget.onRegister?.call(_node);
    }
  }

  @override
  void dispose() {
    widget.onUnregister?.call(_node);
    _node.dispose();
    super.dispose();
  }

  /// Scrolls horizontally only when this block is entirely off-screen. A
  /// block that overlaps the view at all stays put — a long programme
  /// that started earlier used to yank the whole guide back to its start
  /// on every arrival (reported directly, more than once); the sticky
  /// label keeps its title readable instead. Left/Right and Up/Down are
  /// dispatched explicitly (see [_TimelineGuideState.moveHorizontal]),
  /// which position the view themselves.
  void _revealHorizontally() {
    if (widget.hScroll.hasClients) {
      final pos = widget.hScroll.position;
      final viewLeft = pos.pixels;
      final viewRight = viewLeft + pos.viewportDimension;
      final overlaps = widget.blockLeft < viewRight &&
          widget.blockLeft + widget.blockWidth > viewLeft;
      if (overlaps) return;
    }
    Scrollable.ensureVisible(context, duration: Duration.zero);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Every palette now gets the same contour + gradient-sheen treatment
    // — see `_SelectableRow`'s doc comment for the full story. Originally
    // Dark/Gold-only: this guide, with several blocks simultaneously
    // solid-filled at once (one "now playing" badge per visible channel
    // row), read as a wall of pastel wash — "a big bunch of colours" —
    // rather than a backdrop with the odd gold accent.
    final accent = scheme.primary;
    // Dedicated gradient-sheen accent — see `buildPaletteColorScheme`'s
    // own doc comment for why it's kept separate from `accent` (Habs:
    // the gradient was blending toward the focus-text white instead of
    // the actual brand red before this split existed).
    final gradientAccent = scheme.primaryContainer;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      // Same HoldToActivate-over-InkWell shape as the plain live list's
      // rows — a held Select here now opens _showChannelOptions, the
      // one thing that plain hold-to-favorite couldn't do for a block
      // (the focused thing is a time slot, not the channel).
      child: HoldToActivate(
        onTap: widget.onOpen,
        onHold: widget.onShowOptions,
        child: Focus(
          focusNode: _node,
          onFocusChange: (f) {
            setState(() => _focused = f);
            // Instant, not animated — the same "jumpTo, never animateTo
            // on a real device" reasoning as the rest of this widget;
            // only relevant once these blocks are numerous enough to
            // scroll. onFocusGained runs first so the vertical axis has
            // already been edge-scrolled (see
            // _TimelineGuideState._ensureRowVisible) by the time
            // ensureVisible looks at it — leaving it only the horizontal
            // axis to settle.
            if (f) {
              widget.onFocusGained?.call();
              _revealHorizontally();
            }
          },
          child: InkWell(
            // Windows only — gating actual playback behind a second click
            // instead of the first lets a single click act as a pure
            // preview, reported directly as the expected mouse behavior
            // (click = look, double-click = commit); a D-pad remote has
            // no such ambiguity (one press IS the commit), so
            // HoldToActivate above and a touch tap are untouched, only
            // this widget's own mouse-click path changes. `onTap: null`
            // was tried first on the assumption InkWell requests focus on
            // any tap-down regardless of its own callbacks — reported
            // directly as not actually true here (no focus, no details
            // panel, on a single click at all); `_node.requestFocus()`
            // makes the single click focus this block explicitly instead
            // of trusting that.
            onTap: Platform.isWindows ? _node.requestFocus : widget.onOpen,
            onDoubleTap: Platform.isWindows ? widget.onOpen : null,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: _focused
                    ? null
                    : widget.isNow
                        ? Colors.black87
                        : Colors.white.withValues(alpha: 0.06),
                // Same real diagonal sheen as `_SelectableRow`'s own focus
                // fix — see its doc comment for why a flat `black87` fill
                // photographed as more "filled" than it read live.
                gradient: _focused
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.black,
                          Color.lerp(Colors.black, gradientAccent, 0.4)!,
                          Colors.black,
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      )
                    : null,
                border: Border.all(
                  color: _focused
                      ? accent
                      : widget.isNow
                          ? accent.withValues(alpha: 0.85)
                          : Colors.white24,
                  width: _focused ? 2 : (widget.isNow ? 1.5 : 1),
                ),
                borderRadius: BorderRadius.circular(6),
                boxShadow: _focused
                    ? [
                        BoxShadow(
                            color: accent.withValues(alpha: 0.5),
                            blurRadius: 10)
                      ]
                    : const [],
              ),
              alignment: Alignment.centerLeft,
              // A block wider than the viewport (a long "now playing"
              // programme, or one that started before the guide's visible
              // window and got clamped to the left edge) used to render as
              // a solid block of color with its title anchored at the
              // block's own literal left edge — which is exactly what
              // scrolls out of view first, leaving no visible label at
              // all. Reported directly on real hardware: "I can't see
              // what's currently playing there." This nudges the label
              // right by however far the viewport has scrolled past this
              // block's own left edge, clamped so it never pushes past the
              // block's own right edge — a plain sticky-header effect.
              child: ListenableBuilder(
                listenable: widget.hScroll,
                builder: (context, _) {
                  final scrollX =
                      widget.hScroll.hasClients ? widget.hScroll.offset : 0.0;
                  final maxInset =
                      (widget.blockWidth - 40.0).clamp(0.0, double.infinity);
                  final inset =
                      (scrollX - widget.blockLeft).clamp(0.0, maxInset);
                  return Padding(
                    padding: EdgeInsets.fromLTRB(6 + inset, 2, 6, 2),
                    child: Text(
                      widget.program?.title ?? widget.placeholderLabel ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _focused
                              ? accent
                              : widget.program == null
                                  ? Colors.white54
                                  : Colors.white,
                          fontSize: 12,
                          fontStyle: widget.program == null
                              ? FontStyle.italic
                              : FontStyle.normal),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
