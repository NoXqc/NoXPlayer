import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../services/playlist_manager.dart';
import '../widgets/hold_to_activate.dart';

/// TV-remote-first multiview grid — several live channels playing at
/// once, one with audio focus at a time. Same idea/UX as
/// `DesktopMultiviewScreen` (Windows), independently implemented here
/// against `video_player_hdr` instead of `media_kit` — there is no
/// cross-platform video engine in this app (see `pubspec.yaml`'s
/// media_kit comment), so each platform needs its own.
///
/// Worth naming plainly: `video_player_hdr` renders via a platform view
/// specifically to dodge an Android GPU-texture rendering bug, and this
/// app has documented history of a *shared-decode-session* platform-view
/// bug on real Fire Stick hardware (see `LiveResumeHint`'s doc comment —
/// the scrapped "Live Island" pill: one decode session rendered in two
/// places at once corrupted both). This screen doesn't do that — every
/// cell owns a fully independent `VideoPlayerHdrController`/decode
/// session, never shared — so that specific bug doesn't apply here.
/// Requested directly regardless, citing TiviMate's own multiview running
/// fine even on older Fire Sticks; verify on real hardware rather than
/// trusting that confidently, the same as everything else in this app.
class MultiviewScreen extends StatefulWidget {
  const MultiviewScreen({super.key});

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewCell {
  Channel? channel;
  VideoPlayerHdrController? controller;
  final FocusNode focusNode = FocusNode(debugLabel: 'multiview-cell');
}

class _MultiviewScreenState extends State<MultiviewScreen> {
  static const _cellCount = 4;
  final List<_MultiviewCell> _cells =
      List.generate(_cellCount, (_) => _MultiviewCell());
  int _activeCell = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cells[0].focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final cell in _cells) {
      cell.controller?.dispose();
      cell.focusNode.dispose();
    }
    super.dispose();
  }

  /// Deliberately the *opposite* order from `PlaybackService
  /// .reloadCurrentChannel`'s own "build the replacement fully before
  /// touching the old one" technique — that avoids a black flash when
  /// there's only ever one stream playing, but here several cells are
  /// already decoding at once, close to this hardware's own concurrent-
  /// decoder-session ceiling. Keeping the old controller alive while the
  /// new one initializes briefly needs N+1 simultaneous sessions instead
  /// of N — reported directly as tipping a completely different,
  /// already-stable cell into freezing as a result of reloading or
  /// swapping an unrelated one. Disposing the old controller first here
  /// instead, accepting a brief black flash on the cell actually being
  /// touched, is the safer trade-off once multiview is already this
  /// close to the hardware's real limit.
  Future<void> _assign(int index, Channel channel) async {
    final cell = _cells[index];
    if (cell.controller != null) {
      final old = cell.controller;
      setState(() => cell.controller = null);
      await old!.dispose();
    }
    // mixWithOthers: true — defaults to false, which lets this new
    // controller's own initialize()/play() request *exclusive* Android
    // audio focus even though it's about to be muted for every cell but
    // the active one. That exclusive request is itself enough to make
    // the system silently pause whichever controller actually held
    // focus — reported directly as exactly this: reloading one (muted
    // or not) cell froze the *other*, audio-focused one specifically,
    // not a random sibling, which pointed at audio focus rather than
    // the video decode/rendering path itself.
    final newController = VideoPlayerHdrController.networkUrl(
      Uri.parse(channel.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await newController.initialize(viewType: VideoViewType.platformView);
      if (!mounted) {
        unawaited(newController.dispose());
        return;
      }
      await newController.setVolume(index == _activeCell ? 1.0 : 0.0);
      await newController.play();
      setState(() {
        cell.channel = channel;
        cell.controller = newController;
      });
    } catch (_) {
      unawaited(newController.dispose());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn\'t start that channel')));
      }
    }
  }

  /// The "Reload" action — see `PlayerControls`' own Reload button /
  /// `PlaybackService.reloadCurrentChannel`'s doc comment for why a
  /// manual relaunch (not an automatic watchdog) is this app's
  /// established fix for a channel that's silently stalled (frozen
  /// frame, no spinner, no error). Requested directly for every
  /// multiview cell for the same reason.
  Future<void> _reload(int index) async {
    final channel = _cells[index].channel;
    if (channel != null) await _assign(index, channel);
  }

  void _clear(int index) {
    final cell = _cells[index];
    final old = cell.controller;
    setState(() {
      cell.channel = null;
      cell.controller = null;
    });
    unawaited(old?.dispose());
  }

  void _setActive(int index) {
    if (_cells[index].channel == null) return;
    setState(() => _activeCell = index);
    for (var i = 0; i < _cells.length; i++) {
      _cells[i].controller?.setVolume(i == _activeCell ? 1.0 : 0.0);
    }
  }

  /// True while a picker push is already in flight — [HoldToActivate]'s
  /// own doc comment documents a real, confirmed-on-hardware class of bug
  /// this guards against: a single remote Select press occasionally
  /// reaching both its own synthesized `onTap` *and* the wrapped
  /// `InkWell`'s ambient keyboard-Activate handling, firing the callback
  /// twice. Reported directly here as exactly that shape of symptom — a
  /// flash, then the picker list still showing instead of the grid — a
  /// second `Navigator.push` stacking a second copy of the picker on top
  /// of the first, so popping one just reveals the other underneath. This
  /// makes a second call a no-op instead of a second push, regardless of
  /// what actually triggered it.
  bool _openingPicker = false;

  Future<void> _openPicker(int index) async {
    if (_openingPicker) return;
    _openingPicker = true;
    try {
      final playlist = context.read<PlaylistManager>();
      final channels = playlist.visibleChannels(category: 'tv');
      final chosen = await Navigator.of(context).push<Channel>(
        MaterialPageRoute(
            builder: (_) => _ChannelPickerScreen(channels: channels)),
      );
      if (chosen != null) await _assign(index, chosen);
    } finally {
      _openingPicker = false;
    }
  }

  /// Remote hardware has no separate "swap"/"remove" buttons to aim a
  /// D-pad at the way the Windows screen's mouse-driven icons do — a
  /// held Select (see [HoldToActivate]) opens this instead, the same
  /// "hold for more options" convention the live channel list and the
  /// Timeline guide's program blocks already use elsewhere in this app.
  Future<void> _showCellActions(int index) async {
    if (_cells[index].channel == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh, color: Colors.white),
              title:
                  const Text('Reload', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('reload'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz, color: Colors.white),
              title: const Text('Change channel',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('swap'),
            ),
            ListTile(
              leading: const Icon(Icons.close, color: Colors.white),
              title:
                  const Text('Remove', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'reload':
        await _reload(index);
      case 'swap':
        await _openPicker(index);
      case 'remove':
        _clear(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Text('Multiview',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const Icon(Icons.volume_up, color: Colors.amber, size: 16),
                    const SizedBox(width: 4),
                    const Text(
                        '= audio — Select to switch, hold Select for options',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              // A fixed 2x2 Row-of-Rows, not GridView — GridView is a
              // Scrollable, and its own `childAspectRatio: 16/9` didn't
              // exactly match every real TV's actual available height,
              // making it genuinely scrollable by a few pixels. Reported
              // directly: moving D-pad focus down to the bottom row then
              // triggered Flutter's default "scroll the newly-focused
              // widget into view" behavior, shifting the top row
              // partially off-screen. A plain Row/Column+Expanded layout
              // always exactly fills whatever space is actually
              // available, with no Scrollable involved at all — nothing
              // left for that default behavior to act on.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                                child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: _buildCell(0))),
                            Expanded(
                                child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: _buildCell(1))),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                                child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: _buildCell(2))),
                            Expanded(
                                child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: _buildCell(3))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCell(int index) {
    final cell = _cells[index];
    final active = index == _activeCell && cell.channel != null;
    void onTap() =>
        cell.channel == null ? _openPicker(index) : _setActive(index);
    return HoldToActivate(
      onTap: onTap,
      onHold: cell.channel == null ? null : () => _showCellActions(index),
      child: _MultiviewCellTile(
        focusNode: cell.focusNode,
        channel: cell.channel,
        controller: cell.controller,
        active: active,
        onTap: onTap,
        onLongPress: cell.channel == null ? null : () => _showCellActions(index),
      ),
    );
  }
}

class _MultiviewCellTile extends StatefulWidget {
  const _MultiviewCellTile({
    required this.focusNode,
    required this.channel,
    required this.controller,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final FocusNode focusNode;
  final Channel? channel;
  final VideoPlayerHdrController? controller;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_MultiviewCellTile> createState() => _MultiviewCellTileState();
}

class _MultiviewCellTileState extends State<_MultiviewCellTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      focusNode: widget.focusNode,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.active
                ? Colors.amber
                : (_focused ? Colors.white : Colors.white24),
            width: widget.active || _focused ? 3 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.controller != null &&
                widget.controller!.value.isInitialized)
              VideoPlayerHdr(widget.controller!,
                  key: ObjectKey(widget.controller))
            else
              ColoredBox(
                color: const Color(0xFF1A1A1A),
                child: Center(
                  child: Icon(
                      widget.channel == null
                          ? Icons.add_circle_outline
                          : Icons.hourglass_empty,
                      color: Colors.white38,
                      size: 36),
                ),
              ),
            if (widget.channel != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.78),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      if (widget.active) ...[
                        const Icon(Icons.volume_up,
                            color: Colors.amber, size: 15),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          widget.channel!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Search-and-pick list for assigning a channel to a cell — same shape
/// as `GroupCatalogScreen`'s own picker-style lists, with the same
/// text-field escape fix `_AddProfileScreenState`/`TmdbSettingsScreen`
/// already use elsewhere in this app (see either's own, fuller doc
/// comment): `EditableText` claims arrow keys for itself whenever a text
/// field has focus, so plain default Down traversal never actually
/// escapes a focused search field on real remote hardware, regardless of
/// what's focusable below it.
class _ChannelPickerScreen extends StatefulWidget {
  const _ChannelPickerScreen({required this.channels});

  final List<Channel> channels;

  @override
  State<_ChannelPickerScreen> createState() => _ChannelPickerScreenState();
}

class _ChannelPickerScreenState extends State<_ChannelPickerScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _firstResultFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleSearchFieldEscapeKey);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _firstResultFocus.requestFocus());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleSearchFieldEscapeKey);
    _searchController.dispose();
    _searchFocus.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  bool _handleSearchFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) return false;
    if (FocusManager.instance.primaryFocus != _searchFocus) return false;
    _firstResultFocus.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.channels
        : widget.channels
            .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Pick a channel'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Search channels...',
                hintStyle: TextStyle(color: Colors.white54),
                prefixIcon: Icon(Icons.search, color: Colors.white54),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final c = filtered[i];
                return ListTile(
                  focusNode: i == 0 ? _firstResultFocus : null,
                  leading: (c.logoUrl != null && c.logoUrl!.isNotEmpty)
                      ? Image.network(c.logoUrl!,
                          width: 32,
                          height: 32,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.tv, color: Colors.white54))
                      : const Icon(Icons.tv, color: Colors.white54),
                  title:
                      Text(c.name, style: const TextStyle(color: Colors.white)),
                  onTap: () => Navigator.of(context).pop(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
