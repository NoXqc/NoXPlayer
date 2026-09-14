import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import '../widgets/catalog_warmup_banner.dart';
import '../widgets/channel_list_tile.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/mode_button.dart';
import '../widgets/player_controls.dart';
import '../widgets/sidebar.dart';
import 'catalog_sync_screen.dart';
import 'player_screen.dart';
import 'search_screen.dart';
import 'series_detail_screen.dart';
import 'settings/settings_menu_screen.dart';

/// Main screen: collapsible sidebar + channel/program list, with the video
/// player shown inline on wide layouts (tablets/Android boxes) or, on
/// phones, a persistent [MiniPlayerBar] that expands into the fullscreen
/// [PlayerScreen] — both are just presentations of the shared
/// [PlaybackService], so switching between them never restarts playback.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const double _wideBreakpoint = 900;

  bool _sidebarCollapsed = false;
  String _tab = 'TV';
  String? _selectedGroup;

  bool _isWide(BuildContext context) => MediaQuery.of(context).size.width >= _wideBreakpoint;

  void _openSearch() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(initialScope: _tab)));
  }

  Future<void> _selectChannel(Channel channel) async {
    // Awaited so PlayerScreen's own initState (which also calls play(),
    // guarded to no-op once this channel is already current) doesn't
    // race this call — see TvHomeScreen._selectChannel for the full
    // explanation of the bug this avoids.
    await context.read<PlaybackService>().play(channel);
    if (!mounted) return;
    if (!_isWide(context)) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)));
    }
  }

  void _openSeries(XtreamSeries series) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  void _onGroupSelected(String? group) {
    setState(() => _selectedGroup = group);
    if (group != null) {
      context.read<PlaylistManager>().ensureCategoryLoaded(group, _categoryForTab(_tab));
    }
  }

  Future<void> _refreshPlaylist() async {
    final storage = context.read<StorageService>();
    final playlist = context.read<PlaylistManager>();

    if (playlist.isXtream) {
      final server = storage.getXtreamServer();
      final username = storage.getXtreamUsername();
      final password = storage.getXtreamPassword();
      if (server == null || username == null || password == null) {
        _promptForSettings();
        return;
      }
      // Shared with Settings > Clear Cache — see its doc comment for why
      // this needed to become a reusable helper rather than living here.
      final didSync = await confirmAndRunFullCatalogSync(context, playlist);
      if (didSync && mounted) _showUpdateToast();
      return;
    }

    // M3U mode: no per-category concept to re-sync, just a plain re-fetch
    // of the flat list — still confirms first since a stray tap on this
    // button shouldn't kick off a re-fetch unintentionally.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update content now?'),
        content: const Text('Re-checks your playlist URL for new content.'),
        actions: [
          ModeButton(label: 'Cancel', selected: false, onTap: () => Navigator.of(context).pop(false)),
          ModeButton(label: 'Update', selected: false, onTap: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final url = storage.getM3uUrl();
    if (url == null || url.isEmpty) {
      _promptForSettings();
      return;
    }
    await playlist.loadFromUrl(url);
  }

  Future<void> _refreshEpg() async {
    final storage = context.read<StorageService>();
    final url = storage.getEpgUrl();
    if (url == null || url.isEmpty) {
      _promptForSettings();
      return;
    }
    await context.read<EpgService>().refresh(url);
  }

  void _promptForSettings() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Set your playlist source in Settings first.')),
    );
    _openSettings();
  }

  void _showUpdateToast() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Content updated'), duration: Duration(seconds: 2)),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsMenuScreen()));
  }

  /// A horizontal "Continue Watching" strip for the Movies/TV Shows tabs,
  /// built from [PlaybackService.recentlyPlayed] filtered to items of the
  /// right content type (via their `xt_vod_`/`xt_ep_` id prefix) that have
  /// a saved resume position. Null when there's nothing to resume, or on
  /// tabs where "resume" doesn't apply (Live TV, Favorites).
  Widget? _buildContinueWatchingStrip() {
    if (_tab != 'Movies' && _tab != 'TV Shows') return null;
    final idPrefix = _tab == 'Movies' ? 'xt_vod_' : 'xt_ep_';
    final playback = context.watch<PlaybackService>();
    final storage = context.read<StorageService>();
    final items = playback.recentlyPlayed
        .where((c) => c.id.startsWith(idPrefix) && storage.getLastPosition(c.id) > 0)
        .toList();
    if (items.isEmpty) return null;

    return SizedBox(
      height: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text('Continue Watching', style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final c = items[i];
                final hasImage = c.logoUrl != null && c.logoUrl!.isNotEmpty;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    onTap: () => _selectChannel(c),
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 84,
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: hasImage
                                  ? CachedNetworkImage(
                                      imageUrl: c.logoUrl!,
                                      fit: BoxFit.cover,
                                      width: 84,
                                      errorWidget: (_, __, ___) => const ColoredBox(
                                        color: Colors.black26,
                                        child: Icon(Icons.play_circle_outline),
                                      ),
                                    )
                                  : const ColoredBox(
                                      color: Colors.black26,
                                      child: Icon(Icons.play_circle_outline),
                                    ),
                            ),
                          ),
                          Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = _isWide(context);
    final playlist = context.watch<PlaylistManager>();
    final epg = context.watch<EpgService>();
    final playback = context.watch<PlaybackService>();
    final showClock = context.watch<AppPreferences>().showClock;
    final continueStrip = _buildContinueWatchingStrip();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text(AppConstants.appName),
            if (showClock)
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: _ClockText(),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
          IconButton(
            tooltip: 'Update content',
            icon: playlist.isLoading
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.playlist_add_check),
            onPressed: playlist.isLoading ? null : _refreshPlaylist,
          ),
          IconButton(
            tooltip: 'Update EPG now',
            icon: epg.isLoading
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.calendar_month),
            onPressed: epg.isLoading ? null : _refreshEpg,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 8),
        ],
      ),
      // Was `playlist.channels.isEmpty` — that's now empty in Xtream mode
      // until ensureLiveChannelsLoaded actually runs (it's no longer
      // eager), so this would otherwise block the *entire* app (Movies/TV
      // Shows included) behind a full-screen spinner just because live
      // channels specifically hadn't been touched yet. lastLoadSummary is
      // the right "has anything at all loaded" signal instead — it's set
      // as soon as categories restore, independent of live-channel state.
      body: (playlist.isLoading && playlist.lastLoadSummary == null)
          ? _buildLoadingState(playlist)
          : (playlist.error != null && playlist.lastLoadSummary == null)
              ? _buildEmptyState()
              : Column(
                  children: [
                    const CatalogWarmupBanner(),
                    Expanded(
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: _sidebarCollapsed ? 64 : 260,
                            child: Sidebar(
                              collapsed: _sidebarCollapsed,
                              selectedTab: _tab,
                              selectedGroup: _selectedGroup,
                              onToggleCollapse: () =>
                                  setState(() => _sidebarCollapsed = !_sidebarCollapsed),
                              onTabChanged: (tab) => setState(() {
                                _tab = tab;
                                _selectedGroup = null;
                              }),
                              onGroupSelected: _onGroupSelected,
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            flex: isWide ? 2 : 3,
                            child: continueStrip == null
                                ? _buildChannelList(playlist)
                                : Column(
                                    children: [
                                      continueStrip,
                                      Expanded(child: _buildChannelList(playlist)),
                                    ],
                                  ),
                          ),
                          if (isWide) ...[
                            const VerticalDivider(width: 1),
                            Expanded(
                              flex: 3,
                              // Keyed to the channel, not just const —
                              // see VideoPlayerPane's own AspectRatio fix
                              // for the leaf widget; this additionally
                              // forces the *whole* pane (and whatever the
                              // platform view's hybrid-composition
                              // plumbing keeps attached to its ancestry)
                              // to tear down and rebuild on a channel
                              // switch, confirmed on real hardware as
                              // necessary on top of the leaf-level key —
                              // that alone still left a stale frame
                              // behind on some devices.
                              child: VideoPlayerPane(key: ValueKey(playback.currentChannel?.id)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!isWide && playback.isPlayingSomething && !playback.isMinimized)
                      MiniPlayerBar(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayerScreen(channel: playback.currentChannel!),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _buildChannelList(PlaylistManager playlist) {
    // Needed for the live channel list (below) and Favorites (which can
    // include individually-favorited live channels) to have anything to
    // show at all — see PlaylistManager.ensureLiveChannelsLoaded's doc
    // comment for why this isn't loaded eagerly anymore. No-op if this
    // isn't Xtream mode, already loaded, or already loading.
    unawaited(playlist.ensureLiveChannelsLoaded());

    // Series aren't directly playable — in Xtream mode the TV Shows tab
    // lists series containers that drill down into episodes, not channels.
    if (_tab == 'TV Shows' && playlist.isXtream) {
      final series = playlist.visibleSeries(_selectedGroup);
      // isWarmingCatalog only means "still safe to assume this could
      // populate soon" for Movies/TV Shows — Live TV is already fully
      // loaded upfront regardless of catalog warm-up progress.
      if (series.isEmpty && (playlist.isLoading || playlist.isWarmingCatalog)) {
        return const Center(child: CircularProgressIndicator());
      }
      if (series.isEmpty) {
        return const Center(child: Text('No TV shows found. Pick a category on the left.'));
      }
      return ListView.builder(
        itemCount: series.length,
        itemBuilder: (context, index) {
          final s = series[index];
          return ListTile(
            leading: SizedBox(
              width: 48,
              height: 48,
              child: (s.coverUrl != null && s.coverUrl!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: s.coverUrl!,
                      fit: BoxFit.contain,
                      errorWidget: (_, __, ___) => const Icon(Icons.video_library),
                    )
                  : const Icon(Icons.video_library),
            ),
            title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openSeries(s),
          );
        },
      );
    }

    final channels = _tab == 'Favorites'
        ? playlist.favoriteChannels
        : playlist.visibleChannels(groupTitle: _selectedGroup, category: _categoryForTab(_tab));

    // Catalog warm-up only ever affects Movies/TV Shows, never Live TV —
    // but Live TV can still genuinely be "loading" now (the kick-off
    // above), which the plain `playlist.isLoading` check below already
    // covers on its own.
    final warmupMightStillPopulate = _tab != 'TV' && playlist.isWarmingCatalog;
    if (channels.isEmpty && (playlist.isLoading || warmupMightStillPopulate)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (channels.isEmpty) {
      return const Center(child: Text('No channels found.'));
    }

    return Consumer<PlaybackService>(
      builder: (context, playback, _) => ListView.builder(
        itemCount: channels.length,
        itemBuilder: (context, index) {
          final channel = channels[index];
          return ChannelListTile(
            channel: channel,
            selected: playback.currentChannel?.id == channel.id,
            showEpg: _tab == 'TV',
            onTap: () => _selectChannel(channel),
          );
        },
      ),
    );
  }

  String _categoryForTab(String tab) => switch (tab) {
        'Movies' => 'vod',
        'TV Shows' => 'series',
        _ => 'tv',
      };

  Widget _buildLoadingState(PlaylistManager playlist) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(playlist.loadingPhase ?? 'Loading playlist...', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.live_tv, size: 64),
            const SizedBox(height: 16),
            const Text('Failed to load playlist.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _openSettings, child: const Text('Open Settings')),
          ],
        ),
      ),
    );
  }
}

/// Small self-ticking clock shown in the app bar when enabled in Settings.
class _ClockText extends StatefulWidget {
  const _ClockText();

  @override
  State<_ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<_ClockText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      DateFormat('HH:mm').format(DateTime.now()),
      style: Theme.of(context).textTheme.titleMedium,
    );
  }
}
