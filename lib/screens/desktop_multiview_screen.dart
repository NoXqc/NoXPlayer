import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/playlist_manager.dart';

/// Windows-only: a grid of simultaneously-playing live channels —
/// requested directly, citing TiviMate's own multiview (proven to run
/// fine even on a Fire Stick) and that a Windows PC has far more headroom
/// than any box this app otherwise targets. Each cell owns a completely
/// independent `media_kit` `Player`/`VideoController` — safe to run
/// several at once the same way `DesktopMiniPlayer`'s preview box already
/// is (see its own doc comment): `media_kit`'s texture-based rendering
/// supports many simultaneous `Video` widgets, unlike `video_player_hdr`'s
/// platform views, which is exactly why this exists only here and not on
/// mobile/TV. Deliberately standalone, same "doesn't touch
/// PlaybackService" shape as `DesktopPlayerScreen` — see that screen's own
/// doc comment for the fuller reasoning this one shares.
///
/// Only one cell's audio plays at a time (every other `Player` is muted,
/// not paused — all four keep decoding/rendering their video live) —
/// tapping a filled cell makes it the audio-focused one, mirroring
/// TiviMate's own "tap to swap audio" multiview behavior rather than
/// trying to invent a different convention.
class DesktopMultiviewScreen extends StatefulWidget {
  const DesktopMultiviewScreen({super.key});

  @override
  State<DesktopMultiviewScreen> createState() =>
      _DesktopMultiviewScreenState();
}

class _MultiviewCell {
  Channel? channel;
  Player? player;
  VideoController? controller;
}

class _DesktopMultiviewScreenState extends State<DesktopMultiviewScreen> {
  static const _cellCount = 4;
  final List<_MultiviewCell> _cells =
      List.generate(_cellCount, (_) => _MultiviewCell());
  int _activeCell = 0;

  @override
  void dispose() {
    for (final cell in _cells) {
      cell.player?.dispose();
    }
    super.dispose();
  }

  void _assign(int index, Channel channel) {
    final cell = _cells[index];
    cell.player?.dispose();
    final player = Player();
    // See DesktopPlayerScreen's identical fix for the full story — mpv's
    // default live-reconnect handling silently stalls this provider's
    // stream after ~15-20s (no error, just a frozen frame), confirmed as
    // the actual cause of the exact symptom reported here, not a
    // provider connection-limit issue despite looking like one at first.
    (player.platform as NativePlayer)
        .setProperty('demuxer-lavf-o', 'reconnect_streamed=0');
    final controller = VideoController(player);
    player.open(Media(channel.url));
    player.setVolume(index == _activeCell ? 100 : 0);
    setState(() {
      cell.channel = channel;
      cell.player = player;
      cell.controller = controller;
    });
  }

  /// Same manual-relaunch idea as `DesktopPlayerScreen._reload`/
  /// `PlayerControls`' own Reload button — for a cell that's silently
  /// stalled (frozen frame, no error), requested directly for every
  /// multiview cell the same way.
  void _reload(int index) {
    final cell = _cells[index];
    final channel = cell.channel;
    if (channel == null) return;
    cell.player?.open(Media(channel.url));
  }

  void _clear(int index) {
    _cells[index].player?.dispose();
    setState(() => _cells[index] = _MultiviewCell());
  }

  void _setActive(int index) {
    if (_cells[index].channel == null) return;
    setState(() => _activeCell = index);
    for (var i = 0; i < _cells.length; i++) {
      _cells[i].player?.setVolume(i == _activeCell ? 100 : 0);
    }
  }

  Future<void> _openPicker(int index) async {
    final playlist = context.read<PlaylistManager>();
    final channels = playlist.visibleChannels(category: 'tv');
    final chosen = await showDialog<Channel>(
      context: context,
      builder: (_) => _ChannelPickerDialog(channels: channels),
    );
    if (chosen != null) _assign(index, chosen);
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
                    const Text('= audio — click a channel to switch',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                      childAspectRatio: 16 / 9,
                    ),
                    itemCount: _cellCount,
                    itemBuilder: (context, i) => _buildCell(i),
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
    return InkWell(
      onTap: () =>
          cell.channel == null ? _openPicker(index) : _setActive(index),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
              color: active ? Colors.amber : Colors.white24,
              width: active ? 3 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cell.controller != null)
              Video(controller: cell.controller!, controls: NoVideoControls)
            else
              const ColoredBox(
                color: Color(0xFF1A1A1A),
                child: Center(
                  child: Icon(Icons.add_circle_outline,
                      color: Colors.white38, size: 40),
                ),
              ),
            if (cell.channel != null)
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
                      if (active) ...[
                        const Icon(Icons.volume_up,
                            color: Colors.amber, size: 15),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          cell.channel!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh,
                            color: Colors.white70, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Reload',
                        onPressed: () => _reload(index),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.swap_horiz,
                            color: Colors.white70, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Change channel',
                        onPressed: () => _openPicker(index),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white70, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Remove',
                        onPressed: () => _clear(index),
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

/// A plain search-and-pick list — the live channel list this draws from
/// can run into the tens of thousands across every enabled playlist (see
/// `PlaylistManager.visibleChannels`), so a simple substring filter over
/// a lazily-built `ListView` is what keeps this responsive rather than
/// anything fancier.
class _ChannelPickerDialog extends StatefulWidget {
  const _ChannelPickerDialog({required this.channels});

  final List<Channel> channels;

  @override
  State<_ChannelPickerDialog> createState() => _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends State<_ChannelPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.channels
        : widget.channels
            .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      child: SizedBox(
        width: 480,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _searchController,
                autofocus: true,
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
                    leading: (c.logoUrl != null && c.logoUrl!.isNotEmpty)
                        ? Image.network(c.logoUrl!,
                            width: 32,
                            height: 32,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.tv, color: Colors.white54))
                        : const Icon(Icons.tv, color: Colors.white54),
                    title: Text(c.name,
                        style: const TextStyle(color: Colors.white)),
                    onTap: () => Navigator.of(context).pop(c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
