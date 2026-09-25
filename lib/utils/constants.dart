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

  /// Fresh-install default for [AppPreferences.guideViewMode] — 'live'
  /// (the original single-channel now/next view) or 'timeline' (the
  /// cable-guide grid). Always overridable in Settings > Theme.
  static const String defaultGuideViewMode = 'live';

  // SharedPreferences keys.
  //
  // keyM3uUrl/keyEpgUrl/keyXtreamServer.../keyPlaylistMode/
  // keyPlaylistEnabled/the global keyHiddenGroups/keyFavoritedGroups/
  // keySyncFrequencyDays/keyLastFullSyncAt below are LEGACY —
  // pre-multi-playlist, single global scalars. Nothing writes them
  // anymore; they're read exactly once, by
  // PlaylistManager._migrateLegacySinglePlaylist, to build the one
  // PlaylistProfile an upgrading install starts with. Kept (not deleted)
  // as a cheap fallback during early rollout of that migration.
  static const String keyM3uUrl = 'nox_m3u_url';
  static const String keyEpgUrl = 'nox_epg_url';
  static const String keyRefreshInterval = 'nox_refresh_interval_minutes';
  static const String keyThemeMode = 'nox_theme_mode';
  static const String keyFavorites = 'nox_favorites';
  static const String keyFavoriteSeries = 'nox_favorite_series';
  static const String keyHiddenGroups = 'nox_hidden_groups';

  /// Per-channel hide, scoped to live TV only — for duplicate feeds a
  /// provider lists within an otherwise-wanted group (e.g. the same
  /// channel in both HD and HEVC), where hiding the whole group isn't
  /// an option. Namespaced per playlist exactly like [keyHiddenGroups].
  static const String keyHiddenChannels = 'nox_hidden_channels';
  static const String keyFavoritedGroups = 'nox_favorited_groups';
  static const String keyRecentSearches = 'nox_recent_searches';

  /// The JSON-encoded `List<PlaylistProfile>` — the whole multi-playlist
  /// list lives in one SharedPreferences string, same "small scalar" shape
  /// as everything else in this section (unlike the EPG cache, which is
  /// genuinely large and lives in a disk cache file instead — see
  /// cacheFileEpgPrograms below). Deliberately NOT a cache file: this has
  /// to survive `StorageService.clearCache()`, which wipes the whole
  /// OS-reclaimable cache directory on purpose.
  static const String keyPlaylists = 'nox_playlists';

  /// One-time guard so `PlaylistManager._migrateLegacySinglePlaylist` only
  /// ever runs once per install, even across many future launches.
  static const String keyMigratedToMultiPlaylist =
      'nox_migrated_multi_playlist';
  static const String keyEpgCache = 'nox_epg_cache';
  static const String keyEpgLastUpdated = 'nox_epg_last_updated';
  static const String keyLastChannelId = 'nox_last_channel_id';
  static const String keyLastPositionPrefix = 'nox_last_position_';
  static const String keyLastDurationPrefix = 'nox_last_duration_';

  /// LEGACY global scalar — when the last full catalog sync completed.
  /// Per-playlist now (`'${keyLastFullSyncAt}_$playlistId'`, read/written
  /// via `StorageService.getLastFullSyncAt(playlistId)`/
  /// `setLastFullSyncAt`); this bare key is only read once, during
  /// migration. See PlaylistManager.needsFullSync/runFullCatalogSync.
  static const String keyLastFullSyncAt = 'nox_last_full_sync_at';

  /// LEGACY global scalar — "how often" for the above. Per-playlist now,
  /// as `PlaylistProfile.syncFrequencyDays`; this bare key is only read
  /// once, during migration. `defaultSyncFrequencyDays`/
  /// `syncFrequencyDaysOptions` below are still live — they're
  /// `PlaylistProfile.syncFrequencyDays`'s default value and the dropdown
  /// options in its detail-panel UI, not tied to this legacy key.
  static const String keySyncFrequencyDays = 'nox_sync_frequency_days';
  static const int defaultSyncFrequencyDays = 3;
  static const List<int> syncFrequencyDaysOptions = [1, 3, 7, 10, 14];

  // LEGACY global scalars — one playlist's mode/login, superseded by
  // PlaylistProfile. Only read once, during migration.
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

  /// Live TV presentation: 'live' (single-channel now/next) or 'timeline'
  /// (cable-guide grid, all visible channels at once).
  static const String keyGuideViewMode = 'nox_guide_view_mode';

  /// LEGACY global scalar — "enable/disable playlist" (freeing a
  /// provider's connection slot for another device without touching
  /// cached catalog/credentials). Per-playlist now, as
  /// `PlaylistProfile.enabled`; this bare key is only read once, during
  /// migration.
  static const String keyPlaylistEnabled = 'nox_playlist_enabled';

  /// Duo-tone accent palettes offered in Settings > Theme — replaced the
  /// old flat single-color presets, which couldn't represent a deliberate
  /// two-hue "cyberpunk" accent (Material's `ColorScheme.fromSeed` only
  /// derives one hue's tonal ramp). "Dark/Gold" is deliberately the most
  /// restrained of the four — muted rather than neon — so there's a safe
  /// option for a shared device an older user might also use.
  static const List<CyberpunkPalette> cyberpunkPalettes = [
    // First entry is the fresh-install default — see
    // StorageService.getPaletteId's fallback and AppPreferences._paletteById's
    // orElse, both of which fall back to cyberpunkPalettes.first.
    //
    // primary/secondary here are the same purple/magenta as the
    // Purple/Magenta entry below — not shown as a colored gradient/fill
    // anywhere (see CyberpunkPalette.isMinimal), just kept as the
    // wordmark's own accent so it isn't plain white too.
    CyberpunkPalette(
      id: 'minimal',
      label: 'Minimalist',
      primary: Color(0xFF7C3AED),
      secondary: Color(0xFFE91E8C),
      isMinimal: true,
    ),
    CyberpunkPalette(
      id: 'red_blue',
      label: 'Red / Blue',
      primary: Color(0xFFE5393F),
      secondary: Color(0xFF2979FF),
    ),
    CyberpunkPalette(
      id: 'purple_magenta',
      label: 'Purple / Magenta',
      primary: Color(0xFF7C3AED),
      secondary: Color(0xFFE91E8C),
    ),
    // Replaced the old Green / Orange palette (id 'green_orange', still
    // mapped to this one — see AppPreferences._paletteById). Bleu-blanc-
    // rouge: the red is the Canadiens' own C8102E; the blue is lifted well
    // above the team's near-navy so the wordmark gradient and focus glow
    // stay readable on this UI's black backgrounds. The white is the
    // focus/selected color (see CyberpunkPalette.highlight).
    CyberpunkPalette(
      id: 'habs',
      label: 'Habs',
      primary: Color(0xFFC8102E),
      secondary: Color(0xFF1F4FD8),
      highlight: Colors.white,
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
