import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/catalog_sync_prompt_screen.dart';
import 'screens/catalog_sync_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings/add_playlist_screen.dart';
import 'screens/tv_home_screen.dart';
import 'screens/welcome_add_playlist_screen.dart';
import 'services/app_preferences.dart';
import 'services/catalog_database.dart';
import 'services/device_memory_service.dart';
import 'services/epg_service.dart';
import 'services/parental_pin.dart';
import 'services/persistent_image_cache.dart';
import 'services/playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/storage_service.dart';
import 'services/viewer_profile_service.dart';
import 'utils/constants.dart';
import 'utils/route_observer.dart';
import 'utils/tv_theme.dart';
import 'widgets/desktop_live_resume_hint.dart';
import 'widgets/live_resume_hint.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Plain `sqflite` has no Windows/Linux implementation at all — confirmed
  // via .flutter-plugins-dependencies: sqflite_android/sqflite_darwin exist
  // for the platforms this app already shipped on, nothing for
  // windows/linux. sqflite_common_ffi's FFI-based factory is the standard
  // swap for those two desktop platforms; Android/iOS/macOS keep using
  // plain sqflite's own already-proven native implementation untouched.
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Only ever used by DesktopPlayerScreen — see its own doc comment and
    // pubspec.yaml's media_kit comment. Every other platform keeps using
    // video_player_hdr exclusively and never touches this at all.
    MediaKit.ensureInitialized();
  }
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
  late final ViewerProfileService _viewerProfileService;
  late final ParentalPin _parentalPin;
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

  /// True while waiting on [WelcomeAddPlaylistScreen]'s answer — shown once,
  /// right after [PlaylistManager.init] confirms a brand-new install has
  /// zero playlists configured, since nothing else in the app hints that
  /// content lives behind Settings > Playlist Manager rather than just
  /// showing up on its own.
  bool _newUserPromptPending = false;
  Completer<bool>? _newUserPromptCompleter;

  /// Set from [WelcomeAddPlaylistScreen]'s answer, consumed once `_ready`
  /// flips true (see `_buildReadyContent`'s `build` doc comment below) —
  /// can't just push [AddPlaylistScreen] directly from the prompt itself,
  /// since the real `MaterialApp`/`Navigator` this screen's bootstrap gate
  /// runs ahead of doesn't exist yet at that point.
  bool _pendingAutoOpenAddPlaylist = false;

  Future<bool> _confirmNewUserWantsPlaylist() {
    final completer = Completer<bool>();
    _newUserPromptCompleter = completer;
    if (mounted) setState(() => _newUserPromptPending = true);
    return completer.future;
  }

  void _respondToNewUserPrompt(bool wantsToAddPlaylist) {
    if (mounted) setState(() => _newUserPromptPending = false);
    _newUserPromptCompleter?.complete(wantsToAddPlaylist);
    _newUserPromptCompleter = null;
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
      // Asked once per launch, before anything decides a layout — see
      // DeviceTypeService for why screen width couldn't answer this.
      _preferences.isTelevision = await DeviceTypeService.isTelevision();

      _catalogDb = CatalogDatabase();

      _playlistManager = PlaylistManager(_storage, _catalogDb);
      _epgService = EpgService(_storage);
      _playbackService = PlaybackService(_storage, _playlistManager);
      _parentalPin = ParentalPin(_storage);
      _viewerProfileService =
          ViewerProfileService(_storage, _playlistManager, _playbackService);

      // Restores category lists (small, fast regardless of catalog size —
      // see that method's doc comment for why live channels/category
      // *items* are no longer touched here). Awaited, unlike before: the
      // freshness check right below needs isXtream/category state to
      // already be correct, so there's no way to let the UI go up first
      // this time.
      await _playlistManager.init();

      // Brand-new install, nothing configured yet — ask once up front
      // rather than leaving a new user to land on an empty TV/Movies/TV
      // Shows screen with no indication content has to be added via
      // Settings first. `needsFullSync()` below is always false with zero
      // playlists (nothing enabled to be stale), so this can't race or
      // double up with that prompt.
      if (_playlistManager.profiles.isEmpty) {
        _pendingAutoOpenAddPlaylist = await _confirmNewUserWantsPlaylist();
      }

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

      // Anything the pre-load above kicked off but didn't itself await
      // (a warm-up someone else started, a category still in flight)
      // finishes behind the splash rather than behind the real UI.
      // Reported directly, and the reason this is worth waiting for: the
      // app's crashes clustered in the first ~20 seconds of a cold start,
      // which is exactly when the catalog fetches, a video decoder
      // opening for the resumed channel, and the EPG parse all used to
      // run at once. The splash is time the user already expects to
      // spend; a half-populated UI that then falls over is not.
      await _waitForCategoriesToSettle();

      // A fixed floor on top of the real work above — on a very small
      // catalog (or M3U mode, which skips the pre-load entirely) that
      // work alone might finish in well under a second, too fast for the
      // splash's pulse animation to actually register at all.
      final elapsed = DateTime.now().difference(started);
      if (elapsed < _minSplashDuration) {
        await Future.delayed(_minSplashDuration - elapsed);
      }
      if (mounted) setState(() => _ready = true);
      // TEMPORARY — see the matching traceEpgTiming block below; this is
      // the reference point "UI active" actually means for that trace.
      unawaited(traceEpgTiming('_ready=true (splash gone, UI active)'));
      if (didSync) {
        // The toast needs the real MaterialApp's ScaffoldMessengerKey,
        // which doesn't exist until the tree above actually builds.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _showToast('Content updated'));
      }
      if (_pendingAutoOpenAddPlaylist) {
        // Same reasoning as the toast above — the real Navigator this
        // pushes onto doesn't exist until this build lands.
        _pendingAutoOpenAddPlaylist = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => const AddPlaylistScreen()));
        });
      }
      // `_epgService.init()` used to run strictly after
      // `_autoResumeLastChannel`, on the reasoning that it's "a heavy EPG
      // XML parse" that shouldn't run alongside the catalog still
      // settling — that reasoning no longer matches what `init()` actually
      // does: it reads the already-downloaded EPG cache from disk (a
      // `compute()`-decoded JSON file), not a live XML parse at all — the
      // real XML parse only happens in `refresh()`/`refreshAll()`, the
      // network-triggered update this call never touches. Reported
      // directly as EPG not appearing until ~58s after the UI was already
      // up and interactive — with no correctness reason left for EPG to
      // wait its turn behind auto-resume, running them concurrently
      // instead of strictly sequentially should recover whatever time was
      // lost purely to queue position, leaving only genuine decode time
      // (if any) as the real remaining cost.
      // TEMPORARY — tracing that same gap, alongside the matching
      // traceEpgTiming calls in EpgService.init() itself — both append to
      // the same file (nox_epg_trace.txt in the OS temp dir), though that
      // file turned out unreachable from this test device (no root, not
      // debuggable, and Android's own scoped-storage restriction blocks
      // adb from even its app-external directory) — kept only for
      // `debugPrint`'s own logcat line, on the chance a less locked-down
      // device can read it. Remove every traceEpgTiming call in this block
      // once the real bottleneck is confirmed found.
      unawaited(() async {
        await traceEpgTiming('post-splash chain start');
        await _playbackService.init();
        await traceEpgTiming('playbackService.init done');
        await Future.wait([
          _autoResumeLastChannel(),
          _epgService.init(),
        ]);
        await traceEpgTiming(
            'autoResumeLastChannel + epgService.init done (concurrent)');
        _epgService.startAutoRefresh(
            _storage.getRefreshInterval(), _epgSources);
        // No-op for most launches (no key set, or already refreshed this
        // week) — see PlaylistManager.refreshWhatsNewTmdbIfDue's doc
        // comment for why this is a launch-time due-check rather than an
        // in-process weekly timer.
        await _playlistManager.refreshWhatsNewTmdbIfDue();
      }());
    } catch (e) {
      // Surfaces any unexpected startup failure as a retryable screen
      // instead of leaving the app stuck on the splash spinner forever.
      if (mounted) setState(() => _bootstrapError = e.toString());
    }
  }

  /// Upper bound on how long the splash will hold for the catalog. A
  /// provider slow or broken enough to still be fetching after this has
  /// to be allowed to finish behind the UI instead — a splash that never
  /// ends is worse than a catalog that fills in late.
  static const _categorySettleTimeout = Duration(seconds: 30);

  Future<void> _waitForCategoriesToSettle() async {
    final deadline = DateTime.now().add(_categorySettleTimeout);
    while (_playlistManager.isLoadingCategories &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Used to start playing straight into whatever live channel was last
  /// playing — the same "turn it on and it's on the last channel" behavior
  /// MyTvOnline has — but that meant opening a real decoder and starting a
  /// network stream concurrently with the catalog/EPG load already running
  /// behind the splash, which was itself enough extra work to make the
  /// first 10-20s of a cold start feel sluggish. Reported directly. Now
  /// just finds the channel and hands it to [PlaybackService
  /// .setPendingResumeChannel] — `LiveResumeHint` surfaces it as a pill the
  /// user can act on (hold Right to actually start it), nothing opens
  /// unless they do. No-ops if something's already playing (a real user
  /// action on this launch beat the background load) or there's nothing to
  /// resume into.
  ///
  /// Scoped to live channels only (not movies/episodes): those are
  /// deliberate choices to open, a live channel is just "what's on".
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
    // visibleChannels, not the raw `channels` getter — a restricted
    // viewer's last-played channel may have had its group hidden since
    // they last watched (by whoever set up their profile), and silently
    // offering it to resume into would bypass that the same way an
    // unfiltered search result would.
    for (final channel in _playlistManager.visibleChannels(category: 'tv')) {
      if (channel.id == lastId) {
        _playbackService.setPendingResumeChannel(channel);
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

    // Reported directly, live, on *two* devices after the fix below was
    // first written: a solid white screen for several real seconds on
    // every cold launch — this fix's own regression, not the native-
    // launch-screen bug fixed separately (drawable/launch_background.xml).
    // `_ready`/`_syncPromptPending`/`_syncing` all start false, which is
    // exactly the state this method is in for Flutter's very *first*
    // build — called synchronously as part of the same initState() call
    // stack, before `_bootstrap()` (started, not awaited, from initState)
    // has run past its own first `await` and actually assigned
    // `_preferences`/`_catalogDb`/`_playlistManager`/`_epgService`/
    // `_playbackService`. The previous version of this method wrapped
    // *every* non-error branch in the MultiProvider below unconditionally
    // — including this exact "nothing has happened yet" initial state —
    // so that very first build referenced five still-uninitialized `late
    // final` fields and threw, repeatedly, on every rebuild attempt until
    // `_bootstrap()` finally caught up. This splash branch never actually
    // needed Provider access at all (pure local widget state throughout)
    // — kept outside the wrap below, same as the original structure
    // before that fix, for exactly the reason that structure had it there.
    if (!_ready && !_newUserPromptPending && !_syncPromptPending && !_syncing) {
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

    // Everything below only ever becomes reachable after
    // `_playlistManager.init()` (which itself runs after every `late
    // final` service field above is assigned) has already completed —
    // `_newUserPromptPending`/`_syncPromptPending`/`_syncing` are only ever
    // set true later in `_bootstrap()`, well past that point — so
    // referencing all of them in this MultiProvider is genuinely safe here,
    // unlike in the splash branch above.
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: _storage),
        Provider<CatalogDatabase>.value(value: _catalogDb),
        ChangeNotifierProvider<AppPreferences>.value(value: _preferences),
        ChangeNotifierProvider<PlaylistManager>.value(value: _playlistManager),
        ChangeNotifierProvider<EpgService>.value(value: _epgService),
        ChangeNotifierProvider<PlaybackService>.value(value: _playbackService),
        Provider<ParentalPin>.value(value: _parentalPin),
        ChangeNotifierProvider<ViewerProfileService>.value(
            value: _viewerProfileService),
      ],
      child: _buildReadyContent(context),
    );
  }

  Widget _buildReadyContent(BuildContext context) {
    if (_newUserPromptPending) {
      return WelcomeAddPlaylistScreen(onRespond: _respondToNewUserPrompt);
    }

    if (_syncPromptPending) {
      return CatalogSyncPromptScreen(
        lastSyncedAt: _oldestLastFullSyncAt(),
        onRespond: _respondToSyncPrompt,
      );
    }

    if (_syncing) {
      return CatalogSyncScreen(playlist: _playlistManager);
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
              // Windows-only equivalent — see DesktopPlayerScreen's own
              // doc comment for why it's a separate widget/holder rather
              // than reusing LiveResumeHint/PlaybackService.
              if (Platform.isWindows)
                DesktopLiveResumeHint(navigatorKey: _navigatorKey),
            ],
          ),
          // Always dark, regardless of the OS/system light-dark setting —
          // a deliberate streaming-app convention (Netflix/YouTube/Plex
          // all do this too), confirmed directly: "keep it always dark and
          // remove the toggle". No `darkTheme`/`themeMode` at all, so
          // there's nothing for a system-level light-mode change to flip.
          theme: ThemeData(
            brightness: Brightness.dark,
            colorScheme:
                buildPaletteColorScheme(prefs.palette, Brightness.dark),
            useMaterial3: true,
          ),
          home: Builder(
            builder: (context) {
              final useTv = prefs.layoutMode == 'tv' ||
                  (prefs.layoutMode == 'auto' &&
                      (prefs.isTelevision ||
                          MediaQuery.of(context).size.width >=
                              AppConstants.tvLayoutWidthThreshold));
              // `Consumer<ViewerProfileService>` plus a `ValueKey` on the
              // active viewer's id is what actually makes a profile switch
              // take effect on screen — nothing else in this ancestor
              // chain (just `Consumer<AppPreferences>` above) listens to
              // that service at all, so without this, `switchTo` would
              // update every service's own state correctly but the UI
              // would silently keep showing the OLD viewer's screen,
              // confirmed as a real gap during this feature's own review.
              // A full remount (not just a rebuild) is deliberate too —
              // see `ViewerProfileService.switchTo`'s doc comment: it's
              // what tears down `TvHomeScreen`'s own pending-hide timers
              // and resets its focus/selection state via a clean `dispose`
              // instead of needing dozens of fields manually reset.
              return Consumer<ViewerProfileService>(
                builder: (context, viewerService, _) {
                  final key = ValueKey(viewerService.active.id);
                  return useTv ? TvHomeScreen(key: key) : HomeScreen(key: key);
                },
              );
            },
          ),
        );
      },
    );
  }
}
