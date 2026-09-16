import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/m3u_group.dart';
import '../../services/playlist_manager.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/settings_scaffold.dart';

/// Lists every group/category (live, movies, TV shows) — including hidden
/// ones, which is the whole point of this screen — with per-group and
/// bulk "Hide All" / "Show All" controls. Anything hidden here disappears
/// from the corresponding tab on the main screen.
class GroupManagementScreen extends StatefulWidget {
  const GroupManagementScreen(
      {super.key, required this.playlistId, this.deferLoading = false});

  /// Which playlist this screen manages groups for — selecting a playlist
  /// in `PlaylistManagerScreen`'s own list *is* the "which playlist"
  /// picker; this screen itself only ever shows one playlist's groups at
  /// a time, reusing the exact same Hide All/Show All UI it always has.
  final String playlistId;

  /// True when opened from the initial "choose groups first" add-playlist
  /// step — checking a box there doesn't fetch that category immediately
  /// (which was causing rapid-fire loading/jank while picking groups);
  /// [PlaylistManager.warmAllCategories] does one batched pass over
  /// everything chosen right after this screen closes instead.
  final bool deferLoading;

  @override
  State<GroupManagementScreen> createState() => _GroupManagementScreenState();
}

class _GroupManagementScreenState extends State<GroupManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// Blocks every pop attempt (physical back, the Up-to-back shortcut,
  /// system back gesture) until either "Done" is pressed or the user
  /// confirms "yes, leave" in [_confirmLeave] — set true right before
  /// actually popping in both of those cases. This is the real fix for
  /// the reported glitch: an earlier pass only changed what an accidental
  /// exit *did afterward* (skip the auto-download), it didn't stop the
  /// exit itself from happening.
  bool _allowPop = false;

  Future<bool> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave group selection?'),
        content: const Text(
          'Your show/hide choices are saved, and anything still visible '
          'will start downloading — same as pressing Done.',
        ),
        // Plain TextButton/FilledButton left which one has D-pad focus
        // ambiguous — reported directly: FilledButton's permanent solid
        // fill looks the same whether it's actually focused or not, so
        // there's no way to tell the two apart until you guess and press
        // one. ModeButton is this app's established fix elsewhere for
        // exactly this — a solid fill only on real focus — just missed in
        // this one dialog.
        actions: [
          ModeButton(
            label: 'Stay',
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: 'Leave',
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  /// The AppBar's "Done" button (and the Up-arrow fallback that targets
  /// it) turned out not to be reliably reachable on real remotes — a
  /// Firestick user couldn't find any way to it besides a Bluetooth
  /// mouse. This is the actual fix: a 4th tab, reached by the exact same
  /// Right-arrow tab-switching already used to move between TV/Movies/TV
  /// Shows, with nothing on it but a single always-focused Confirm
  /// button — no hunting for it, no relying on Up-arrow doing the right
  /// thing on unfamiliar hardware.
  Future<void> _confirmDone() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save playlist?'),
        content: const Text(
          'Your playlist will be saved with the selected groups. You can '
          'always add or remove groups later in Settings > Group Management.',
        ),
        // Same ModeButton fix as _confirmLeave above — see its comment.
        actions: [
          ModeButton(
            label: 'Cancel',
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: 'Confirm',
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _allowPop = true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// One per tab (TV/Movies/TV Shows/Confirm) — lets [_goToTab] jump focus
  /// straight into the newly-selected tab's content instead of leaving
  /// focus wherever it was (which, on the tab that's now hidden behind the
  /// TabBarView animation, would be nowhere useful).
  final List<FocusScopeNode> _tabScopes =
      List.generate(4, (i) => FocusScopeNode(debugLabel: 'group-mgmt-tab-$i'));

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final scope in _tabScopes) {
      scope.dispose();
    }
    _doneButtonFocusNode.dispose();
    super.dispose();
  }

  /// Switches tabs directly, bound to Left/Right (and 1/2/3) below — a
  /// user checking off groups one at a time otherwise has to scroll all
  /// the way back up to the TabBar just to move from TV to Movies.
  void _goToTab(int index) {
    final clamped = index.clamp(0, 3);
    if (clamped == _tabController.index) return;
    setState(() => _tabController.index = clamped);
    _tabScopes[clamped].requestFocus();
  }

  /// Left/Right switching tabs unconditionally made "Show All"/"Hide All"
  /// unreachable from each other — they sit side by side in the same Row,
  /// and Right from "Show All" was jumping straight to the Movies tab
  /// instead of moving to "Hide All" right next to it. Try the normal
  /// move first; only switch tabs once there's nowhere further to go in
  /// that direction (same pattern as the browse grid's edge handling).
  void _handleTabArrow(TraversalDirection direction, int tabDelta) {
    final moved =
        FocusManager.instance.primaryFocus?.focusInDirection(direction) ??
            false;
    if (!moved) _goToTab(_tabController.index + tabDelta);
  }

  /// The AppBar's "Done" button wasn't reachable by D-pad at all — nothing
  /// handed focus up to it, so it was only reachable by touch/mouse (the
  /// physical device Back button still works to leave, via [PopScope]
  /// above, but that's a different action from a deliberate "Done").
  /// Same fallback pattern as the tab arrows: try moving up normally
  /// first (into the checkbox list), and only jump to Done once there's
  /// genuinely nowhere further up to go.
  final FocusNode _doneButtonFocusNode =
      FocusNode(debugLabel: 'group-mgmt-done');

  void _handleUpArrow() {
    final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.up) ??
        false;
    if (!moved) _doneButtonFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();

    return withTvThemeIfNeeded(
        context,
        (context) => PopScope(
            canPop: _allowPop,
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) return;
              final leave = await _confirmLeave();
              if (!context.mounted || !leave) return;
              setState(() => _allowPop = true);
              if (!context.mounted) return;
              // A confirmed "Leave" is just as deliberate as pressing "Done" —
              // the whole point of the prompt is to rule out an *accidental*
              // exit, not to treat a confirmed one differently. Popping with
              // `false`/no result here made AddPlaylistScreen._promptDownloadScope
              // think the user bailed without finishing, silently skipping the
              // warm-up download even though they'd explicitly confirmed leaving.
              Navigator.of(context).pop(true);
            },
            child: SettingsScaffold(
              title: 'Group Management',
              // Explicit "Done" so the caller can tell a deliberate finish apart
              // from just leaving the screen some other way (physical back, an
              // accidental pop, or confirming "leave" in the prompt above
              // without having pressed Done). See
              // AddPlaylistScreen._promptDownloadScope for why that distinction
              // matters here specifically: it decides whether to start
              // downloading everything not yet hidden.
              actions: [
                TextButton(
                  focusNode: _doneButtonFocusNode,
                  onPressed: () {
                    setState(() => _allowPop = true);
                    Navigator.of(context).pop(true);
                  },
                  child:
                      const Text('Done', style: TextStyle(color: Colors.white)),
                ),
              ],
              bottom: TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'TV'),
                  Tab(text: 'Movies'),
                  Tab(text: 'TV Shows'),
                  Tab(text: 'Confirm'),
                ],
              ),
              body: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                      _handleTabArrow(TraversalDirection.left, -1),
                  const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                      _handleTabArrow(TraversalDirection.right, 1),
                  const SingleActivator(LogicalKeyboardKey.digit1): () =>
                      _goToTab(0),
                  const SingleActivator(LogicalKeyboardKey.digit2): () =>
                      _goToTab(1),
                  const SingleActivator(LogicalKeyboardKey.digit3): () =>
                      _goToTab(2),
                  const SingleActivator(LogicalKeyboardKey.digit4): () =>
                      _goToTab(3),
                  const SingleActivator(LogicalKeyboardKey.arrowUp):
                      _handleUpArrow,
                },
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    FocusScope(
                      node: _tabScopes[0],
                      child: _GroupList(
                        groups: playlist.tvGroups
                            .where((g) => g.playlistId == widget.playlistId)
                            .toList(),
                        playlist: playlist,
                        playlistId: widget.playlistId,
                        deferLoading: widget.deferLoading,
                      ),
                    ),
                    FocusScope(
                      node: _tabScopes[1],
                      child: _GroupList(
                        groups: playlist.vodGroups
                            .where((g) => g.playlistId == widget.playlistId)
                            .toList(),
                        playlist: playlist,
                        playlistId: widget.playlistId,
                        deferLoading: widget.deferLoading,
                      ),
                    ),
                    FocusScope(
                      node: _tabScopes[2],
                      child: _GroupList(
                        groups: playlist.seriesGroups
                            .where((g) => g.playlistId == widget.playlistId)
                            .toList(),
                        playlist: playlist,
                        playlistId: widget.playlistId,
                        deferLoading: widget.deferLoading,
                      ),
                    ),
                    FocusScope(
                      node: _tabScopes[3],
                      child: _ConfirmTab(onConfirm: _confirmDone),
                    ),
                  ],
                ),
              ),
            )));
  }
}

class _ConfirmTab extends StatelessWidget {
  const _ConfirmTab({required this.onConfirm});

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 48, color: Colors.white70),
            const SizedBox(height: 16),
            const Text(
              'If you are done selecting your groups, press Confirm below.\n\n'
              'If you are not done yet, press Left to go back to your categories.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            FilledButton(
              autofocus: true,
              onPressed: onConfirm,
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.playlist,
    required this.playlistId,
    this.deferLoading = false,
  });

  final List<M3uGroup> groups;
  final PlaylistManager playlist;
  final String playlistId;
  final bool deferLoading;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const Center(
          child: Text('No categories yet — load a playlist first.'));
    }

    final titles = groups.map((g) => g.title);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => playlist.setGroupsHidden(
                      playlistId, titles, false,
                      loadImmediately: !deferLoading),
                  child: const Text('Show All'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      playlist.setGroupsHidden(playlistId, titles, true),
                  child: const Text('Hide All'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final group = groups[index];
              // Confirmed on a real Formuler box: without any key, toggling
              // visibility (individually, or via Show/Hide All) updated the
              // underlying data immediately and correctly — leaving the
              // screen and coming back always showed the right checkmarks —
              // but the *already-mounted* checkbox never repainted in place
              // to reflect it, even though the identical build worked fine
              // on a Firestick. That's a stale-repaint bug in this device's
              // GPU/renderer failing to redraw an in-place property change
              // on the existing render object, not a logic bug.
              //
              // First fix attempt keyed the whole CheckboxListTile to its
              // shown/hidden value, which did force a repaint — but it also
              // tore down and rebuilt the row's own focus node every single
              // toggle, so a D-pad user checking one box at a time watched
              // focus jump to a neighboring row on its own (Flutter's focus
              // manager losing the just-disposed node and auto-resolving to
              // the nearest one). The row itself — and the focus/tap target
              // it owns — must stay the *same* element across a toggle;
              // only the small checkbox glyph that wasn't repainting needs
              // to be torn down and recreated. So the key moves onto just
              // that inner piece, and the row is built by hand (instead of
              // CheckboxListTile) so that piece can be keyed independently
              // of the focusable row around it.
              //
              // Second fix attempt: kept `Checkbox` itself, just wrapped in
              // a `KeyedSubtree` keyed to `group.isHidden` — confirmed on
              // the same Formuler box as STILL not reliably repainting.
              // Data was verified correct throughout (toggling really did
              // flip `_hiddenGroups`; a subsequent full sync used the
              // correct set) — this is a pure paint bug, not a logic one,
              // and it survives even a full Element recreation, which
              // means the problem isn't identity/keying at all — it's
              // something about repainting `Checkbox` specifically on this
              // device. `Checkbox` is a full Material widget with its own
              // ink/animation machinery; swapping to a bare `Icon` (no
              // Material ink response, no internal AnimatedContainer, as
              // simple a paint primitive as Flutter has) sidesteps
              // whatever that is rather than trying to force it again.
              //
              // Three more fix attempts here, all confirmed on a real
              // Fire Stick as NOT fixing this: forcing the whole
              // `_GroupList` to rebuild once via a changing key a frame
              // after this screen's first paint; forcing a brand new
              // compositing *layer* via a keyed `RepaintBoundary` (kept
              // anyway over the `KeyedSubtree` it replaced — a strict
              // superset); and automatically popping this screen and
              // silently pushing a fresh copy of itself, which got stuck
              // exactly the same way on the very first toggle. That last
              // one also ruled out "just needs elapsed time since the
              // heavy load" (confirmed separately too: waiting 60+ real
              // seconds before trying Hide All again changed nothing) —
              // so nothing in *this* screen's own widget tree, however
              // rebuilt, was ever going to fix it.
              //
              // The actual root cause turned out to live somewhere this
              // file never touches at all: `PlaylistManager` firing
              // `notifyListeners()` synchronously *during* `TvHomeScreen`'s
              // own build (TvHomeScreen stays mounted, just covered, under
              // the whole Add Playlist → Group Management stack, and
              // still rebuilds when the provider above it notifies).
              // Confirmed directly via a debug-mode Flutter assertion
              // ("setState() or markNeedsBuild() called during build")
              // that release mode has no equivalent safety net for — see
              // `PlaylistManager._loadLiveChannelsOnce`'s doc comment for
              // the actual fix. Real hardware confirmed fixed end-to-end
              // after that change, so the `RepaintBoundary` above is
              // likely no longer doing any real work — left in place
              // anyway since it's strictly safe and costs nothing.
              return ListTile(
                key: ValueKey(group.title),
                title: Text(group.title),
                trailing: RepaintBoundary(
                  key: ValueKey(group.isHidden),
                  child: Icon(
                    group.isHidden ? Icons.circle_outlined : Icons.check_circle,
                    color: group.isHidden
                        ? Colors.white54
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                onTap: () => playlist.setGroupHidden(
                  playlistId,
                  group.title,
                  !group.isHidden,
                  loadImmediately: !deferLoading,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
