import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/tv_home_screen.dart';
import 'services/app_preferences.dart';
import 'services/epg_service.dart';
import 'services/playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/storage_service.dart';
import 'utils/constants.dart';
import 'utils/route_observer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

      _playlistManager = PlaylistManager(_storage);
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
        _autoResumeLastChannel();
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
  void _autoResumeLastChannel() {
    if (_playbackService.isPlayingSomething) return;
    final lastId = _storage.getLastChannelId();
    if (lastId == null) return;
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
