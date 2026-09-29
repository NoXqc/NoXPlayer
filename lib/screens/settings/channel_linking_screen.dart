import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/channel.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/auto_pair_flow.dart';
import '../../widgets/settings_scaffold.dart';

/// Manual cross-playlist "same real-world channel" linking — see
/// `AppConstants.keyChannelLinks`'s doc comment for why this has to be
/// manual (there's no reliable automatic way to tell two different
/// providers' channels are the same one; the exact same problem already
/// confirmed for EPG ids one level down). Lets a live channel on one
/// playlist name its equivalent on another, so `PlayerControls`'s
/// "switch to linked channel" button and the playback-error screen's own
/// version of it have somewhere to point.
///
/// One-to-one only, by design — a channel links to at most one other
/// channel, not a chain across three or more playlists. No custom D-pad
/// handling here, same reasoning as `EpgSettingsScreen`/
/// `SettingsMenuScreen`: plain Flutter default focus traversal is what
/// actually works reliably on real remote hardware for a Settings-family
/// screen like this one.
///
/// Embedded as the "Channel Pairing" tab of [EpgSettingsScreen] — not a
/// screen of its own (no `SettingsScaffold` here; the parent already
/// provides one, shared across all its tabs). [_PickLinkedChannelScreen]
/// below stays a real pushed screen though — picking a link is a modal-
/// feeling flow, not something that belongs embedded in a tab.
class ChannelLinkingScreen extends StatefulWidget {
  const ChannelLinkingScreen({super.key});

  @override
  State<ChannelLinkingScreen> createState() => _ChannelLinkingScreenState();
}

class _ChannelLinkingScreenState extends State<ChannelLinkingScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'channel-pairing-search');
  final _autoPairFocus = FocusNode(debugLabel: 'channel-pairing-auto-pair');

  /// See `EpgChannelMatchingScreen._firstResultFocus`'s doc comment.
  final _firstResultFocus =
      FocusNode(debugLabel: 'channel-pairing-first-result');

  /// Non-null right after "Auto-Pair Channels" and choosing Review —
  /// narrows the list to just the composite `Channel.id`s that pass
  /// paired, instead of every channel. Cleared by editing the search
  /// field (typing a fresh query is a clearer "I'm done reviewing, I want
  /// to look for something else" signal than a separate button) or by
  /// running Auto-Pair/Unpair again.
  Set<String>? _reviewFilter;

  /// See `EpgChannelMatchingScreen._handleSearchEscape`'s doc comment —
  /// same fix, same bug (in both directions — an Up-only version shipped
  /// first and was confirmed still not enough), reported directly
  /// against this screen too.
  bool _handleSearchEscape(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowUp &&
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return false;
    }
    if (FocusManager.instance.primaryFocus != _searchFocus) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _autoPairFocus.requestFocus();
    } else {
      _firstResultFocus.requestFocus();
    }
    return true;
  }

  Future<void> _autoPair(PlaylistManager playlist) async {
    final result =
        await runAutoPairFlow(context, autoPair: playlist.autoPairChannelLinks);
    if (!mounted) return;
    setState(() => _reviewFilter = result.review ? result.paired : null);
  }

  Future<void> _unpair(PlaylistManager playlist) async {
    final didUnpair = await confirmAndUnpair(context,
        autoPairedCount: playlist.autoPairedChannelLinkCount,
        unpair: playlist.unpairAutoChannelLinks);
    if (!mounted || !didUnpair) return;
    setState(() => _reviewFilter = null);
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleSearchEscape);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleSearchEscape);
    _searchController.dispose();
    _searchFocus.dispose();
    _autoPairFocus.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    // Every enabled playlist's live channels together, not scoped to one —
    // linking is inherently a relationship *between* playlists, so this
    // list needs to show all of them side by side (with which playlist
    // each row belongs to) rather than picking one as "the" source.
    final channels = playlist.visibleChannels(category: 'tv');
    final query = _searchController.text.trim().toLowerCase();
    final reviewFilter = _reviewFilter;
    final filtered = (query.isEmpty
            ? channels
            : channels.where((c) => c.name.toLowerCase().contains(query)))
        .where((c) => reviewFilter == null || reviewFilter.contains(c.id))
        .toList();
    final enabledCount = playlist.profiles.where((p) => p.enabled).length;
    final canLink = enabledCount >= 2;

    return Column(
      children: [
        if (!canLink)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'Add and enable a second playlist first — a link connects '
              'a channel on one playlist to its equivalent on another.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (canLink)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    focusNode: _autoPairFocus,
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Auto-Pair Channels'),
                    onPressed: () => _autoPair(playlist),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.undo),
                    label: const Text('Unpair Channels'),
                    onPressed: () => _unpair(playlist),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            decoration: InputDecoration(
              labelText: reviewFilter != null
                  ? 'Reviewing ${reviewFilter.length} auto-paired channel${reviewFilter.length == 1 ? '' : 's'} — type to search all instead'
                  : 'Search your channels',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() {
              if (value.isNotEmpty) _reviewFilter = null;
            }),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No channels found.'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final channel = filtered[i];
                    final link = playlist.channelLinkFor(channel);
                    final linkedChannel =
                        link == null ? null : playlist.resolveChannelLink(link);
                    final ownPlaylistName =
                        playlist.playlistNameFor(channel.playlistId);
                    final String status;
                    final bool isError;
                    if (link == null) {
                      status = 'Not linked';
                      isError = false;
                    } else if (linkedChannel == null) {
                      // The linked playlist was removed/disabled, or that
                      // channel disappeared from a refreshed catalog —
                      // surfaced rather than silently resolving to
                      // nothing the next time playback actually needs it.
                      status = 'Linked channel no longer available';
                      isError = true;
                    } else {
                      status =
                          'Linked to ${playlist.playlistNameFor(link.playlistId)}: ${linkedChannel.name}';
                      isError = false;
                    }
                    return ListTile(
                      focusNode: i == 0 ? _firstResultFocus : null,
                      title: Text(channel.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('$ownPlaylistName — $status',
                          style: TextStyle(
                              color: isError
                                  ? Theme.of(context).colorScheme.error
                                  : null)),
                      trailing: link != null
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              tooltip: 'Clear link',
                              onPressed: () =>
                                  playlist.setChannelLink(channel, null),
                            )
                          : Icon(Icons.chevron_right,
                              color: canLink ? null : Colors.white24),
                      onTap: !canLink
                          ? null
                          : () async {
                              final picked = await Navigator.of(context)
                                  .push<Channel>(MaterialPageRoute(
                                      builder: (_) => _PickLinkedChannelScreen(
                                          source: channel)));
                              if (picked != null) {
                                await playlist.setChannelLink(channel, (
                                  playlistId: picked.playlistId,
                                  rawId: picked.rawId
                                ));
                              }
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Searches every *other* enabled playlist's live channels (never the
/// source channel's own playlist — same-playlist failover is already the
/// backup-servers mechanism, a link to another channel on the same
/// playlist wouldn't mean anything) and pops the picked [Channel] back to
/// [ChannelLinkingScreen].
class _PickLinkedChannelScreen extends StatefulWidget {
  const _PickLinkedChannelScreen({required this.source});

  final Channel source;

  @override
  State<_PickLinkedChannelScreen> createState() =>
      _PickLinkedChannelScreenState();
}

class _PickLinkedChannelScreenState extends State<_PickLinkedChannelScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final candidates = playlist
        .visibleChannels(category: 'tv')
        .where((c) => c.playlistId != widget.source.playlistId)
        .toList();
    final query = _searchController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? candidates
        : candidates
            .where((c) => c.name.toLowerCase().contains(query))
            .toList();

    return SettingsScaffold(
      title: 'Link "${widget.source.name}"',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search other playlists\' channels',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No matches.'))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final channel = filtered[i];
                      return ListTile(
                        title: Text(channel.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle:
                            Text(playlist.playlistNameFor(channel.playlistId)),
                        onTap: () => Navigator.of(context).pop(channel),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
