import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/tv_home_screen.dart';
import 'services/app_preferences.dart';
import 'services/catalog_database.dart';
import 'services/epg_service.dart';
import 'services/playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/storage_service.dart';
import 'utils/constants.dart';
import 'utils/route_observer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter's default ImageCache holds up to 1000 decoded images / ~100MB —
  // fine on a phone, but on a memory-constrained box (some Firesticks have
  // as little as ~1.7GB total RAM) that alone can be enough to trigger a
  // device-wide low-memory kill cascade while browsing a large catalog, even
  // with cacheWidth/cacheHeight shrinking each individual decoded image (see
  // PosterCard/channel_list_tile). A much tighter ceiling here means old
  // poster bitmaps actually get evicted instead of accumulating for the
  // whole session.
  //
  // Was 400/60MB, deliberately conservative while an OOM-crashing Firestick
  // was still an open question. Since then: that same build ran stable on a
  // *different* Firestick, a Formuler box handles a far bigger catalog with
  // zero issues, and a pre-rewrite build crashed on the same problem device
  // too — pointing at that specific unit's own memory/OS state, not catalog
  // size, as the actual cause. Combined with cached_network_image now
  // backing this (an eviction re-decodes from disk, not the network, so
  // it's cheaper than it used to be), there's real room to loosen this a
  // bit — kept as a moderate bump, not a removal of the ceiling, since this
  // is still a small/constrained class of hardware.
  PaintingBinding.instance.imageCache.maximumSize = 600;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20; // 100MB
  runApp(const NoxIptvApp());
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

class _NoxIptvAppState extends State<NoxIptvApp> {
  late final StorageService _storage;
  late final CatalogDatabase _catalogDb;
  late final AppPreferences _preferences;
  late final PlaylistManager _playlistManager;
  late final EpgService _epgService;
  late final PlaybackService _playbackService;
  bool _ready = false;

  /// Lets background work (the initial playlist load finishing, "Update
  /// content" finishing) show a brief toast without needing a BuildContext
  /// tied to whatever screen happens to be on top — same trick other IPTV
  /// players use for their "refresh complete" notification.
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  final String _splashStatus = 'Starting...';
  String? _bootstrapError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() => _bootstrapError = null);
    try {
      _storage = StorageService();
      await _storage.init();

      _preferences = AppPreferences(_storage);
      await _preferences.init();

      _catalogDb = CatalogDatabase();

      _playlistManager = PlaylistManager(_storage, _catalogDb);
      _epgService = EpgService(_storage);
      _playbackService = PlaybackService(_storage, _preferences);

      // The home screen goes up now, not after everything below finishes —
      // matching how other IPTV players (MyTvOnline, IPlayer) open
      // straight into the UI and refresh in the background instead of
      // blocking behind a splash. HomeScreen/TvHomeScreen already have
      // their own loading affordances (spinners, the catalog warm-up
      // banner, empty states) for exactly this transitional state.
      if (mounted) setState(() => _ready = true);

      unawaited(_playlistManager.init().then((_) {
        unawaited(_autoResumeLastChannel());
        _showToast('Content updated');
      }));
      unawaited(_epgService.init());
      unawaited(_playbackService.init());

      final epgUrl = _storage.getEpgUrl();
      if (epgUrl != null && epgUrl.isNotEmpty) {
        _epgService.startAutoRefresh(_storage.getRefreshInterval(), epgUrl);
      }
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
        _playbackService.play(channel);
        return;
      }
    }
  }

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
                  const Icon(Icons.error_outline, color: Colors.white70, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Startup failed:\n$_bootstrapError',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _bootstrap, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 16),
                Text(_splashStatus, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ),
      );
    }

    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: _storage),
        Provider<CatalogDatabase>.value(value: _catalogDb),
        ChangeNotifierProvider<AppPreferences>.value(value: _preferences),
        ChangeNotifierProvider<PlaylistManager>.value(value: _playlistManager),
        ChangeNotifierProvider<EpgService>.value(value: _epgService),
        ChangeNotifierProvider<PlaybackService>.value(value: _playbackService),
      ],
      child: Consumer<AppPreferences>(
        builder: (context, prefs, _) {
          return MaterialApp(
            title: AppConstants.appName,
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: _scaffoldMessengerKey,
            navigatorObservers: [appRouteObserver],
            themeMode: prefs.themeMode,
            theme: ThemeData(
              brightness: Brightness.light,
              colorSchemeSeed: prefs.palette.primary,
              useMaterial3: true,
            ),
            darkTheme: ThemeData(
              brightness: Brightness.dark,
              colorSchemeSeed: prefs.palette.primary,
              useMaterial3: true,
            ),
            home: Builder(
              builder: (context) {
                final useTv = prefs.layoutMode == 'tv' ||
                    (prefs.layoutMode == 'auto' &&
                        MediaQuery.of(context).size.width >= AppConstants.tvLayoutWidthThreshold);
                return useTv ? const TvHomeScreen() : const HomeScreen();
              },
            ),
          );
        },
      ),
    );
  }
}
