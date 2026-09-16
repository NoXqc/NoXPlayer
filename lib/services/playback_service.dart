import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/channel.dart';
import 'playlist_manager.dart';
import 'storage_service.dart';

/// Owns the single, app-wide [VideoPlayerHdrController] for whatever channel
/// is currently playing.
///
/// Was a plain `VideoPlayerController` (the stock `video_player` package) —
/// switched after a long, evidence-backed diagnosis of a real bug: on
/// Android, going fullscreen showed solid black while the exact same
/// stream played fine in a smaller inline preview elsewhere in the app,
/// even though the decoder logs showed successful decoding the entire
/// time (confirmed via logcat on real Formuler and Firestick hardware). A
/// side-by-side comparison against a native player app on the same
/// hardware showed identical MediaCodec-level success in both — the
/// difference was specifically in how each *displays* the decoded frame,
/// not decoding itself. `video_player`'s Android implementation renders
/// through a GPU-texture path that has a known, documented weakness here;
/// `video_player_hdr` is a drop-in-API fork that can render through a
/// platform view instead, closer to how a native app's own `SurfaceView`
/// works. `EnableImpeller` (Flutter's newer renderer, which fixes this
/// properly) can't be turned on here — it crashes on startup on this
/// hardware's GPU driver (see AndroidManifest.xml) — so this is the
/// practical way to get the same effective fix without it.
///
/// Previously each screen (the inline pane, the fullscreen player) created
/// and disposed its own controller, so navigating back from fullscreen on a
/// phone killed playback entirely — there was nothing left to resume into.
/// Hoisting the controller up here means any number of presentation widgets
/// (the inline pane, the fullscreen screen, a mini-player bar) can all watch
/// the same live controller — switching between them is just a different
/// wrapper around the same video, never a restart.
class PlaybackService extends ChangeNotifier {
  PlaybackService(this._storage, this._playlistManager);

  static const _recentlyPlayedCacheKey = 'recently_played';
  static const _maxRecentlyPlayed = 30;

  final StorageService _storage;
  final PlaylistManager _playlistManager;

  Channel? currentChannel;
  VideoPlayerHdrController? controller;
  Future<void>? initFuture;
  String? error;

  /// True while `PlayerScreen` is actually mounted and showing this
  /// channel fullscreen — set/cleared by that screen's own
  /// `initState`/`dispose` via [setFullscreenActive]. `LiveResumeHint`
  /// reads this both to stop the global hold-Right gesture from firing
  /// again on top of an already-showing fullscreen view, and to hide its
  /// own reminder text while fullscreen is already showing.
  bool isFullscreenActive = false;

  /// A plain field assignment here wouldn't notify `LiveResumeHint`,
  /// which listens via [addListener] — confirmed on real hardware as the
  /// cause of its reminder text still showing the just-left channel's
  /// name for a moment right after entering fullscreen for a *different*
  /// one, since nothing had told it anything changed yet.
  void setFullscreenActive(bool value) {
    if (isFullscreenActive == value) return;
    isFullscreenActive = value;
    notifyListeners();
  }

  /// True only for a brief window after an automatic cold-start "resume
  /// last channel" call (see `main.dart`'s `_autoResumeLastChannel`, the
  /// only caller that passes `silent: true` to [play]), ended by either
  /// [_silentResumeTimer] or genuine user interaction with the Live TV
  /// tab (see `TvHomeScreen.clearSilentResume`) — whichever comes first.
  ///
  /// Exists because the mere act of that background resume starting was
  /// enough to make `TvHomeScreen` auto-scroll its groups column to that
  /// channel's group and start fetching its EPG — cosmetic, unrelated to
  /// actual stream buffering, but visible work that happened the instant
  /// the splash screen handed off to the main UI, reading as "the cold
  /// start is slow" for a couple of seconds on something that had nothing
  /// to do with the stream itself. `TvHomeScreen` checks this flag to
  /// suppress exactly that jump while it's true, while playback still
  /// starts loading immediately regardless.
  ///
  /// Deliberately NOT cleared when [initFuture] resolves (an earlier
  /// version of this did that, and it didn't actually fix anything —
  /// `initFuture` completing means `play()`/`initialize()` have been
  /// *called*, not that a frame has actually decoded and become visible
  /// yet, so the jump still happened before the stream was genuinely
  /// ready to look at, reproducing the exact same complaint). A plain
  /// fixed grace period is a blunter but honest fix for that: long enough
  /// that a normal cold start's stream has actually started rendering by
  /// the time this clears on its own.
  bool isSilentlyResuming = false;
  Timer? _silentResumeTimer;

  /// Called by `TvHomeScreen` on any deliberate group/channel/tab
  /// interaction — ends the "silent" window early even if the grace
  /// period hasn't elapsed yet, since at that point the user has already
  /// gone looking for it themselves.
  void clearSilentResume() {
    _silentResumeTimer?.cancel();
    _silentResumeTimer = null;
    if (isSilentlyResuming) {
      isSilentlyResuming = false;
      notifyListeners();
    }
  }

  Timer? _positionSaveTimer;

  /// Ordered episodes the currently playing channel came from (e.g. a
  /// whole series, season-by-season) — set by `SeriesDetailScreen` when an
  /// episode is opened, so playback can auto-advance near the end (see the
  /// position timer in [play]). Left in place across a switch rather than
  /// cleared, so advancing repeatedly through a season/series just keeps
  /// working — a channel that isn't actually in here (a movie, a live
  /// channel picked afterward) simply finds no match in [_nextInQueue] and
  /// this becomes a no-op until the next episode is opened.
  List<Channel>? _upNextQueue;

  void setUpNextQueue(List<Channel>? queue) {
    _upNextQueue = queue;
  }

  Channel? get _nextInQueue {
    final queue = _upNextQueue;
    final current = currentChannel;
    if (queue == null || current == null) return null;
    final index = queue.indexWhere((c) => c.id == current.id);
    if (index < 0 || index + 1 >= queue.length) return null;
    return queue[index + 1];
  }

  /// Public alias of [_nextInQueue] — lets the "Up Next" bubble in
  /// [PlayerScreen] show what's coming without duplicating the lookup.
  Channel? get nextUpChannel => _nextInQueue;

  Channel? get _previousInQueue {
    final queue = _upNextQueue;
    final current = currentChannel;
    if (queue == null || current == null) return null;
    final index = queue.indexWhere((c) => c.id == current.id);
    if (index <= 0) return null;
    return queue[index - 1];
  }

  /// Public alias of [_previousInQueue] — lets [PlayerControls]' explicit
  /// "Previous episode" button jump back without duplicating the lookup.
  /// Null (button hidden) for a movie/live channel — anything not actually
  /// in [_upNextQueue] — the same way [nextUpChannel] already behaves.
  Channel? get previousUpChannel => _previousInQueue;

  /// Set when the user dismisses the "Up Next" bubble — reset on every
  /// [play] call, so it only ever suppresses auto-advance for the episode
  /// it was dismissed on, not every episode after it.
  bool _autoAdvanceDismissed = false;

  void dismissAutoAdvance() {
    _autoAdvanceDismissed = true;
    notifyListeners();
  }

  List<Channel> _recentlyPlayed = [];

  /// Most-recently-played items, newest first — the raw material for a
  /// "Continue Watching" row. Filter by id prefix (`xt_vod_`/`xt_ep_`) and
  /// [StorageService.getLastPosition] to find what's actually resumable.
  List<Channel> get recentlyPlayed => _recentlyPlayed;

  bool get isPlayingSomething => currentChannel != null;

  Future<void> init() async {
    final raw = await _storage.readCacheFile(_recentlyPlayedCacheKey);
    if (raw == null) return;
    try {
      _recentlyPlayed = (jsonDecode(raw) as List)
          .map((e) => Channel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _recentlyPlayed = [];
    }
  }

  Future<void> _recordRecentlyPlayed(Channel channel) async {
    _recentlyPlayed.removeWhere((c) => c.id == channel.id);
    _recentlyPlayed.insert(0, channel);
    if (_recentlyPlayed.length > _maxRecentlyPlayed) {
      _recentlyPlayed = _recentlyPlayed.sublist(0, _maxRecentlyPlayed);
    }
    await _storage.writeCacheFile(
      _recentlyPlayedCacheKey,
      jsonEncode(_recentlyPlayed.map((c) => c.toJson()).toList()),
    );
    notifyListeners();
  }

  /// Starts playing [channel]. No-ops if it's already the current channel
  /// (so re-opening the fullscreen view for the channel the mini-player is
  /// already showing doesn't restart it).
  ///
  /// [silent] is only ever passed by `main.dart`'s cold-start auto-resume
  /// — see [isSilentlyResuming]'s doc comment.
  Future<void> play(Channel channel, {bool silent = false}) async {
    if (!_playlistManager.isPlaylistEnabled(channel.playlistId)) {
      error =
          'This playlist is disabled on this device — enable it in Settings > Playlist Manager to watch.';
      notifyListeners();
      return;
    }
    if (currentChannel?.id == channel.id && controller != null) return;

    await _teardown();
    currentChannel = channel;
    error = null;
    _autoAdvanceDismissed = false;
    // Always assigned (not just set true when silent) — a non-silent
    // play() must always win, even if a previous silent resume's window
    // was still open, otherwise a genuine user pick right after cold
    // start could get stuck being treated as "not yet looked at".
    _silentResumeTimer?.cancel();
    _silentResumeTimer = null;
    isSilentlyResuming = silent;
    if (silent) {
      _silentResumeTimer = Timer(const Duration(seconds: 4), clearSilentResume);
    }
    notifyListeners();
    unawaited(_recordRecentlyPlayed(channel));

    // Confirmed on real hardware as the cause of a live channel looking
    // "stuck paused": a live id can carry a *stale* saved position from
    // a completely unrelated past session (the periodic save below used
    // to write one unconditionally, live or not), and seeking a live
    // stream to an old position lands outside its actual sliding DVR
    // window — the player then just sits there buffering/frozen instead
    // of joining live. A live channel has no meaningful "resume point" at
    // all, so this is skipped entirely rather than trying to validate the
    // saved value.
    // rawId, not the composite `id` — Channel.isLiveId documents that it
    // expects the raw, unprefixed id. Confirmed as a real regression:
    // with `id` here this always read false for a real live channel,
    // silently reintroducing the exact "stuck paused" bug described
    // above (a live channel getting treated as if it had a saved VOD
    // resume position).
    final isLive = Channel.isLiveId(channel.rawId);
    final savedPositionMs = isLive ? 0 : _storage.getLastPosition(channel.id);
    final newController = VideoPlayerHdrController.networkUrl(
      Uri.parse(channel.url),
      closedCaptionFile: channel.subtitleUrl != null
          ? _loadCaptions(channel.subtitleUrl!)
          : null,
    );
    controller = newController;

    initFuture = newController
        .initialize(viewType: VideoViewType.platformView)
        .then((_) async {
      if (savedPositionMs > 0) {
        await newController.seekTo(Duration(milliseconds: savedPositionMs));
      }
      await newController.play();
      // Fire TV/Android TV boxes otherwise sleep the screen mid-stream on
      // idle-input timeout, exactly like they would for any non-video app —
      // there was nothing here telling the OS playback is active.
      unawaited(WakelockPlus.enable());
      await _storage.setLastChannelId(channel.id);
      // Live streams report zero/unknown duration — that's fine, it just
      // means StorageService.getWatchedFraction has nothing to compute a
      // percentage from for those, which is the correct outcome (a live
      // channel doesn't have a "% watched").
      final duration = newController.value.duration;
      if (duration > Duration.zero) {
        await _storage.setLastDuration(channel.id, duration.inMilliseconds);
      }
      notifyListeners();
    }).catchError((e) {
      error = e.toString();
      notifyListeners();
    });

    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final c = controller;
      final ch = currentChannel;
      // See the doc comment above `isLive` — never persist a "resume
      // point" for a live channel in the first place, not just skip
      // reading one back.
      if (c != null &&
          ch != null &&
          c.value.isInitialized &&
          !Channel.isLiveId(ch.rawId)) {
        _storage.setLastPosition(ch.id, c.value.position.inMilliseconds);
        final duration = c.value.duration;
        if (duration > Duration.zero) {
          _storage.setLastDuration(ch.id, duration.inMilliseconds);
          // Auto-advance a season/series near the end.
          final remaining = duration - c.value.position;
          if (remaining <= const Duration(seconds: 30) &&
              !_autoAdvanceDismissed) {
            final next = _nextInQueue;
            if (next != null) unawaited(play(next));
          }
        }
      }
    });

    notifyListeners();
  }

  Future<void> stop() async {
    await _teardown();
    currentChannel = null;
    _silentResumeTimer?.cancel();
    _silentResumeTimer = null;
    isSilentlyResuming = false;
    notifyListeners();
  }

  Future<ClosedCaptionFile> _loadCaptions(String url) async {
    final response = await http.get(Uri.parse(url));
    final content = response.body;
    if (url.toLowerCase().endsWith('.vtt')) {
      return WebVTTCaptionFile(content);
    }
    return SubRipCaptionFile(content);
  }

  Future<void> _teardown() async {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    final old = controller;
    controller = null;
    initFuture = null;
    unawaited(WakelockPlus.disable());
    await old?.dispose();
  }

  @override
  void dispose() {
    _silentResumeTimer?.cancel();
    _teardown();
    super.dispose();
  }
}
