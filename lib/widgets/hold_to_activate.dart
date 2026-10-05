import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds "hold Select to do something else" on top of an already-interactive
/// child, without giving that child a second focus stop or double-firing its
/// gesture handling.
///
/// This is a keyboard-only overlay, not a self-contained row widget like
/// this app's `_GroupRow` (tv_home_screen.dart) — it wraps a child that
/// already has its own `InkWell`/`GestureDetector` for touch, and only adds
/// the D-pad/remote side of "hold to activate something extra". That's
/// possible because `Focus.onKeyEvent` participates in the key-event
/// bubble-up chain from whichever descendant currently holds primary focus
/// *regardless* of `canRequestFocus` — the same mechanism `Shortcuts` relies
/// on — so `canRequestFocus: false` here means this never becomes a second
/// tab-stop, it just listens in on key events meant for the child.
///
/// Swallowing the key event here also means the app's default `Shortcuts`
/// never turns a plain Select/Enter press into an `ActivateIntent` for the
/// child — so a short press's "tap" behavior is synthesized directly on
/// `KeyUpEvent` here (same as `_GroupRow` does), rather than relying on the
/// child's own keyboard activation.
///
/// [onHold] is nullable so this can be dropped in unconditionally: with it
/// null, holding does nothing and a short press still calls [onTap] as
/// normal.
class HoldToActivate extends StatefulWidget {
  const HoldToActivate({
    super.key,
    required this.onTap,
    this.onHold,
    this.holdDuration = const Duration(milliseconds: 550),
    required this.child,
  });

  final VoidCallback onTap;
  final VoidCallback? onHold;
  final Duration holdDuration;
  final Widget child;

  @override
  State<HoldToActivate> createState() => _HoldToActivateState();
}

class _HoldToActivateState extends State<HoldToActivate> {
  Timer? _holdTimer;
  bool _holdFired = false;

  /// True only between this exact instance's own KeyDownEvent and its
  /// matching KeyUpEvent — guards against an *orphaned* KeyUp firing
  /// [onTap] on its own. Flutter routes a key event to whatever currently
  /// holds primary focus at the moment that event arrives, not to
  /// whoever held focus when the matching key-down fired — so a
  /// `requestFocus()` call made elsewhere in response to *this* same
  /// physical Select press (e.g. switching live-TV groups, which
  /// explicitly refocuses the new group's first channel row right in its
  /// own key-down handler) can move focus onto a different
  /// `HoldToActivate` before the key is physically released. That row
  /// then receives this press's key-*up* with no key-down of its own ever
  /// having reached it — previously indistinguishable from a real short
  /// press here, so it fired `onTap` reflexively. Reported directly and
  /// confirmed: selecting Live TV's "Favourites" group from a different
  /// group's channel list launched that new list's first channel straight
  /// into fullscreen, with the list itself never visibly shown — exactly
  /// this: the group-switch's own key-down retargeted focus onto that
  /// row, and the same press's key-up then "activated" it a moment later.
  bool _downReceived = false;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isActivateKey = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA;
    if (!isActivateKey) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _holdFired = false;
      _downReceived = true;
      _holdTimer?.cancel();
      final onHold = widget.onHold;
      if (onHold != null) {
        _holdTimer = Timer(widget.holdDuration, () {
          _holdFired = true;
          onHold();
        });
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      final hadMatchingDown = _downReceived;
      _downReceived = false;
      if (hadMatchingDown && !_holdFired) widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      // Confirmed on real hardware: without this, a short press fired
      // *both* this widget's own synthesized onTap (below) AND the
      // wrapped child's built-in keyboard "Activate" handling — InkWell/
      // ListTile bind Enter/NumpadEnter to their own onTap via Flutter's
      // ambient Shortcuts+Actions (a completely separate dispatch path
      // from the raw Focus.onKeyEvent bubbling this widget uses), so both
      // fired independently for the same press. `_GroupRow`'s identical
      // Timer technique never hit this because it wraps a plain
      // GestureDetector, which has no built-in keyboard activation to
      // compete with. Claiming these keys here, closer to the child than
      // the app's default Shortcuts, means Flutter's ambient Enter/
      // NumpadEnter-to-Activate translation never gets a chance to run —
      // this widget's own Focus.onKeyEvent below is left as the sole
      // consumer, exactly like `_GroupRow`.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): DoNothingIntent(),
        SingleActivator(LogicalKeyboardKey.enter): DoNothingIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): DoNothingIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): DoNothingIntent(),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleKeyEvent,
        child: widget.child,
      ),
    );
  }
}
