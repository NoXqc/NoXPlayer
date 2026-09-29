import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/auto_pair_flow.dart';
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
/// Embedded as the "EPG Matching" tab of [EpgSettingsScreen] — not a
/// screen of its own (no `SettingsScaffold` here; the parent already
/// provides one, shared across all its tabs) despite the name and the
/// `State`/`Screen` naming left as-is from when it was one, to keep the
/// rename contained to what's actually user-visible.
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
  final _searchFocus = FocusNode(debugLabel: 'epg-matching-search');
  final _autoPairFocus = FocusNode(debugLabel: 'epg-matching-auto-pair');

  /// The currently-first row's own node — retargeted to whichever channel
  /// is actually first after every filter/search change (see [build]) so
  /// Down from the search field always has a real, live node to jump to.
  final _firstResultFocus = FocusNode(debugLabel: 'epg-matching-first-result');

  /// See `ChannelLinkingScreen._reviewFilter`'s doc comment — same idea,
  /// for this screen's own "Auto-Pair Channels".
  Set<String>? _reviewFilter;

  /// Escapes the search field in either direction — plain default arrow-
  /// key traversal doesn't reliably escape a focused `TextField` at all
  /// on real remote hardware, the exact same root cause
  /// `AddPlaylistScreen._handleFieldEscapeKey` already documents and
  /// fixes for its own fields. Reported directly here too: stuck in the
  /// search field either way, unable to reach the buttons above *or* the
  /// list below it (an Up-only version of this fix shipped first, on the
  /// assumption Down was already reaching the list fine on its own —
  /// confirmed wrong, it needs the exact same explicit handling as Up).
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

  Future<void> _autoPair(PlaylistManager playlist, EpgService epg) async {
    if (epg.channelCatalog.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Auto-Pair Channels'),
          content:
              const Text('No EPG feed has been loaded yet this session — run '
                  '"Update EPG Now" first so there\'s a channel directory to '
                  'match against.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final result = await runAutoPairFlow(context,
        autoPair: () => playlist.autoPairEpgIds(epg));
    if (!mounted) return;
    setState(() => _reviewFilter = result.review ? result.paired : null);
  }

  Future<void> _unpair(PlaylistManager playlist) async {
    final didUnpair = await confirmAndUnpair(context,
        autoPairedCount: playlist.autoPairedEpgOverrideCount,
        unpair: playlist.unpairAutoEpgOverrides);
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
    final epg = context.watch<EpgService>();
    // Live TV only, and already excludes hidden channels — the same list
    // the sidebar itself shows, so nothing turns up here the user can't
    // otherwise see and wouldn't recognize.
    final channels = playlist.visibleChannels(category: 'tv');
    final query = _searchController.text.trim().toLowerCase();
    final reviewFilter = _reviewFilter;
    final filtered = (query.isEmpty
            ? channels
            : channels.where((c) => c.name.toLowerCase().contains(query)))
        .where((c) => reviewFilter == null || reviewFilter.contains(c.id))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  focusNode: _autoPairFocus,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Auto-Pair Channels'),
                  onPressed: () => _autoPair(playlist, epg),
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
                      focusNode: i == 0 ? _firstResultFocus : null,
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
                        final picked = await Navigator.of(context).push<String>(
                            MaterialPageRoute(
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
