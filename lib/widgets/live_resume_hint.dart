import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../screens/player_screen.dart';
import '../services/playback_service.dart';

/// Replaces the earlier "Live Island" floating pill (see git history on
/// the `backup/live-island-attempt` branch for that whole attempt) —
/// scrapped after it kept surfacing real, hard-to-fix native rendering
/// bugs (a platform-view teardown/recreate race that made the pill vanish
/// on a second minimize; two simultaneous consumers of the same HDR
/// decode session corrupting each other's picture) all rooted in the same
/// place: rendering a *second* live video surface for the same channel
/// anywhere outside the one already showing it. This widget renders no
/// video at all, so none of that can happen.
///
/// The idea it replaces the pill with: leaving a live channel's fullscreen
/// view doesn't stop it — [PlaybackService]'s controller keeps playing in
/// the background exactly like a movie/episode already did. Instead of a
/// floating video pill representing that, **holding Right on the D-pad
/// from anywhere in the app** jumps straight back to fullscreen (see
/// [_handleGlobalKey]), and a small text reminder at the bottom of the
/// screen (also plain-tappable, for touch/mouse) names what's playing and
/// the gesture that resumes it (see [build]) for as long as it's playing
/// somewhere other than its own fullscreen view.
///
/// Lives directly above [MaterialApp]'s `Navigator` (see main.dart's
/// `builder`), as a sibling of it rather than a descendant, so the hold
/// gesture and the reminder both work from any screen — same reason the
/// pill needed that position. Being a sibling means `Navigator.of
/// (context)` from in here finds nothing; [navigatorKey] is how
/// [_resume] reaches the real Navigator instead.
class LiveResumeHint extends StatefulWidget {
  const LiveResumeHint({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<LiveResumeHint> createState() => _LiveResumeHintState();
}

class _LiveResumeHintState extends State<LiveResumeHint> {
  // Same duration the pill's own hold-Down/hold-Up gestures settled on —
  // confirmed comfortable on real hardware for a deliberate hold.
  static const _holdDuration = Duration(milliseconds: 1200);

  Timer? _holdTimer;

  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.addListener(_onPlaybackChanged);
    // Two earlier versions of this each got half of it right and not the
    // other — see [_handleGlobalKey] for why neither the pill's own
    // "consume everything, synthesize a substitute on release" pattern
    // nor a fully non-blocking observer actually work for Right
    // specifically, and what this does instead.
    FocusManager.instance.addEarlyKeyEventHandler(_handleGlobalKey);
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleGlobalKey);
    _holdTimer?.cancel();
    super.dispose();
  }

  bool get _canResume {
    final channel = _playback.currentChannel;
    return channel != null &&
        Channel.isLiveId(channel.id) &&
        _playback.controller != null &&
        !_playback.isFullscreenActive;
  }

  /// Neither of the two things already tried for a hold gesture in this
  /// app actually fits Right:
  ///
  /// - The pill's own hold-Down/hold-Up "consume everything, then
  ///   synthesize `focusInDirection` on release if the hold didn't
  ///   complete" pattern relied on that synthesized call being a faithful
  ///   substitute for whatever a normal press would have done. For
  ///   Down/Up that happened to hold. For Right it doesn't: this app's
  ///   own screens bind Right to *custom* `CallbackShortcuts` actions —
  ///   `TvHomeScreen`'s column navigation (`_moveColumnFocus`,
  ///   `_enterBrowseColumn`, its own "Right in the last column" shortcut)
  ///   and `PlayerScreen`'s deliberate no-op — none of which
  ///   `focusInDirection` (Flutter's generic geometric focus search) has
  ///   any way to know about or replicate. Confirmed on real hardware:
  ///   consuming a real press and replacing it with that generic
  ///   fallback made Right stop doing its actual job, not just look
  ///   different — every press after a hold attempt kept landing on the
  ///   same inaccurate substitute instead of the screen's real handler.
  /// - A fully non-blocking observer (tried right before this) avoids
  ///   that by never touching the real event at all — but then nothing
  ///   stops Android's own repeated `KeyRepeatEvent`s (what actually
  ///   drives smooth scrolling anywhere else in the app while a
  ///   directional key is held) from rapid-firing the underlying screen
  ///   for the entire hold, which read as broken even with no functional
  ///   conflict.
  ///
  /// The actual fix needs no synthesis at all: let the *real* first
  /// `KeyDownEvent` through untouched (`ignored`), so whatever the
  /// focused screen actually does on a real Right press happens exactly
  /// as it always would. Only the *repeats* that would otherwise rapid-
  /// fire for the rest of a sustained hold get swallowed. `KeyUpEvent`
  /// has nothing left to do beyond stopping the timer — the real action
  /// already ran the moment the key went down, so there's never a
  /// substitute to get wrong. Accepted trade-off: a sustained hold no
  /// longer smoothly fast-scrolls a long grid past its first step while
  /// something's playing in the background, same as holding Down never
  /// scrolled a list while the pill existed — but every ordinary press,
  /// including the very next one right after a hold, is the real thing,
  /// never a guess. Gated on [_canResume] first, so every other screen's
  /// own use of Right is completely unaffected whenever there's nothing
  /// to resume.
  KeyEventResult _handleGlobalKey(KeyEvent event) {
    if (!_canResume) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdDuration, _resume);
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _holdTimer = null;
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  void _resume() {
    _holdTimer = null;
    if (!mounted || !_canResume) return;
    final channel = _playback.currentChannel;
    if (channel == null) return;
    widget.navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => PlayerScreen(channel: channel)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final channel = _playback.currentChannel;
    final show = _canResume && channel != null;

    // Always Positioned, shown or not — a bare non-Positioned child here
    // would collapse this whole Stack (and the Navigator painted
    // alongside it) to 0x0. See player_screen.dart's `UpNextBubble` for
    // the full story on why.
    if (!show) {
      return const Positioned(bottom: 24, left: 0, right: 0, child: SizedBox.shrink());
    }

    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: SafeArea(
          top: false,
          child: GestureDetector(
            onTap: _resume,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.circle, color: Colors.redAccent, size: 10),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      '${channel.name} — hold ▶ to resume',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
