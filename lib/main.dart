import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/catalog_sync_prompt_screen.dart';
import 'screens/catalog_sync_screen.dart';
import 'screens/home_screen.dart';
import 'screens/tv_home_screen.dart';
import 'services/app_preferences.dart';
import 'services/catalog_database.dart';
import 'services/device_memory_service.dart';
import 'services/epg_service.dart';
import 'services/persistent_image_cache.dart';
import 'services/playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/storage_service.dart';
import 'utils/constants.dart';
import 'utils/route_observer.dart';
import 'utils/tv_theme.dart';
import 'widgets/live_resume_hint.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureImageCache();
  // See persistent_image_cache.dart's doc comment — the package default
  // stores cached poster/logo *files* in OS-reclaimable storage while its
  // own cache index lives somewhere persistent, so they can (and on a
  // real box, confirmed do) drift out of sync: every poster re-fetches
  // from scratch on a cold start, not just the first one ever.
  CachedNetworkImageProvider.defaultCacheManager = persistentImageCacheManager;
  runApp(const NoxIptvApp());
}

/// Flutter's default ImageCache holds up to 1000 decoded images / ~100MB —
/// fine on a phone, but on a memory-constrained box (some Firesticks have
/// as little as ~1.7GB total RAM) that alone can be enough to trigger a
/// device-wide low-memory kill cascade while browsing a large catalog, even
/// with cacheWidth/cacheHeight shrinking each individual decoded image (see
/// PosterCard/channel_list_tile).
///
/// This used to be one fixed number for every device — confirmed as the
/// wrong model: a Firestick with almost no memory headroom and a Formuler
/// box with plenty both got the exact same ceiling, when what they can
/// each actually spare is very different. Native Android image loaders
/// (Glide, the de facto standard) size their own cache off
/// `ActivityManager.isLowRamDevice()`/`getMemoryInfo()` for exactly this
/// reason — this queries the same real device info (via MainActivity.kt,
/// since Flutter has no built-in way to ask this) and scales the ceiling
/// to what *this* device can actually spare, instead of guessing one
/// number for all of them. Falls back to the old conservative constant
/// (100MB) if the query fails for any reason (non-Android platform,
/// unexpected native exception) — never guesses generous under
/// uncertainty.
Future<void> _configureImageCache() async {
  final info = await DeviceMemoryService.getMemoryInfo();
  final int maxBytes;
  if (info == null || info.isLowRamDevice || info.totalMemGB < 2.0) {
    maxBytes =
        100 << 20; // 100MB — the tier this session already validated as stable
  } else if (info.totalMemGB < 3.0) {
    maxBytes = 175 << 20;
  } else if (info.totalMemGB < 4.0) {
    maxBytes = 250 << 20;
  } else {
    // Was 350MB — bumped after confirming on real hardware that the
    // adaptive ceiling (introduced this same version) was noticeably
    // faster than the old fixed 100MB but still not quite instant on a
    // device with real headroom to spare.
    maxBytes = 500 << 20;
  }
  // The image *count* isn't the real lever — at ~300KB per decoded poster
  // (see PosterCard's cacheWidth/cacheHeight), maxBytes above is reached
  // long before any sane count limit would matter. Set high enough that
  // it's never the actual constraint, so maxBytes is the one true ceiling.
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = maxBytes;
}

/// Root widget. Bootstraps [StorageService], [PlaylistManager], and
/// [EpgService] before building the [MaterialApp] so every provider handed
/// down the tree already has its persisted settings/cache loaded — no
/// "waiting for provider" states inside the UI.
class NoxIptvApp extends StatefulWidget {
  const NoxIptvApp({super.key});

  @override
  State<NoxIptvApp> createState() => _NoxIptvAppState();
}

class _NoxIptvAppState extends State<NoxIptvApp>
    with SingleTickerProviderStateMixin {
  late final StorageService _storage;
  late final CatalogDatabase _catalogDb;
  late final AppPreferences _preferences;
  late final PlaylistManager _playlistManager;
  late final EpgService _epgService;
  late final PlaybackService _playbackService;
  bool _ready = false;

  /// True while [PlaylistManager.runFullCatalogSync] is blocking the
  /// launch — see [CatalogSyncScreen] and [_bootstrap] for the whole
  /// "a few times a week, not every launch" reasoning.
  bool _syncing = false;

  /// True while waiting on [CatalogSyncPromptScreen]'s Yes/No answer — a
  /// full sync is a multi-minute, server-round-trip-per-category action
  /// triggered automatically (a stale timestamp), not a direct user tap,
  /// so it asks first rather than just barging into it.
  bool _syncPromptPending = false;
  Completer<bool>? _syncPromptCompleter;

  Future<bool> _confirmAutoSync() {
    final completer = Completer<bool>();
    _syncPromptCompleter = completer;
    if (mounted) setState(() => _syncPromptPending = true);
    return completer.future;
  }

  void _respondToSyncPrompt(bool confirmed) {
    if (mounted) setState(() => _syncPromptPending = false);
    _syncPromptCompleter?.complete(confirmed);
    _syncPromptCompleter = null;
  }

  /// Lets background work (the initial playlist load finishing, "Update
  /// content" finishing) show a brief toast without needing a BuildContext
  /// tied to whatever screen happens to be on top — same trick other IPTV
  /// players use for their "refresh complete" notification.
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Lets [LiveResumeHint] push the fullscreen player back on top from
  /// its own position in the tree — it sits as a *sibling* of the
  /// Navigator (see `builder` below), deliberately, so its hold-Right
  /// gesture and reminder text work from any screen; `Navigator.of
  /// (context)` from there would find nothing, since siblings aren't
  /// ancestors.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  final String _splashStatus = 'Starting...';
  String? _bootstrapError;

  /// Drives the cold-start splash's "firing up" pulse (logo breathing
  /// scale + glow) — purely cosmetic, tied to however long [_bootstrap]
  /// actually takes rather than padding out a fixed extra delay. Most
  /// launches only see this for a moment; it just looks intentional
  /// instead of a bare spinner for however long that moment is.
  late final AnimationController _splashController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _splashController.dispose();
    super.dispose();
  }

  /// The splash is meant to be *seen*, not just theoretically present —
  /// a boot animation that only flashes for a fraction of a second reads
  /// as broken, not polished. On a normal day (no full sync due),
  /// bootstrap itself now finishes in well under a second, which isn't
  /// enough time to register the pulse at all. This is a deliberate,
  /// fixed minimum floor the splash stays up for regardless of how fast
  /// the real work finishes — same idea as a game console's boot
  /// animation playing out fully even though the actual boot is quick.
  static const _minSplashDuration = Duration(milliseconds: 2600);

  Future<void> _bootstrap() async {
    setState(() => _bootstrapError = null);
    final started = DateTime.now();
    try {
      _storage = StorageService();
      await _storage.init();

      _preferences = AppPreferences(_storage);
      await _preferences.init();

      _catalogDb = CatalogDatabase();

      _playlistManager = PlaylistManager(_storage, _catalogDb);
      _epgService = EpgService(_storage);
      _playbackService = PlaybackService(_storage, _playlistManager);

      // Restores category lists (small, fast regardless of catalog size —
      // see that method's doc comment for why live channels/category
      // *items* are no longer touched here). Awaited, unlike before: the
      // freshness check right below needs isXtream/category state to
      // already be correct, so there's no way to let the UI go up first
      // this time.
      await _playlistManager.init();

      // TiviMate/MyTVOnline3-style: a full catalog sync (every non-hidden
      // category's items, not just category lists) happens a few times a
      // week, not on every launch — an ordinary day skips straight to the
      // main UI with an already-populated local catalog. Blocking behind
      // CatalogSyncScreen here (rather than showing the main UI and
      // syncing behind it, the old approach) is the actual point: the
      // user shouldn't reach a real, usable Movies/TV Shows screen until
      // the catalog is genuinely ready, matching how those apps behave on
      // a sync day. Hidden groups are unaffected either way — see
      // runFullCatalogSync's doc comment.
      //
      // This is triggered by a stale timestamp, not a direct tap, so it
      // asks first (CatalogSyncPromptScreen) rather than just barging into
      // a multi-minute blocking sync — declining leaves the timestamp
      // untouched, so it asks again next launch instead of postponing
      // forever.
      var didSync = false;
      if (_playlistManager.needsFullSync()) {
        final confirmed = await _confirmAutoSync();
        if (confirmed) {
          didSync = true;
          if (mounted) setState(() => _syncing = true);
          await _playlistManager.runFullCatalogSync();
          if (mounted) setState(() => _syncing = false);
        }
      }

      // Only relevant on the plain "no sync due today" path — if a sync
      // ran, [runFullCatalogSync] already populated every category via
      // its own warm-up, so there's nothing left to pre-load here.
      //
      // This is the actual point of showing a splash at all: an ordinary
      // cold restart starts with every category's *items* wiped from
      // memory (by design — see _restoreXtreamCache's doc comment), even
      // though they're already sitting in the local database from a
      // previous session. Without this, that repopulation only starts
      // once the user taps into Movies/TV Shows, and they'd watch it
      // happen live, category by category. Driving it here instead means
      // the splash — which the user is already expecting to sit through
      // for a moment, the same as a game console's boot animation —
      // is what "pays for" that, so Movies/TV Shows are already fully
      // populated by the time the main UI appears. Uses the same
      // self-sustaining worker pool "Update Content" already relies on,
      // so this is a fast local-database read in the common case, not a
      // network fetch — no artificial delay, this is genuinely the same
      // work that would otherwise happen the moment you opened either tab.
      if (!didSync && _playlistManager.isXtream) {
        // One pre-load pass per enabled Xtream playlist — group names
        // alone aren't enough to route to the right playlist's session
        // once more than one can exist (two playlists could share a
        // category name), so this groups the merged vod/seriesGroups
        // lists by their own `playlistId` first.
        final futures = <Future<void>>[];
        for (final profile in _playlistManager.profiles
            .where((p) => p.enabled && p.isXtream)) {
          final vodNames = _playlistManager.vodGroups
              .where((g) => g.playlistId == profile.id && !g.isHidden)
              .map((g) => g.title);
          final seriesNames = _playlistManager.seriesGroups
              .where((g) => g.playlistId == profile.id && !g.isHidden)
              .map((g) => g.title);
          futures.add(_playlistManager.ensureCategoriesLoaded(
              profile.id, vodNames, 'vod'));
          futures.add(_playlistManager.ensureCategoriesLoaded(
              profile.id, seriesNames, 'series'));
        }
        await Future.wait(futures);
      }

      // A fixed floor on top of the real work above — on a very small
      // catalog (or M3U mode, which skips the pre-load entirely) that
      // work alone might finish in well under a second, too fast for the
      // splash's pulse animation to actually register at all.
      final elapsed = DateTime.now().difference(started);
      if (elapsed < _minSplashDuration) {
        await Future.delayed(_minSplashDuration - elapsed);
      }
      if (mounted) setState(() => _ready = true);
      if (didSync) {
        // The toast needs the real MaterialApp's ScaffoldMessengerKey,
        // which doesn't exist until the tree above actually builds.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _showToast('Content updated'));
      }
      unawaited(_autoResumeLastChannel());

      unawaited(_epgService.init());
      unawaited(_playbackService.init());

      _epgService.startAutoRefresh(_storage.getRefreshInterval(), _epgSources);
    } catch (e) {
      // Surfaces any unexpected startup failure as a retryable screen
      // instead of leaving the app stuck on the splash spinner forever.
      if (mounted) setState(() => _bootstrapError = e.toString());
    }
  }

  /// Resumes straight into whatever live channel was last playing — the
  /// same "turn it on and it's on the last channel" behavior MyTvOnline
  /// has. Scoped to live channels only (not movies/episodes): those are
  /// deliberate choices to open, a live channel is just "what's on".
  /// No-ops if something's already playing (a real user action on this
  /// launch beat the background load) or there's nothing to resume into.
  ///
  /// Awaits [ensureLiveChannelsLoaded] directly (unlike every other caller,
  /// which just kicks it off and lets the UI show a brief loading state) —
  /// this one has to actually search the list, so it can't run until the
  /// list exists. Live channels are no longer loaded eagerly during
  /// PlaylistManager.init() (see that method's doc comment), so without
  /// this, resume-last-channel would silently find an empty list and do
  /// nothing on every Xtream launch.
  Future<void> _autoResumeLastChannel() async {
    if (_playbackService.isPlayingSomething) return;
    final lastId = _storage.getLastChannelId();
    if (lastId == null) return;
    await _playlistManager.ensureLiveChannelsLoaded();
    for (final channel in _playlistManager.channels) {
      if (channel.id == lastId) {
        // silent: true — see PlaybackService.isSilentlyResuming's doc
        // comment. This still starts loading/playing right away; it
        // just tells TvHomeScreen not to auto-jump its groups column and
        // fetch EPG for it until the user actually looks for it.
        _playbackService.play(channel, silent: true);
        return;
      }
    }
  }

  /// The oldest last-full-sync timestamp among enabled Xtream playlists —
  /// the most stale one is what actually drove [needsFullSync] to true,
  /// so it's the most representative "how out of date is this" answer to
  /// show on the confirm-before-syncing prompt. Null if none has ever
  /// synced at all.
  DateTime? _oldestLastFullSyncAt() {
    DateTime? oldest;
    for (final profile
        in _playlistManager.profiles.where((p) => p.enabled && p.isXtream)) {
      final at = _storage.getLastFullSyncAt(profile.id);
      if (at == null) return null;
      if (oldest == null || at.isBefore(oldest)) oldest = at;
    }
    return oldest;
  }

  /// Every enabled playlist's EPG source, evaluated fresh on each
  /// `EpgService.startAutoRefresh` tick — see `EpgService.refresh`'s doc
  /// comment for why each playlist's own channel ids matter here.
  List<EpgSource> _epgSources() => _playlistManager.profiles
      .where((p) => p.enabled && (p.epgUrl?.isNotEmpty ?? false))
      .map((p) => (
            url: p.epgUrl!,
            knownChannelIds: _playlistManager.knownChannelIdsFor(p.id)
          ))
      .toList();

  void _showToast(String message) {
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_bootstrapError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white70, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Startup failed:\n$_bootstrapError',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                      onPressed: _bootstrap, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // The three branches below (and the real app further down) all run
    // only once `_bootstrap()` has progressed far enough to assign every
    // `late final` service field, unlike the `_bootstrapError` case above
    // (which can fire mid-assignment) — so wrapping them in the same
    // `MultiProvider` the real app uses is safe here. Reported directly,
    // live: `CatalogSyncPromptScreen`'s two `ModeButton`s render as blank,
    // completely unresponsive boxes ("no way to get out of it," "also
    // can not skip") — `ModeButton` reads `AppPreferences` via
    // `context.watch`, and this screen used to be returned *before* this
    // method's `MultiProvider` further down, with no ancestor Provider of
    // any kind. Flutter's release-mode fallback for a widget that throws
    // during build is exactly what was on screen: a plain, non-
    // interactive placeholder box with no text and no working `onTap`.
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: _storage),
        Provider<CatalogDatabase>.value(value: _catalogDb),
        ChangeNotifierProvider<AppPreferences>.value(value: _preferences),
        ChangeNotifierProvider<PlaylistManager>.value(value: _playlistManager),
        ChangeNotifierProvider<EpgService>.value(value: _epgService),
        ChangeNotifierProvider<PlaybackService>.value(value: _playbackService),
      ],
      child: _buildReadyContent(context),
    );
  }

  Widget _buildReadyContent(BuildContext context) {
    if (_syncPromptPending) {
      return CatalogSyncPromptScreen(
        lastSyncedAt: _oldestLastFullSyncAt(),
        onRespond: _respondToSyncPrompt,
      );
    }

    if (_syncing) {
      return CatalogSyncScreen(playlist: _playlistManager);
    }

    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: AnimatedBuilder(
              animation: _splashController,
              builder: (context, child) {
                // 0..1..0 over the controller's duration — eased so the
                // pulse breathes rather than bouncing linearly.
                final t = Curves.easeInOut.transform(_splashController.value);
                final scale = 0.94 + (t * 0.12); // 0.94 .. 1.06
                final glow = 0.25 + (t * 0.45); // 0.25 .. 0.70
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFFE91E8C).withValues(alpha: glow),
                            blurRadius: 40,
                            spreadRadius: 6,
                          ),
                        ],
                      ),
                      child: Transform.scale(
                        scale: scale,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Image.asset(
                            'assets/icon/icon_flat.png',
                            width: 120,
                            height: 120,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [Color(0xFF7C3AED), Color(0xFFE91E8C)],
                      ).createShader(bounds),
                      child: const Text(
                        AppConstants.appName,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(_splashStatus,
                        style: const TextStyle(color: Colors.white70)),
                  ],
                );
              },
            ),
          ),
        ),
      );
    }

    return Consumer<AppPreferences>(
      builder: (context, prefs, _) {
        return MaterialApp(
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: _scaffoldMessengerKey,
          navigatorKey: _navigatorKey,
          navigatorObservers: [appRouteObserver],
          // Renders above the Navigator's own output rather than inside
          // it, so the hold-Right-to-resume gesture and reminder text
          // work from any screen instead of only the one route they
          // happened to be built into (see LiveResumeHint's doc
          // comment).
          builder: (context, child) => Stack(
            children: [
              if (child != null) child,
              LiveResumeHint(navigatorKey: _navigatorKey),
            ],
          ),
          themeMode: prefs.themeMode,
          theme: ThemeData(
            brightness: Brightness.light,
            colorScheme:
                buildPaletteColorScheme(prefs.palette, Brightness.light),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorScheme:
                buildPaletteColorScheme(prefs.palette, Brightness.dark),
            useMaterial3: true,
          ),
          home: Builder(
            builder: (context) {
              final useTv = prefs.layoutMode == 'tv' ||
                  (prefs.layoutMode == 'auto' &&
                      MediaQuery.of(context).size.width >=
                          AppConstants.tvLayoutWidthThreshold);
              return useTv ? const TvHomeScreen() : const HomeScreen();
            },
          ),
        );
      },
    );
  }
}
