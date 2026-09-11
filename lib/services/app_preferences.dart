import 'package:flutter/material.dart';

import '../models/cyberpunk_palette.dart';
import '../utils/constants.dart';
import 'storage_service.dart';

/// App-wide UI/behavior preferences (theme, clock, layout mode, whether
/// this device is allowed to play anything right now).
///
/// Replaces manually threading 8 separate value/callback constructor
/// params through every screen that touches a setting — with the growing
/// number of settings screens, that had become the classic "prop drilling"
/// problem Provider exists to solve. Screens just `watch<AppPreferences>()`
/// and call a setter; everything persists itself.
class AppPreferences extends ChangeNotifier {
  AppPreferences(this._storage);

  final StorageService _storage;

  late ThemeMode themeMode;
  late bool showClock;
  late CyberpunkPalette palette;
  late String layoutMode; // 'auto', 'phone', 'tv'
  late bool playlistEnabled;

  Future<void> init() async {
    themeMode = _storage.getThemeMode() == 'light' ? ThemeMode.light : ThemeMode.dark;
    showClock = _storage.getShowClock();
    palette = _paletteById(_storage.getPaletteId());
    layoutMode = _storage.getLayoutMode();
    playlistEnabled = _storage.getPlaylistEnabled();
  }

  CyberpunkPalette _paletteById(String id) => AppConstants.cyberpunkPalettes
      .firstWhere((p) => p.id == id, orElse: () => AppConstants.cyberpunkPalettes.first);

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    _storage.setThemeMode(mode == ThemeMode.light ? 'light' : 'dark');
    notifyListeners();
  }

  void setShowClock(bool value) {
    showClock = value;
    _storage.setShowClock(value);
    notifyListeners();
  }

  void setPalette(CyberpunkPalette newPalette) {
    palette = newPalette;
    _storage.setPaletteId(newPalette.id);
    notifyListeners();
  }

  void setLayoutMode(String mode) {
    layoutMode = mode;
    _storage.setLayoutMode(mode);
    notifyListeners();
  }

  /// Whether this device is allowed to start/continue playback — the
  /// "enable/disable playlist" feature: flipping this off frees up a
  /// provider's connection slot (many panels cap concurrent streams) for
  /// another device, without touching the cached catalog or credentials.
  void setPlaylistEnabled(bool value) {
    playlistEnabled = value;
    _storage.setPlaylistEnabled(value);
    notifyListeners();
  }
}
