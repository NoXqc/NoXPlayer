# VesperTV — working notes for Claude Code

Read this first in any fresh session. It is the project's memory: what it is, how to build/ship it,
the rules that were learned the hard way, and every bug that has already been fixed (so it doesn't
get re-introduced or re-investigated).

## 1. What this is
Flutter IPTV player (M3U + Xtream Codes, XMLTV EPG) for **Android phones, Android TV boxes
(Formuler), Fire Sticks, and Windows 10/11 PCs**. GPL-3.0, open source, always free, no ads, no
tracking, bring-your-own playlist (the app ships no channels).

- **Name:** VesperTV (formerly **NoXPlayer**; "NoX TV Player" in some UI text). Renamed in Oct 2026
  because "NoXPlayer" collided with a well-known Android emulator that had a malware scandal.
  "Vesper" = evening star; brand is **black + gold**, logo is a gold "V" with a four-point star.
- **Repo:** https://github.com/NoXqc/VesperTV (renamed from `NoXqc/NoXPlayer`; GitHub auto-redirects
  web/API/git/download URLs from the old name — **never create a new repo called `NoXPlayer`**, it
  would break those redirects for every old install and link).
- **Site:** https://vespertv.app (GitHub Pages from `docs/`, HTTPS enforced). DNS is at Cloudflare,
  4 `A` records (185.199.108-111.153) on the apex + `www` CNAME → `noxqc.github.io`, all
  **DNS only / grey cloud** (an orange proxy cloud breaks Pages' certificate issuance). `docs/CNAME`
  = `vespertv.app`. The old `noxplayertv.com` site is gone.
- **Community:** Discord https://discord.gg/DDeGDHvFY. **Downloader (AFTVnews) code: `1760256`**.
- **Package / identifiers deliberately NOT renamed** (renaming would orphan every install's data and
  break in-place updates): Android `applicationId` `com.nox.nox_iptv`, Dart package `nox_iptv`,
  Windows exe `nox_iptv.exe`, signing alias `noxplayer`, SharedPreferences keys, cache names like
  `noxplayer_posters`. Only user-visible strings, icons, URLs and docs were renamed.

**The owner** tests on real devices and sends phone photos/screenshots of the TV. Most bugs only show
up on real boxes (weak CPUs, D-pad remotes, Fire OS quirks) — emulators/tests are not a substitute.
Keep replies short; make routine calls yourself; **confirm before anything destructive or
outward-facing** (deleting releases, force-pushes, posting). Only commit/release when asked.

## 2. Start-here checklist for a clean session
1. `git pull`, then `git status` (ignore the untracked `*-windows-x64.zip` and
   `third_party/video_player_android/pubspec.lock` — local artifacts).
2. Machine facts (Windows PC): repo `C:\Users\aarse\NoXPlayer`; Flutter `C:\src\flutter`; JDK 17;
   Android SDK `C:\Android\Sdk`; apksigner `C:\Android\Sdk\build-tools\36.0.0\apksigner.bat`;
   keystore `C:\Users\aarse\keystores\noxplayer-release.jks` via git-ignored `android\key.properties`
   (originals also on drive `E:\`). Files are CRLF here (autocrlf) — "LF will be replaced by CRLF"
   warnings are normal. `flutter pub get` dirties generated plugin files under linux/macos/windows —
   `git checkout` them before committing.
3. Use Bash (Git Bash) or PowerShell. In Git Bash, **prefix adb commands that take `/sdcard`-style
   paths with `MSYS_NO_PATHCONV=1`** (it mangles them). Big multi-line heredocs sometimes break the
   Bash tool — write a script file with the Write tool and run that instead.
4. `flutter analyze` must report the baseline **22** info-level issues (no errors). Don't add new ones.
5. Check the current state of releases: `gh release list` (latest should be `3.53.0` unless noted
   in §11).

## 3. Layout (what matters)
- `lib/main.dart` — bootstrap + splash, layout choice (TV vs phone), welcome/add-playlist prompt for
  new users, Windows `window_manager` init, post-splash auto-resume of the last channel.
- `lib/screens/tv_home_screen.dart` — the whole TV UI (tabs, groups, live list, Timeline guide,
  Movies/TV Shows browse + hero, Windows Minimize/Close rows). Huge file, full of load-bearing
  comments. Read them.
- `lib/screens/player_screen.dart` + `lib/widgets/player_controls.dart` — Android/TV fullscreen
  player (primary row, chevron-revealed secondary row, quality/FPS/audio-channel badges).
- `lib/screens/multiview_screen.dart` — 2-stream Multiview (sidebar warnings, channel picker with
  group+search+EPG-now subtitle). Windows has its own `desktop_multiview_screen.dart`.
- `lib/screens/desktop_player_screen.dart`, `lib/services/desktop_mini_player.dart`,
  `lib/widgets/desktop_live_resume_hint.dart` — the **entirely separate Windows playback stack**
  (`media_kit`). Android uses `video_player_hdr` + `PlaybackService`/`PlayerScreen`. Changes to one do
  not affect the other; features must be built twice.
- `lib/services/playlist_manager.dart` / `playlist_session.dart` — per-playlist state, catalog
  loading, hidden groups/channels, backup-server failover. `playback_service.dart`,
  `epg_service.dart`, `catalog_database.dart` (sqflite), `storage_service.dart` (prefs/cache),
  `app_update_service.dart` (GitHub release updater).
- `lib/screens/settings/*` — Settings screens (Add Playlist is a 3-pane LokTV-style layout).
- `lib/screens/welcome_add_playlist_screen.dart` — first-launch "Hey beautiful Human" prompt.
- `lib/widgets/`: `poster_card`, `hold_to_activate`, `live_resume_hint`, `tv_menu_tile`,
  `mode_button`, `pin_pad`, `sidebar`, `epg_guide`.
- Palettes: `lib/utils/constants.dart` (`cyberpunkPalettes`, `AppConstants.appName`),
  `lib/models/cyberpunk_palette.dart`, `lib/utils/tv_theme.dart`.
- `third_party/video_player_android` — **vendored, patched** ExoPlayer plugin (see §9).
- `assets/icon/` — logo sources; `gen_icon.py` regenerates all icons + the TV banner (§8).
- `docs/index.html` — the entire marketing site (single file) + `docs/assets/` screenshots (§8).
- `windows/runner/main.cpp`, `Runner.rc` — Windows runner (window title "VesperTV").

## 4. Build / check
- `flutter analyze` — baseline **22** info issues, none errors.
- Android: `flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk` (~68 MB).
- Windows: **kill the running app first** (`Get-Process nox_iptv | Stop-Process -Force`) or the link
  step fails with `LNK1104: cannot open nox_iptv.exe`. Then `flutter build windows --release`
  (output `build\windows\x64\runner\Release\nox_iptv.exe`) and zip the **whole Release folder** as
  `VesperTV-windows-x64.zip` (the exe needs the DLLs/`data` folder beside it — a bare .exe will
  not run, which is why the site links the zip, not the exe).
- Only run `dart format` on files you edited (`dart format lib` reformats unrelated files).
- Don't launch the Windows exe from an automated PowerShell session to test it — it can show a blank
  white window there (proven unrelated to `window_manager`); the owner launching it normally works.

## 5. Signing (READ BEFORE BUILDING A RELEASE)
- `android/key.properties` + the `.jks` keystore are **git-ignored secrets**. Alias `noxplayer`.
  `storeFile` is an absolute path for that machine (Windows: forward slashes).
- If key.properties is missing/wrong the build **silently signs with the debug key** — that APK
  cannot install over a real install. Always verify:
  `apksigner verify --print-certs app-release.apk` → SHA-256 must be
  `c92a346ac5b6191a373b3572fa0fbd72abdd5f64db497bd321617b8cc4562431`.
- Never commit the keystore/passwords. Losing the key = existing installs can never update.
- Android requires `versionCode` (the `+N` in `pubspec.yaml`, currently **+182**) to never go
  down, even if the visible version resets. Always bump N on every build you intend to install.

## 6. Release workflow
Only release when the owner asks ("update the latest", "cut it", "fully release").
1. Bump `version:` in `pubspec.yaml` (`x.y.z+build`). Settings shows it.
2. `flutter analyze`, build APK, **verify signature (§5)**, build Windows + zip, **commit + push
   source first** (the tag must land on HEAD).
3. Update the latest release in place (don't cut a new release per test build):
   `gh release upload <tag> build/app/outputs/flutter-apk/app-release.apk VesperTV-windows-x64.zip --clobber`
   then `gh release edit <tag> --tag <new-version> --title "VesperTV <ver>" --notes-file <file>`.
   **`--notes` replaces the whole body** — write self-contained notes (never "see below").
4. **Gotcha:** `gh release edit --tag` leaves the old git tag behind and may put the new tag on a
   stale commit — confirm `git ls-remote --tags origin <ver>` equals `git rev-parse HEAD`. Repoint
   with `gh api -X PATCH repos/NoXqc/VesperTV/git/refs/tags/<tag> -f sha=<full-sha> -F force=true`.
5. Experimental builds → `--prerelease` (skipped by `/releases/latest`, so Downloader and Check for
   Updates ignore them). Promote with `gh release edit <tag> --prerelease=false --latest`.
6. **Verify what users get:** download
   `https://github.com/NoXqc/VesperTV/releases/latest/download/app-release.apk` and
   `.../VesperTV-windows-x64.zip`, `sha256sum` against the local files; also check the OLD
   `https://github.com/NoXqc/NoXPlayer/releases/latest/download/app-release.apk` and
   `https://api.github.com/repos/NoXqc/NoXPlayer/releases/latest` still redirect to the new repo,
   and `curl -sL http://go.aftvnews.com/1760256 | grep -o 'https://github[^"'"'"' ]*'` resolves
   (AFTVnews still stores the **old** `NoXqc/NoXPlayer/...` URL — it works only through GitHub's
   redirect, so that redirect is load-bearing).
7. **Updater semantics (changed in 3.53.0):** `AppUpdateService` offers a release when its
   `tag_name` is **different** from the installed version (`_isDifferent`), no longer only when
   newer. Reason: versioning is meant to restart at 1.0.0, which is numerically lower than the old
   3.x tags. Any Android asset ending `.apk` / Windows asset ending `.zip` is picked by extension —
   never leave two `.zip` (or two `.apk`) assets on the latest release.

## 7. Test devices (adb over LAN)
- Formuler Z11 Pro MAX `10.0.0.46:5555` — **IP changes** with VPN/network toggles/reboots (often
  `192.168.1.46:5555`). Fire Stick `192.168.1.33:5555` (was `10.0.0.94:5555`). This PC is authorized.
- First connect from a new PC pops an "Allow USB/ADB debugging?" dialog on the TV — accept "always".
- Install with `adb install -r` (GUI installers silently fail on the Formuler):
  ```
  adb connect 192.168.1.46:5555
  adb -s 192.168.1.46:5555 install -r build/app/outputs/flutter-apk/app-release.apk
  adb -s 192.168.1.46:5555 shell am start -n com.nox.nox_iptv/.MainActivity
  ```
  Verify: `adb shell pm path com.nox.nox_iptv` then `adb shell sha256sum <path>` vs local build.
- Formuler restrictions: not rooted, app not debuggable → **no logcat of the app, no `run-as`, no
  access to `Android/data`** (scoped storage). Don't plan on log-file instrumentation there.
- "Crashes" on these boxes are usually **ANRs**: `adb shell dumpsys dropbox --print data_app_anr`
  (and `data_app_crash`); `top -H -b -n 1 -p <pid>` shows busy threads.
- Driving the UI over adb for screenshots: `adb exec-out screencap -p > x.png` (video surfaces show
  **black** in screencaps — that's normal while a stream plays). `input keyevent DPAD_*`/`BACK` work.
  **`input keyevent --longpress` does NOT trigger HoldToActivate; use a touch hold instead:**
  `adb shell input swipe X Y X Y 1800` on the item (pointer long-press is supported on
  `HoldToActivate`). `input tap X Y` works for touch targets. **The sidebar "Exit App" row is focusable
  at the bottom — never press Select there by accident.**
- Don't `adb install` when the owner says not to (they sometimes test from a separate box).
- The owner sets the Formuler's theme to **Dark / Gold** on purpose; leave it unless asked.

## 8. Branding assets & website
- **Logo:** `python assets/icon/gen_icon.py` (Pillow) regenerates `icon_flat/background/foreground.png`,
  `tv_banner.png` and the five `android/app/src/main/res/drawable-*/banner.png`. Then
  `dart run flutter_launcher_icons` for launcher icons (Android adaptive, iOS, Windows `.ico`, web,
  macOS). The splash and welcome screen load `assets/icon/icon_flat.png`. Revert incidental
  line-ending-only diffs the icon tool causes (e.g. `ios/Runner.xcodeproj/project.pbxproj`).
- **Palettes:** the default fresh-install theme is **Platinum** (`id: 'minimal'`, first entry of
  `cyberpunkPalettes`); its `primary`/`secondary` only drive the wordmark and small accent bars and
  are now brand gold `F0C75E`/`C9781A` (they used to be the old purple/magenta — that was the bug
  behind "still purple after the rename"). The splash screen's glow/wordmark in `main.dart` are gold
  too. **Dark / Gold** (`dark_gold`) is the full gold theme. Don't move `dark_gold` to first place:
  fresh-install fallback is `cyberpunkPalettes.first`, and users who never picked a palette would
  silently switch theme on update.
- **Site (`docs/index.html`):** one file, design tokens on `:root` (gold = `--violet*` names kept
  from the old purple palette; text on gold fills must be dark `#1A1205`, not white). Hero has a
  `.sky` layer (CSS sun rays + twinkling stars, honours `prefers-reduced-motion`). Under the hero is
  the **swipeable screenshot carousel** (`#galTrack`: native scroll-snap + arrows, dots, ←/→ keys,
  mouse drag; JS at the top of the `<script>`). Windows is advertised in the hero (kicker, "Windows
  (.zip)" button), FAQ and Install section 04. Inline screenshots were deliberately removed in
  favour of the carousel.
- **Screenshots** (`docs/assets/shot-*.png|jpg`, also used in `README.md`): captured from the
  Formuler via `adb screencap` (1920×1080) in Dark / Gold, the **"Hold to resume" pill blurred out**
  (Pillow: crop box (740,902)-(1180,1064), Gaussian blur 30, brightness ×0.5, feathered paste), then
  resized to 1600×900. Retake them after any big UI change.

## 9. Vendored ExoPlayer plugin
`third_party/video_player_android` is a patched copy of `video_player_android` **2.12.2** (matches
what `video_player_hdr ^1.2.0` resolves to), wired in through `dependency_overrides`. Patch adds
`org.jellyfin.media3:media3-ffmpeg-decoder` and `EXTENSION_RENDERER_MODE_PREFER` in
`PlatformViewVideoPlayer.java`, fixing silent **AC3/E-AC3 5.1** audio on boxes without a licensed
Dolby decoder. **If `video_player_hdr` or its constraint is ever bumped**, re-sync the vendored copy
to the new version and re-apply both patches (the `ExoPlayer.Builder`/`DefaultRenderersFactory`
change and the gradle dependency line). Migrating to `media_kit` on Android was researched and
rejected (HDR + Android-TV hardware-decode risk).

## 10. Hard-won rules (don't re-learn these)
- **Cold-start splash is deliberately slow (~20-25s with a big second playlist).** Entering the UI
  early lets remote input crash weak boxes. Do not cap/shorten it (`_bootstrap` in main.dart). The
  Android last-channel auto-resume is also deliberately NOT done at cold launch (only a pending
  "Hold > to resume" pill); on **Windows** it does auto-resume.
- **D-pad focus:** default directional traversal is unreliable across differently shaped columns/
  rows — use explicit dispatch (`_moveColumnFocus`, the Timeline guide's own Up/Down/Left/Right,
  one `FocusScopeNode` per zone + `CallbackShortcuts`). No per-row `FocusScope`. Any programmatic
  scroll uses `jumpTo`, never `animateTo` (caused an ANR-length freeze on a big list). Pause periodic
  timers when covered (`RouteAware`). Remote "hold Select" = `HoldToActivate`; `InkWell.onLongPress`
  is touch-only.
- **Fire OS's on-screen keyboard swallows the physical Back button — known, unfixable limitation.**
  Confirmed via a raw `getevent` capture (clean `KEY_BACK`) plus Flutter-side logging of
  `logicalKey.keyId`: pressing Back on a Fire TV remote while the on-screen keyboard has D-pad
  focus never reaches the app as Back/Escape/browserBack at all. Fire OS's own keyboard overlay
  intercepts it first and resynthesizes it as ordinary keyboard-internal D-pad navigation
  (arrowRight/arrowDown moving the on-screen selector) immediately followed by a synthetic
  `numpadEnter` — indistinguishable, by the time Flutter sees it, from the user genuinely
  navigating the keyboard and pressing Enter on purpose. That synthetic Enter is what fires
  `TextField.onSubmitted`/`TextInputAction.next`, advancing focus to the next field instead of
  closing the keyboard. No app-level fix exists. A Formuler box does not have this problem (Back
  closes its keyboard normally).
- **A plain focusable widget (not a text field) competes with Flutter's own default directional
  traversal — `HardwareKeyboard.instance.addHandler` loses that race.** `add_playlist_screen.dart`'s
  `_handleFieldEscapeKey` reliably overrides arrow keys while a *text field* has focus only because
  `EditableText` swallows arrow keys internally. For a non-text-field widget (e.g. `ModeButton`,
  `TvMenuTile`), default traversal still runs and overrides a raw handler's `requestFocus()`. Use
  `CallbackShortcuts` for that case — it intercepts before default traversal.
- **Never call `notifyListeners()` mid-build.** `PlaylistManager.notifyListeners` defers anything
  fired during the build phase (fixed Group Management checkmarks not repainting).
- Composite `Channel.id` (`playlistId::rawId`) vs raw `Channel.rawId`: EPG lookups and
  `Channel.isLiveId` need **rawId**.
- Back button: walks content → groups → tabs, exits the app only from the tabs column (`PopScope`
  in TvHomeScreen).
- The "live island" pill / mini player share **one controller** across preview/fullscreen/pill; see
  the comments before touching `PlaybackService`.
- **Multiview audio swap = recreate the controller (`_assign`), not toggle in place.** Toggling audio
  tracks in place (`_setAudioEnabled`) was tried **twice** and was worse both times (stalls; audio
  would not activate). Keep the reload and the stall watchdogs. Multiview freezing is mostly the
  IPTV provider's connection limit, not the app (warnings are shown in the left sidebar).
- **"Open in Multiview" from the player must `await _playback.stop()` before pushing**, otherwise
  the fullscreen stream and its audio keep playing underneath.
- **Windows** is a separate world: `window_manager` makes the app **always fullscreen** at launch
  (`WindowOptions(fullScreen: true, titleBarStyle: hidden)`); it cannot minimize while fullscreen →
  `_minimizeWindow()` exits fullscreen first and `WindowListener.onWindowRestore` re-enters it;
  `SystemNavigator.pop()` does nothing on Windows → use `windowManager.close()`; mouse "hold" needs
  the pointer `LongPressGestureRecognizer` inside `HoldToActivate` (keyboard Enter-hold alone did not
  work for mouse users); the last live channel is saved in `DesktopPlayerScreen`
  (`setLastChannelId`) because nothing else writes it on Windows.
- Open-source principle: **no embedded API keys.** Anything needing a key (TMDB, a future
  OpenSubtitles) is bring-your-own-key in Settings.

## 11. Known bugs & their fixes (history — don't regress these)
| Symptom | Cause | Fix / where |
|---|---|---|
| Add Playlist: Back to close the keyboard on the **Name** field jumped to fullscreen live; Back again returned | `LiveResumeHint`'s global hold-Right (1200 ms) timer was armed while a text field had focus, and the Fire/remote keyboard sequence fired it | `LiveResumeHint._textFieldFocused` gates both arming **and** `_resume()` (`live_resume_hint.dart`) |
| Cold launch opened the first live group instead of Favourites | `_effectiveLiveGroup` used only `currentChannel`, which is null on cold launch | favourites-first using `currentChannel ?? pendingResumeChannel` (`tv_home_screen.dart`) |
| Add Playlist: Right from fields never reached the Add button; up/down escapes buggy | focus escape logic per field | explicit `_modeScope/_fieldsScope/_statusScope`, `_handleFieldEscapeKey` with a unified field list; mode rows use `TvMenuTile(focusNode:)` |
| Multiview: main stream/audio kept playing after "Open in Multiview" | player not stopped | `await _playback.stop()` before push |
| Multiview: in-place audio toggle stalled / no audio | see §10 | reverted to recreate-via-`_assign` |
| Windows: "can't go truly full screen" (title bar + taskbar, ~98%) | native runner only shows a bordered window | `window_manager` always-fullscreen launch |
| Windows: Minimize did nothing / Close did nothing / Alt+Tab-away fine | minimize blocked in fullscreen; `SystemNavigator.pop` no-op | see §10 Windows |
| Windows: hold-to-menu only worked with keyboard Enter | no pointer long-press | `RawGestureDetector` in `HoldToActivate` |
| Windows: last channel not resumed at launch | nothing recorded it | `DesktopPlayerScreen` records `setLastChannelId`; `_autoResumeLastChannel` pushes it |
| Windows build `LNK1104` | exe still running | kill `nox_iptv` first |
| Rebranded APK still purple (default theme) | Platinum's accent pair + splash were hardcoded purple/magenta | gold values in `constants.dart` and `main.dart` splash |
| Updater never offers a lower-numbered release (1.0.0 < 3.x) | strict "newer" compare | `_isDifferent` (§6.7) |
| `gh release edit --notes` referenced "notes below" and wiped them | `--notes` replaces body | write self-contained notes with `--notes-file` |
| Release asset update didn't change what `/latest` serves | tag left on old commit | repoint tag to HEAD (§6.4) |
| Formuler adb "device not found" | its IP changed | reconnect on `192.168.1.46:5555` / check its Settings > Network |
| **Open: EPG not ready for ~58 s after the UI appears on the Formuler** (PC: 1-2 s; LokTV is near-instant) | unproven — hypothesis: eager full in-memory decode vs a lazily-queried DB, on weak hardware | not fixed. Concurrent-init attempt gave no improvement. `traceEpgTiming` in `epg_service.dart`/`main.dart` is **TEMPORARY instrumentation** (its output file is unreadable on the Formuler) — remove it when this is resolved or abandoned |

## 12. Features worth knowing
- **Timeline guide** (Settings > Theme > Live TV guide = `guideViewMode` 'live'|'timeline'):
  `_TimelineGuide*` in tv_home_screen.dart. Left/Right step 30-minute slots (`moveHorizontal`),
  Up/Down keep the time column (live "now" for a currently-airing block), entering from groups and
  returning from fullscreen restore focus at the current time, long blocks keep a sticky label, rows
  with no EPG show a placeholder, hold-Select opens a favourite/hide menu. "Live" = compact
  now/next list with details below.
- **Player controls:** a primary row plus a secondary row revealed by pressing Down again (a chevron
  hints it exists); every icon button has a text label; top row shows quality (HD/FHD/4K), FPS and
  audio-channel (e.g. 5.1) badges. "Multiview" button opens Multiview with this channel preloaded.
- **Multiview:** two stacked cells, warnings in the left sidebar, channel picker with group list +
  search and the current programme under each channel.
- **Welcome prompt:** brand-new users (no playlists) get "Hey beautiful Human, Welcome to
  VesperTV" with Add Playlist / Skip for now.
- **Hide individual live channels** (per playlist, `hiddenChannels`), unhide in
  Settings > Playlist Manager > Hidden Channels. Group hiding is separate. Hold Select on a movie/
  TV group offers **Expand catalog** (full-screen poster grid), Favourite, Hide.
- **Movies/TV Shows:** hero + poster rows; hero description fetched after a 400 ms dwell and cached
  in `PlaylistManager` (shared with the detail screens).
- **Backup servers:** connect tries last-working → main → backups (one pass); live stream *open*
  failures retry other servers. Mid-stream drops do not fail over. Sticks to last-working server.
- **Palettes:** duo-tone `primary`/`secondary`; optional `highlight` is wordmark/swatch decoration
  only (Habs uses white). Old id `green_orange` maps to `habs`. `isMinimal` (Platinum) = flat black
  with translucent-white glass focus; `trueBlack` (Dark / Gold) = hand-built scheme.
- **Viewer profiles** (`ViewerProfile`, `ViewerProfileService`): several viewers sharing one
  device's playlists, each with their own favorites/hidden-groups/watch-history. Main's data lives
  under every *existing* unsuffixed storage key, completely unchanged — never add a step that
  rewrites Main's keys on upgrade; a second-or-later viewer's keys get `__vp_<id>` appended by
  `StorageService._vk`/`_vkp` instead (position/duration keys keep the suffix at the very end, not
  after the prefix, so `clearCache()`'s `startsWith` sweep still catches every viewer's). A
  restricted ("kid") viewer uses a *shown-groups allowlist* (`keyShownGroups`), not the blocklist
  every other viewer uses — see `PlaylistSession._loadViewerScopedState`'s doc comment for why a
  new category must default to hidden for them, not visible. `CatalogDatabase`'s own `is_favorite`
  column stopped being the favorite source of truth — `PlaylistManager` injects a live callback
  (`isVodFavorite`/`isSeriesFavorite`) instead; only write that column while Main is active.
  `ViewerProfileService.requireUnlock` is the single PIN choke point for *opening Settings at all*
  from a restricted profile; any direct, non-Settings control that can un-hide something (the TV
  live-channel long-press menu's "Unhide") needs its own `requireUnlock` check. A profile switch
  (`switchTo`) stops playback *before* flipping the active viewer id, then calls
  `PlaylistManager.applyActiveViewer`/`PlaybackService.reloadForViewer`; it only shows because
  `main.dart` wraps the home screen in `Consumer<ViewerProfileService>` keyed by the active viewer's
  id, which remounts the home screen from scratch.

## 13. Status & open items (as of 2026-10-10)
- **Shipped:** rebrand to VesperTV, logo, gold site with carousel + Windows section, release
  **3.53.0** (`+182`; the "bridge" release; its notes carry the rename TL;DR).
- **Planned, waiting on the owner's go:** a clean **1.0.0** release — delete the old releases
  (`gh release delete <tag> --cleanup-tag`), set `pubspec` to `1.0.0+N` with **N > 182**, keep the
  rename TL;DR in the notes. Do this only after people have had time to update to 3.53.0 (anyone
  still on ≤3.52.3 can't see 1.0.0 and must reinstall from vespertv.app), and **ask before deleting**.
- **Ideas discussed, not started:** Sports tab with live scores (needs a free API key, BYO; hard
  part is matching games to channels); OpenSubtitles integration (BYO key); Windows player-controls
  secondary-row parity; EPG speed rework for weak boxes; a rename of `nox_iptv.exe`→`VesperTV.exe`
  (CMake `BINARY_NAME`; user data location is unaffected).
- Competitor reference: **LokTV** (paid) — cached EPG, sports tab, multiview, simple add-playlist.

## 14. Git
- Commit only when asked; end commit messages with the attribution trailer Claude Code provides.
- Never `--no-verify`, never force-push `main` (force-moving a **tag** to HEAD is the one sanctioned
  exception, §6.4).
- Local junk is git-ignored/untracked on purpose (`nox_*.png` screenshots, `*.apk`, `*-windows-x64.zip`).
