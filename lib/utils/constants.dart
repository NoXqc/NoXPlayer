import 'package:flutter/material.dart';

import '../models/cyberpunk_palette.dart';

/// App-wide constants: display strings, theme seed, and the SharedPreferences
/// keys used by [StorageService]. Centralized here so key names never drift
/// between the services that read and write them.
class AppConstants {
  static const String appName = 'NoXPlayer';
  static const Color seedColor = Colors.deepPurple;

  /// Screen width above which "auto" layout mode switches to the TV UI.
  /// Real TVs/boxes routinely report >=1200 logical px in landscape;
  /// phones and even large tablets stay below it. Also used to decide
  /// whether the fullscreen player should touch orientation at all — see
  /// PlayerScreen's doc comment on why forcing portrait on a TV-sized
  /// screen is actively harmful, not just pointless.
  static const double tvLayoutWidthThreshold = 1200;

  /// Fresh-install default for [AppPreferences.layoutMode] — a user can
  /// always override it in Settings > Theme regardless. Baked in at build
  /// time (`--dart-define=DEFAULT_LAYOUT_MODE=tv`) rather than a runtime
  /// check, so the universal APK (built for TV boxes/Firesticks, where
  /// "auto" detection isn't reliable on non-certified hardware) can default
  /// straight to the TV layout, while the phone/arm64 build keeps "auto".
  static const String defaultLayoutMode =
      String.fromEnvironment('DEFAULT_LAYOUT_MODE', defaultValue: 'auto');

  /// Shown in Settings > Advanced — a human-readable stamp of which build
  /// is actually running, bumped by hand on every build. Exists because
  /// Android's own versionCode/install flow isn't always a reliable signal
  /// on non-Google package installers (some skip reinstalling an APK with
  /// an unchanged versionCode, silently keeping the old binary even though
  /// the user just "installed" the new file) — this reads whatever code
  /// is actually running, independent of any of that.
  static const String buildMarker =
      '3.13.1 — fixed the category-load concurrency cap: it capped '
      'workers per *call*, but every category starting/finishing calls '
      'notifyListeners(), which triggers a rebuild, which called it '
      'again — so a fresh batch of 3 kept stacking on top of whatever '
      'was already loading instead of actually staying capped at 3. '
      'Confirmed on real hardware as not crashing but not meaningfully '
      'faster either. Now checks the live in-flight count directly, so '
      'it holds the real ceiling regardless of how often it\'s re-'
      'entered.';

  // SharedPreferences keys.
  static const String keyM3uUrl = 'nox_m3u_url';
  static const String keyEpgUrl = 'nox_epg_url';
  static const String keyRefreshInterval = 'nox_refresh_interval_minutes';
  static const String keyThemeMode = 'nox_theme_mode';
  static const String keyFavorites = 'nox_favorites';
  static const String keyFavoriteSeries = 'nox_favorite_series';
  static const String keyHiddenGroups = 'nox_hidden_groups';
  static const String keyFavoritedGroups = 'nox_favorited_groups';
  static const String keyRecentSearches = 'nox_recent_searches';
  static const String keyEpgCache = 'nox_epg_cache';
  static const String keyEpgLastUpdated = 'nox_epg_last_updated';
  static const String keyLastChannelId = 'nox_last_channel_id';
  static const String keyLastPositionPrefix = 'nox_last_position_';
  static const String keyLastDurationPrefix = 'nox_last_duration_';

  // Playlist source mode: 'm3u' (direct URL) or 'xtream' (Xtream Codes XC API).
  static const String keyPlaylistMode = 'nox_playlist_mode';
  static const String keyXtreamServer = 'nox_xtream_server';
  static const String keyXtreamUsername = 'nox_xtream_username';
  static const String keyXtreamPassword = 'nox_xtream_password';

  static const String keyShowClock = 'nox_show_clock';
  static const String keyPaletteId = 'nox_palette_id';

  /// UI layout: 'auto' picks phone vs TV by screen size, 'phone'/'tv' force
  /// one regardless — needed because plenty of real Android boxes (this
  /// one included) aren't officially certified Android TV devices, so
  /// there's no fully reliable automatic signal for "this is a TV".
  static const String keyLayoutMode = 'nox_layout_mode';

  /// "Enable/disable playlist" — lets a user free up a provider's
  /// connection slot for another device without touching the cached
  /// catalog or credentials on this one.
  static const String keyPlaylistEnabled = 'nox_playlist_enabled';

  /// Duo-tone accent palettes offered in Settings > Theme — replaced the
  /// old flat single-color presets, which couldn't represent a deliberate
  /// two-hue "cyberpunk" accent (Material's `ColorScheme.fromSeed` only
  /// derives one hue's tonal ramp). "Dark/Gold" is deliberately the most
  /// restrained of the four — muted rather than neon — so there's a safe
  /// option for a shared device an older user might also use.
  static const List<CyberpunkPalette> cyberpunkPalettes = [
    CyberpunkPalette(
      id: 'purple_magenta',
      label: 'Purple / Magenta',
      primary: Color(0xFF7C3AED),
      secondary: Color(0xFFE91E8C),
    ),
    CyberpunkPalette(
      id: 'red_blue',
      label: 'Red / Blue',
      primary: Color(0xFFE5393F),
      secondary: Color(0xFF2979FF),
    ),
    CyberpunkPalette(
      id: 'green_orange',
      label: 'Green / Orange',
      primary: Color(0xFF76FF03),
      secondary: Color(0xFFFF6D00),
    ),
    CyberpunkPalette(
      id: 'dark_gold',
      label: 'Dark / Gold',
      primary: Color(0xFFD4AF37),
      secondary: Color(0xFF8C6D1F),
    ),
  ];

  // On-disk cache file names (under the OS temp/cache directory — safe to
  // lose; the app just re-fetches from the network if they're missing).
  static const String cacheFileM3uChannels = 'm3u_channels';
  static const String cacheFileLiveChannels = 'xtream_live_channels';
  static const String cacheFileLiveCategories = 'xtream_live_categories';
  static const String cacheFileVodCategories = 'xtream_vod_categories';
  static const String cacheFileSeriesCategories = 'xtream_series_categories';
  // Per-category VOD/series *items* (not just the category list above) live
  // in CatalogDatabase (a real local database) now, not a JSON file per
  // category — see that class's doc comment for why.

  /// EPG programme cache. Was a SharedPreferences string (`keyEpgCache`,
  /// kept below only so `clearCache` can sweep away any leftover value
  /// from before this changed) — SharedPreferences backs onto a single XML
  /// file the OS loads whole, which is a bad fit for a full-catalog EPG
  /// blob that can be many MB; moved to the same disk-file cache the
  /// playlist/catalog data already uses.
  static const String cacheFileEpgPrograms = 'epg_programs';

  static const int defaultRefreshIntervalMinutes = 30;
  static const List<int> refreshIntervalOptions = [15, 30, 60, 120];
}
