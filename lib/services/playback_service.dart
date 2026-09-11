import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import 'app_preferences.dart';
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
  PlaybackService(this._storage, this._preferences);

  static const _recentlyPlayedCacheKey = 'recently_played';
  static const _maxRecentlyPlayed = 30;

  final StorageService _storage;
  final AppPreferences _preferences;

  Channel? currentChannel;
  VideoPlayerHdrController? controller;
  Future<void>? initFuture;
  String? error;

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
      _recentlyPlayed =
          (jsonDecode(raw) as List).map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();
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
  Future<void> play(Channel channel) async {
    if (!_preferences.playlistEnabled) {
      error = 'Playlist is disabled on this device — enable it in Settings > Content Manager to watch.';
      notifyListeners();
      return;
    }
    if (currentChannel?.id == channel.id && controller != null) return;

    await _teardown();
    currentChannel = channel;
    error = null;
    _autoAdvanceDismissed = false;
    notifyListeners();
    unawaited(_recordRecentlyPlayed(channel));

    final savedPositionMs = _storage.getLastPosition(channel.id);
    final newController = VideoPlayerHdrController.networkUrl(
      Uri.parse(channel.url),
      closedCaptionFile: channel.subtitleUrl != null ? _loadCaptions(channel.subtitleUrl!) : null,
    );
    controller = newController;

    initFuture = newController.initialize(viewType: VideoViewType.platformView).then((_) async {
      if (savedPositionMs > 0) {
        await newController.seekTo(Duration(milliseconds: savedPositionMs));
      }
      await newController.play();
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
      if (c != null && ch != null && c.value.isInitialized) {
        _storage.setLastPosition(ch.id, c.value.position.inMilliseconds);
        final duration = c.value.duration;
        if (duration > Duration.zero) {
          _storage.setLastDuration(ch.id, duration.inMilliseconds);
          // Auto-advance a season/series near the end — a live channel's
          // duration is always zero, so this branch never fires for those.
          final remaining = duration - c.value.position;
          if (remaining <= const Duration(seconds: 30) && !_autoAdvanceDismissed) {
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
    await old?.dispose();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
