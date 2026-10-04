import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/channel.dart';

/// Windows-only holder for a live channel's `Player`/`VideoController`
/// after `DesktopPlayerScreen`'s back button minimizes it — the Windows
/// equivalent of `PlaybackService` continuing to play a live channel in
/// the background once its fullscreen view is left. Exists at all because
/// `DesktopPlayerScreen` deliberately never touches `PlaybackService` (see
/// its own doc comment) — this is a second, much smaller version of the
/// same idea, holding exactly one channel's session at a time: whatever
/// was most recently minimized. A movie or episode never lands here — see
/// `DesktopPlayerScreen._handleBack`, which only hands off a *live*
/// channel; VOD still just stops on exit, same as mobile.
class DesktopMiniPlayer {
  DesktopMiniPlayer._();
  static final DesktopMiniPlayer instance = DesktopMiniPlayer._();

  /// Null when nothing is minimized — `DesktopLiveResumeHint` watches this
  /// directly to decide whether to show its resume pill at all.
  final ValueNotifier<Channel?> channel = ValueNotifier(null);

  Player? _player;
  VideoController? _controller;

  /// Read-only access for a preview surface (the Timeline guide's own
  /// mini-player box) that wants to render the actual minimized stream
  /// without taking ownership of it the way [take] does. Safe to mount a
  /// second `Video` widget against this alongside (briefly) whatever
  /// still-live widget handed it off — unlike `video_player_hdr`'s
  /// platform views (see `LiveResumeHint`'s doc comment for the real bug
  /// that caused on mobile), `media_kit`'s texture-based rendering
  /// supports multiple simultaneous `Video` widgets on one controller.
  VideoController? get controller => _controller;

  void minimize(Channel ch, Player player, VideoController controller) {
    // Only one minimized session can exist at a time (there's only one
    // pill) — if something else was already minimized, it has no other
    // reference anywhere, so it must be disposed here or it'd keep
    // decoding in the background forever with nothing left to stop it.
    if (_player != null && _player != player) _player!.dispose();
    _player = player;
    _controller = controller;
    channel.value = ch;
  }

  /// Hands the live session back to a freshly reopened
  /// `DesktopPlayerScreen` instead of it creating a new `Player` — resuming
  /// fullscreen must not restart the stream. Clears this holder's own
  /// state since that screen now owns the session again.
  (Player, VideoController)? take() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return null;
    _player = null;
    _controller = null;
    channel.value = null;
    return (player, controller);
  }

  /// Abandons whatever's minimized, disposing its `Player` outright —
  /// every fresh-playback entry point (`TvHomeScreen._selectChannel`,
  /// `MovieDetailScreen.play`, `SeriesDetailScreen._openEpisode`) calls
  /// this before starting something new. Reported directly: picking a
  /// *different* live channel after minimizing one left the old session
  /// quietly still running — [minimize] only disposes a previous one when
  /// minimize is called *again*, which a brand-new, unrelated channel
  /// selection never does, so the old `Player` just kept decoding/playing
  /// audio in the background forever, with the resume pill still pointed
  /// at it even though a different channel was now also playing on top.
  void clear() {
    _player?.dispose();
    _player = null;
    _controller = null;
    channel.value = null;
  }
}
