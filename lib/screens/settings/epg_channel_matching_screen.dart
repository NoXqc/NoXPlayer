import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/settings_scaffold.dart';

/// Lets the user fix a channel whose EPG programme data is missing or
/// wrong even though a third-party XMLTV source is configured and parses
/// fine — see `Channel.epgIdOverride`'s doc comment for why a provider's
/// own `epg_channel_id`/`tvg-id` can simply not line up with whatever
/// feed is configured (reported directly: Trex channels with no match at
/// all against an otherwise-working third-party feed). No custom D-pad
/// handling here — see `EpgSettingsScreen`'s own doc comment for why
/// plain Flutter default focus traversal is the right call for a
/// Settings-family screen like this one.
///
/// Lists every visible live channel with its current match state; tapping
/// one opens [_AssignEpgScreen] to search the loaded feed's own channel
/// directory and assign a specific entry (or clear back to automatic via
/// the trailing X once one's assigned).
class EpgChannelMatchingScreen extends StatefulWidget {
  const EpgChannelMatchingScreen({super.key});

  @override
  State<EpgChannelMatchingScreen> createState() =>
      _EpgChannelMatchingScreenState();
}

class _EpgChannelMatchingScreenState extends State<EpgChannelMatchingScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final epg = context.watch<EpgService>();
    // Live TV only, and already excludes hidden channels — the same list
    // the sidebar itself shows, so nothing turns up here the user can't
    // otherwise see and wouldn't recognize.
    final channels = playlist.visibleChannels(category: 'tv');
    final query = _searchController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? channels
        : channels.where((c) => c.name.toLowerCase().contains(query)).toList();

    return SettingsScaffold(
      title: 'Channel Matching',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Search your channels',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (epg.channelCatalog.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'No EPG feed has been loaded yet this session — run '
                '"Update EPG Now" above first so there\'s a channel '
                'directory to search.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No channels found.'))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final channel = filtered[i];
                      final overrideId = channel.epgIdOverride;
                      final hasPrograms =
                          epg.getPrograms(channel.epgId).isNotEmpty;
                      final String status;
                      final bool ok;
                      if (overrideId != null) {
                        status =
                            'Assigned: ${epg.channelCatalog[overrideId] ?? overrideId}';
                        ok = true;
                      } else if (hasPrograms) {
                        status = 'Matched automatically';
                        ok = true;
                      } else {
                        status = 'No program data';
                        ok = false;
                      }
                      return ListTile(
                        title: Text(channel.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(status,
                            style: TextStyle(
                                color: ok
                                    ? null
                                    : Theme.of(context).colorScheme.error)),
                        trailing: overrideId != null
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                tooltip: 'Clear assignment',
                                onPressed: () =>
                                    playlist.setEpgIdOverride(channel, null),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await Navigator.of(context)
                              .push<String>(MaterialPageRoute(
                                  builder: (_) => _AssignEpgScreen(
                                      channelName: channel.name)));
                          if (picked != null) {
                            await playlist.setEpgIdOverride(channel, picked);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Searches [EpgService.channelCatalog] — the loaded feed's own directory
/// of `<channel id>` -> display name — and pops the picked id back to
/// [EpgChannelMatchingScreen]. [channelName] is shown for context only
/// (the search starts empty rather than prefilled with it: this app's
/// own branded channel names, e.g. "4K| ESPN UHD", routinely share no
/// substring at all with a feed's plain "ESPN", so prefilling would often
/// show zero results by default instead of actually helping).
class _AssignEpgScreen extends StatefulWidget {
  const _AssignEpgScreen({required this.channelName});
  final String channelName;

  @override
  State<_AssignEpgScreen> createState() => _AssignEpgScreenState();
}

class _AssignEpgScreenState extends State<_AssignEpgScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final query = _searchController.text.trim().toLowerCase();
    final entries = epg.channelCatalog.entries
        .where((e) => query.isEmpty || e.value.toLowerCase().contains(query))
        .toList()
      // A candidate with something airing right now is far more likely
      // to be the actual right pick than one the feed has no current
      // data for at all — surfaced first, alphabetical within each group.
      ..sort((a, b) {
        final aHas = epg.currentProgramInCatalog(a.key) != null;
        final bHas = epg.currentProgramInCatalog(b.key) != null;
        if (aHas != bHas) return aHas ? -1 : 1;
        return a.value.compareTo(b.value);
      });

    return SettingsScaffold(
      title: 'Assign "${widget.channelName}"',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Search the EPG feed\'s channels',
                hintText: widget.channelName,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: epg.channelCatalog.isEmpty
                // Distinct from a genuine no-match below — otherwise this
                // reads as "nothing matched your search" when the real
                // cause is "nothing's been loaded into memory this app
                // process at all yet" (reported directly: a reinstall —
                // which always restarts the process, and this catalog
                // isn't persisted to disk — silently emptied it out from
                // under an otherwise-correct search).
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No EPG feed has been loaded yet this app session — '
                      'go back and run "Update EPG Now" first.',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  )
                : entries.isEmpty
                    ? const Center(child: Text('No matches.'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final entry = entries[i];
                          final nowPlaying =
                              epg.currentProgramInCatalog(entry.key);
                          return ListTile(
                            title: Text(entry.value),
                            // What this candidate is airing right now,
                            // when the feed has that — the actual fix for
                            // picking between several plausible-looking
                            // candidates (e.g. espn.us vs espn2.us vs
                            // espnu.us) without trial and error: match it
                            // against whatever the real channel is
                            // showing (reported directly).
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry.key,
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 11)),
                                Text(
                                  nowPlaying != null
                                      ? 'Now: ${nowPlaying.title}'
                                      : 'No current program data',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontStyle: nowPlaying == null
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                      color: nowPlaying == null
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                          : null),
                                ),
                              ],
                            ),
                            isThreeLine: true,
                            onTap: () => Navigator.of(context).pop(entry.key),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
