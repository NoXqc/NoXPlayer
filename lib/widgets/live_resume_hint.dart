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
  bool _holdFired = false;

  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.addListener(_onPlaybackChanged);
    // A first version of this used `HardwareKeyboard.addHandler` — a
    // genuinely non-blocking observer — on the theory that nothing
    // conflicts if Right's normal navigation also keeps running the
    // whole time this widget is separately timing the same hold: the
    // resume action doesn't care what focus did in the meantime. Real
    // hardware testing said otherwise — watching the focused list rapid-
    // scroll through many rows for the entire hold read as broken, not
    // "working as designed", regardless of there being no functional
    // conflict. `addEarlyKeyEventHandler` is the actual gate (runs before
    // the focus tree; returning `KeyEventResult.handled` genuinely stops
    // the event from reaching whatever's focused) — same tool the pill's
    // own hold gestures used, and for the same reason: [_handleGlobalKey]
    // below claims Right entirely for the duration of a hold, only ever
    // letting the underlying screen see a synthesized version of a
    // *normal* press when the hold doesn't complete.
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

  /// Same "consume-and-synthesize" shape as the pill's hold-Down/hold-Up
  /// gestures (see that history on `backup/live-island-attempt` if it
  /// ever needs revisiting): claim Right fully from the first
  /// `KeyDownEvent` — and every `KeyRepeatEvent` Android sends for as
  /// long as it's physically held, which is what actually drives smooth
  /// scrolling elsewhere in the app and is exactly what needs suppressing
  /// here — so none of it leaks through as real navigation during the
  /// hold. Then on `KeyUpEvent`, if the hold never actually completed,
  /// manually perform the equivalent of whatever a normal quick press
  /// would have done (`focusInDirection`) instead of just discarding it.
  /// A quick press of Right behaves exactly as if this widget didn't
  /// exist; only a genuine sustained hold does anything extra — and, as
  /// an accepted trade-off, a sustained hold no longer smoothly fast-
  /// scrolls a long grid while something happens to be playing in the
  /// background either, same as holding Down never scrolled a list while
  /// the pill existed. Gated on [_canResume] first, so every other
  /// screen's own use of Right (column navigation, grid navigation,
  /// TvHomeScreen's own "Right in the last column" shortcut) is
  /// completely unaffected whenever there's nothing to resume.
  KeyEventResult _handleGlobalKey(KeyEvent event) {
    if (!_canResume) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _holdFired = false;
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdDuration, () {
        _holdFired = true;
        _resume();
      });
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _holdTimer = null;
      if (!_holdFired) {
        FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.right);
      }
      return KeyEventResult.handled;
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
