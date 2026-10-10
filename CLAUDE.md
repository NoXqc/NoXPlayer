# VesperTV — working notes for Claude Code

Flutter IPTV player (M3U + Xtream Codes, XMLTV EPG) for Android phones, Android TV boxes
(Formuler) and Fire Sticks. Package `com.nox.nox_iptv`. GPL-3.0, open source, always free.
Repo: https://github.com/NoXqc/VesperTV — site: https://vespertv.app (GitHub Pages from `docs/`).
Community: Discord https://discord.gg/DDeGDHvFY.

The owner tests on real devices and reports back with phone photos of the TV. Most bugs here
only show up on the real boxes (weak GPUs/CPUs, D-pad remotes), so emulators/tests are not
a substitute. Keep replies short; make routine calls yourself.

## Layout (what matters)
- `lib/main.dart` — bootstrap + splash, layout choice (TV vs phone).
- `lib/screens/tv_home_screen.dart` — the whole TV UI (tabs, groups, live list, Timeline guide,
  Movies/TV Shows browse + hero). Huge file, full of load-bearing comments. Read them.
- `lib/services/playlist_manager.dart` / `playlist_session.dart` — per-playlist state, catalog
  loading, hidden groups/channels, backup-server failover. `playback_service.dart`,
  `epg_service.dart`, `catalog_database.dart` (sqflite), `storage_service.dart` (prefs/cache).
- `lib/widgets/poster_card.dart`, `hold_to_activate.dart`, `player_controls.dart`.
- Palettes: `lib/utils/constants.dart` (`cyberpunkPalettes`), `lib/utils/tv_theme.dart`.
- `docs/index.html` — marketing site.

## Build / check
- `flutter analyze` — baseline is **25 info-level issues**, none errors. Don't add new ones.
- `flutter build apk --release`
- Only run `dart format` on files you edited (`dart format lib` reformats unrelated files).

## Signing (READ BEFORE BUILDING A RELEASE)
- `android/key.properties` + the `.jks` keystore are **git-ignored secrets**. Alias `noxplayer`.
  `storeFile` in key.properties is an **absolute path for that machine** — edit it per OS
  (Windows: forward slashes, e.g. `C:/Users/<you>/keystores/noxplayer-release.jks`).
- If key.properties is missing/wrong the build **silently signs with the debug key** — that APK
  cannot install over a real install. Always verify:
  `apksigner verify --print-certs app-release.apk` → SHA-256 must be
  `c92a346ac5b6191a373b3572fa0fbd72abdd5f64db497bd321617b8cc4562431`.
- Never commit the keystore/passwords. Losing the key = existing installs can never update.

## Release workflow
1. Bump `version:` in `pubspec.yaml` (`x.y.z+build`) — Settings shows it, and the in-app updater
   compares against the release **tag_name**.
2. Build, verify signature (above), **commit + push source first**.
3. Update the latest GitHub release in place (don't cut a new release per test build):
   `gh release upload <tag> build/app/outputs/flutter-apk/app-release.apk --clobber`
   then `gh release edit <tag> --tag <new-version> --title "VesperTV <ver>" --notes "..."`.
   The tag must be renamed to the new version or Check for Updates says "up to date".
4. **Gotcha:** `gh release edit --tag` leaves the old tag behind and the new tag lands on
   whatever `main` was — so commit/push before step 3, and confirm with
   `git ls-remote --tags origin <ver>`. To repoint a tag in place:
   `gh api -X PATCH repos/NoXqc/VesperTV/git/refs/tags/<tag> -f sha=<full-sha> -F force=true`.
5. Experimental builds → `--prerelease` (excluded from `/releases/latest`, so the Downloader code
   and Check for Updates skip them). Promote later with
   `gh release edit <tag> --prerelease=false --latest`.
6. Verify what users actually get: download
   `https://github.com/NoXqc/VesperTV/releases/latest/download/app-release.apk` and compare
   `sha256sum` with the local build; and `curl -sL http://go.aftvnews.com/1760256 | grep -o https://github[^"' ]*`
   must show that same URL. **Downloader code: `1760256`** (AFTVnews). Old code 7815226 was pinned to 3.20.1 — dead.
Only release when the owner asks ("update the latest", "fully release").

## Test devices (adb over LAN)
- Formuler Z11 Pro MAX `10.0.0.46:5555` (IP changes with VPN/network toggles — has also been seen
  at `192.168.1.46:5555`). Fire Stick `192.168.1.33:5555` (was `10.0.0.94:5555`).
- First connect from a new PC pops an "Allow USB/ADB debugging?" dialog on the TV — accept "always".
- Install with `adb install -r` (GUI installers silently fail on the Formuler):
  ```
  adb connect 10.0.0.46:5555
  adb -s 10.0.0.46:5555 install -r build/app/outputs/flutter-apk/app-release.apk
  adb -s 10.0.0.46:5555 shell am start -n com.nox.nox_iptv/.MainActivity
  ```
  (Fire Stick: same with `192.168.1.33:5555`. If the Formuler's IP changed after a reboot, check
  its Settings > Network for the new address and update this file.)
  Verify: `adb shell pm path com.nox.nox_iptv` then `adb shell sha256sum <path>` vs local build.
- "Crashes" on these boxes are usually **ANRs**: `adb shell dumpsys dropbox --print data_app_anr`
  (and `data_app_crash`). `top -H -b -n 1 -p <pid>` shows busy threads.
- Don't `adb install` when the owner says not to (they sometimes test from a separate box).

## Hard-won rules (don't re-learn these)
- **Cold-start splash is deliberately slow (~20-25s with a big second playlist).** Entering the UI
  early lets remote input crash weak boxes. Do not cap/shorten it (`_bootstrap` in main.dart).
- **D-pad focus:** default directional traversal is unreliable across differently shaped columns/
  rows — use explicit dispatch (`_moveColumnFocus`, the Timeline guide's own Up/Down/Left/Right).
  No per-row `FocusScope`. Any programmatic scroll uses `jumpTo`, never `animateTo` (caused an
  ANR-length freeze on a big list). Pause periodic timers when covered (`RouteAware`).
  Remote "hold Select" = `HoldToActivate`; `InkWell.onLongPress` is touch-only.
- **Fire OS's on-screen keyboard swallows the physical Back button — known, unfixable limitation.**
  Confirmed via a raw `getevent` capture (clean `KEY_BACK`) plus Flutter-side logging of
  `logicalKey.keyId`: pressing Back on a Fire TV remote while the on-screen keyboard has D-pad
  focus never reaches the app as Back/Escape/browserBack at all. Fire OS's own keyboard overlay
  intercepts it first and resynthesizes it as ordinary keyboard-internal D-pad navigation
  (arrowRight/arrowDown moving the on-screen selector) immediately followed by a synthetic
  `numpadEnter` — indistinguishable, by the time Flutter sees it, from the user genuinely
  navigating the keyboard and pressing Enter on purpose. That synthetic Enter is what fires
  `TextField.onSubmitted`/`TextInputAction.next`, advancing focus to the next field instead of
  closing the keyboard. No app-level fix exists — the information needed (was this really Back?)
  is already gone before our code gets the event. A Formuler box does not have this problem
  (reported directly: Back closes its keyboard normally).
- **A plain focusable widget (not a text field) competes with Flutter's own default directional
  traversal — `HardwareKeyboard.instance.addHandler` loses that race.** `add_playlist_screen.dart`'s
  `_handleFieldEscapeKey` reliably overrides arrow keys while a *text field* has focus only because
  `EditableText` swallows arrow keys internally, leaving no default traversal to compete with. For
  a non-text-field widget (e.g. `ModeButton`), default traversal is still live and runs anyway,
  silently overriding a raw handler's `requestFocus()` a moment later (confirmed on real hardware:
  jumped straight past the intended target to the app bar). Use `CallbackShortcuts` instead for
  that case — it intercepts the key before default traversal gets a turn at all, rather than
  racing against it afterward.
- **Never call `notifyListeners()` mid-build.** `PlaylistManager.notifyListeners` now defers
  anything fired during the build phase — this fixed Group Management checkmarks not repainting
  until you switched tabs. Keep it that way.
- Composite `Channel.id` (`playlistId::rawId`) vs raw `Channel.rawId`: EPG lookups and
  `Channel.isLiveId` need **rawId**.
- Back button: walks content → groups → tabs, exits the app only from the tabs column
  (`PopScope` in TvHomeScreen).
- Release APK also drives the "live island" pill / mini player; see comments before touching
  `PlaybackService` controller sharing (one shared controller across preview/fullscreen/pill).

## Features worth knowing
- **Timeline guide** (Settings > Theme > Live TV guide = `guideViewMode` 'live'|'timeline'):
  `_TimelineGuide*` in tv_home_screen.dart. Left/Right step 30-minute slots (`moveHorizontal`),
  Up/Down keep the time column (live "now" for a currently-airing block), entering from groups
  and returning from fullscreen restore focus at the current time, long blocks keep a sticky label,
  rows with no EPG show a placeholder, hold-Select opens a favourite/hide menu.
- **Hide individual live channels** (per playlist, `hiddenChannels`), unhide in
  Settings > Playlist Manager > Hidden Channels. Group hiding is separate.
- **Movies/TV Shows:** smaller posters, bigger hero; hero description fetched after a 400 ms dwell
  and cached in `PlaylistManager` (shared with the detail screens).
- **Backup servers:** connect tries last-working → main → backups (one pass); live stream *open*
  failures retry other servers. Mid-stream drops do not fail over. Sticks to last-working server.
- **Palettes:** duo-tone `primary`/`secondary`; optional `highlight` replaces the scheme primary
  (Habs uses white). Old id `green_orange` maps to `habs`.
- **Viewer profiles** (`ViewerProfile`, `ViewerProfileService`): several viewers sharing one
  device's playlists, each with their own favorites/hidden-groups/watch-history. Main's data lives
  under every *existing* unsuffixed storage key, completely unchanged — never add a step that
  rewrites Main's keys on upgrade; a second-or-later viewer's keys get `__vp_<id>` appended by
  `StorageService._vk`/`_vkp` instead (position/duration keys keep the suffix at the very end, not
  after the prefix, so `clearCache()`'s `startsWith` sweep still catches every viewer's). A
  restricted ("kid") viewer uses a *shown-groups allowlist* (`keyShownGroups`), not the blocklist
  every other viewer uses — see `PlaylistSession._loadViewerScopedState`'s doc comment for why a
  new category must default to hidden for them, not visible. `CatalogDatabase`'s own `is_favorite`
  column stopped being the favorite source of truth (it can't represent more than one viewer) —
  `PlaylistManager` injects a live callback (`isVodFavorite`/`isSeriesFavorite`) instead; only write
  that column while Main is active (downgrade insurance, not correctness-load-bearing).
  `ViewerProfileService.requireUnlock` is the single PIN choke point for *opening Settings at all*
  from a restricted profile — not screen-by-screen inside it. Any direct, non-Settings control that
  can un-hide something (the TV live-channel long-press menu's "Unhide" option is the one real
  example found so far) needs its own `requireUnlock` check at the point of the action instead,
  since it never passes through the Settings gate to begin with — audit any *new* one the same way
  before assuming the Settings gate alone covers it. A profile switch (`switchTo`) stops playback
  *before* flipping the active viewer id (so the final position save lands under the old viewer),
  then calls `PlaylistManager.applyActiveViewer`/`PlaybackService.reloadForViewer` to re-derive
  everything else from storage with no network access — and only takes visible effect because
  `main.dart` wraps the home screen in `Consumer<ViewerProfileService>` keyed by the active viewer's
  id, which remounts `TvHomeScreen`/`HomeScreen` from scratch (clean dispose of pending-hide timers,
  focus state, etc.) — that `Consumer`/key is the one thing that makes a switch actually show up on
  screen; nothing else up the tree listens to this service at all.

## Git
- Commit only when asked; end commit messages with the attribution trailer Claude Code provides.
- Never `--no-verify`, never force-push `main`.
- Local junk (`nox_*.png` screenshots, `*.apk`) is git-ignored on purpose.
