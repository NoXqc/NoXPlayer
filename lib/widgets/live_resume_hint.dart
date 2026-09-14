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
  /// Deliberately longer than the pill's old hold-Down/hold-Up gestures
  /// (1200ms) ever needed to be. Those were a rare, narrowly-scoped
  /// gesture; Right is used constantly for real navigation (grid
  /// scrolling, column moves), and — unlike those — this one does
  /// nothing to stop a normal sustained hold from also doing its normal
  /// thing the entire time (see [_handleGlobalKey]). A longer hold makes
  /// it much less likely that fast-scrolling through an ordinary-length
  /// grid while something happens to be playing in the background
  /// incidentally also jumps to fullscreen partway through.
  static const _holdDuration = Duration(milliseconds: 2000);

  Timer? _holdTimer;

  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.addListener(_onPlaybackChanged);
    // NOT `FocusManager.addEarlyKeyEventHandler` — that's a genuine gate
    // (it can block an event from reaching whatever's focused), which is
    // exactly wrong here. The pill's own hold-Down/hold-Up gestures
    // needed that gate because they wanted to *stop* the underlying
    // screen from also reacting during the hold (entering the island and
    // the list under it scrolling at the same time made no sense). This
    // gesture has no such conflict: whatever Right normally does
    // elsewhere in the app — moving between columns, fast-scrolling a
    // movie grid via Android's own repeated `KeyRepeatEvent`s while
    // physically held, TvHomeScreen's own "Right in the last column"
    // shortcut — should keep working completely unaffected, the entire
    // time, regardless of whether this widget also happens to be timing
    // the same hold in parallel. `HardwareKeyboard.addHandler` is exactly
    // that: confirmed in Flutter's own source as a non-blocking observer
    // whose return value has no effect on whether the event still reaches
    // the focus tree — the "bug" that ruled it out for the pill's gate is
    // precisely the property wanted here.
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
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

  /// Purely observational — never consumes anything, never synthesizes
  /// anything either, unlike the pill's hold gestures (which needed both,
  /// for the gate-based reasons in [initState]'s doc comment). Just
  /// starts a plain wall-clock timer on `KeyDownEvent` and cancels it on
  /// `KeyUpEvent`; `KeyRepeatEvent`s need no handling at all here — the
  /// timer keeps counting on its own regardless of how many of those
  /// arrive while the key stays down. [_resume] re-checks [_canResume]
  /// itself before acting, in case background playback stopped or
  /// fullscreen opened some other way during the hold.
  bool _handleGlobalKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) return false;
    if (event is KeyDownEvent) {
      if (!_canResume) return false;
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdDuration, _resume);
    } else if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _holdTimer = null;
    }
    return false;
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
