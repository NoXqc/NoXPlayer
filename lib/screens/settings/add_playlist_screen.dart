import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../utils/tv_theme.dart';
import '../../utils/xtream.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import 'group_management_screen.dart';

/// Playlist source configuration — M3U URL or Xtream Codes login — plus the
/// "download everything, or choose groups first?" choice for Xtream
/// accounts, which decides what the catalog warm-up (see [PlaylistManager])
/// actually fetches.
class AddPlaylistScreen extends StatefulWidget {
  const AddPlaylistScreen({super.key});

  @override
  State<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends State<AddPlaylistScreen> {
  late String _mode; // 'm3u' or 'xtream'
  late TextEditingController _m3uController;
  late TextEditingController _epgController;
  late TextEditingController _xtreamServerController;
  late TextEditingController _xtreamUsernameController;
  late TextEditingController _xtreamPasswordController;
  bool _obscurePassword = true;

  /// Field-to-field navigation on a TV remote turned out not to work via
  /// D-pad Up/Down at all — reported on a real Firestick: opening a text
  /// field brings up the on-screen keyboard, and that keyboard is its own
  /// native overlay that can capture D-pad input for moving between its
  /// own keys, never handing arrow keys back to Flutter. The IME's own
  /// "Next"/"Done" action button (what `textInputAction` controls) is
  /// the one thing guaranteed to be reachable by the remote's select/OK
  /// button regardless of that, so field-to-field movement goes through
  /// `onSubmitted` + these explicit nodes instead of relying on arrow keys.
  final _m3uFocus = FocusNode();
  final _epgFocus = FocusNode();
  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  /// Target for the last field's "Done" action in each mode — landing on
  /// `.unfocus()` moved focus to the ambient scope rather than anywhere
  /// specific, which then made the *next* Down press restart from the
  /// top of the screen instead of continuing to Add Playlist. Requesting
  /// this node directly instead gives an obvious, specific landing spot.
  final _addButtonFocus = FocusNode();

  /// Tracks whichever text field last actually had focus, independent of
  /// whatever `FocusManager.instance.primaryFocus` says *right now* —
  /// reported directly on a Fire TV Stick: closing that field's on-screen
  /// keyboard with the physical Back button clears Flutter's own focus
  /// entirely (unlike a Formuler box, where the field stays logically
  /// focused once its keyboard is dismissed), so by the time Up/Down is
  /// pressed afterward, primaryFocus is already null/elsewhere and
  /// [_handleFieldEscapeKey] had nothing to escape *from*. Falling back
  /// to this instead of giving up survives that.
  FocusNode? _lastFocusedTextField;

  void _trackTextFieldFocus() {
    for (final node in [_m3uFocus, _epgFocus, _serverFocus, _usernameFocus, _passwordFocus]) {
      if (node.hasFocus) {
        _lastFocusedTextField = node;
        return;
      }
    }
  }

  /// Guards the *whole* add flow, not just the network fetch —
  /// `playlist.isLoading` goes back to false as soon as the fetch itself
  /// finishes, while the "download everything or choose groups" dialog is
  /// still open and the warm-up is only about to start. Tapping "Add
  /// Playlist" again in that window re-ran the whole thing a second time,
  /// which is how two overlapping warm-up passes happened.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final storage = context.read<StorageService>();
    _mode = storage.getPlaylistMode();
    _m3uController = TextEditingController(text: storage.getM3uUrl() ?? '');
    _epgController = TextEditingController(text: storage.getEpgUrl() ?? '');
    _xtreamServerController = TextEditingController(text: storage.getXtreamServer() ?? '');
    _xtreamUsernameController = TextEditingController(text: storage.getXtreamUsername() ?? '');
    _xtreamPasswordController = TextEditingController(text: storage.getXtreamPassword() ?? '');
    HardwareKeyboard.instance.addHandler(_handleFieldEscapeKey);
    for (final node in [_m3uFocus, _epgFocus, _serverFocus, _usernameFocus, _passwordFocus]) {
      node.addListener(_trackTextFieldFocus);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleFieldEscapeKey);
    for (final node in [_m3uFocus, _epgFocus, _serverFocus, _usernameFocus, _passwordFocus]) {
      node.removeListener(_trackTextFieldFocus);
    }
    _m3uController.dispose();
    _epgController.dispose();
    _xtreamServerController.dispose();
    _xtreamUsernameController.dispose();
    _xtreamPasswordController.dispose();
    _m3uFocus.dispose();
    _epgFocus.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _addButtonFocus.dispose();
    super.dispose();
  }

  /// `onSubmitted` (the keyboard's own Next/Done button) only ever moves
  /// *forward*. Reported directly: skip past a field some other way and
  /// there's no way back to it — pressing Up/Down while a field has focus
  /// normally does nothing (or moves the caret) rather than escaping,
  /// since `EditableText` claims arrow keys for itself whenever it has
  /// focus, regardless of direction. This is the same class of problem
  /// `DpadVerticalNav` originally existed for, scoped narrowly to just
  /// these text fields (not the whole screen — general Up/Down
  /// navigation elsewhere on this screen is plain default traversal,
  /// which is what's actually reliable on real remotes).
  ///
  /// Originally also gated on the on-screen keyboard being closed, to
  /// avoid fighting the field's own onSubmitted wiring — removed after
  /// being reported as causing exactly the bug it was meant to prevent:
  /// landing back on a field via default traversal (e.g. pressing Up
  /// from Add Playlist) re-focuses it, which reopens the keyboard
  /// automatically, which then blocked *this* handler on the very next
  /// press, leaving no way to continue past that field. There's no real
  /// conflict to guard against here in the first place — onSubmitted
  /// fires from the keyboard's own dedicated action button, never from
  /// an arrow key, so this can safely run regardless of keyboard state.
  bool _handleFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown &&
        event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return false;
    }

    final fields = _mode == 'm3u' ? [_m3uFocus, _epgFocus] : [_serverFocus, _usernameFocus, _passwordFocus];
    final current = FocusManager.instance.primaryFocus;
    var index = fields.indexWhere((n) => n == current);
    if (index < 0) index = fields.indexWhere((n) => n == _lastFocusedTextField);
    if (index < 0) return false;

    final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
    final next = index + delta;
    if (next < 0 || next >= fields.length) return false;
    fields[next].requestFocus();
    _lastFocusedTextField = fields[next];
    return true;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final storage = context.read<StorageService>();
      await storage.setPlaylistMode(_mode);

      if (!mounted) return;
      final playlist = context.read<PlaylistManager>();
      final epg = context.read<EpgService>();

      String epgUrl;

      if (_mode == 'xtream') {
        final server = _xtreamServerController.text.trim();
        final username = _xtreamUsernameController.text.trim();
        final password = _xtreamPasswordController.text.trim();

        if (server.isEmpty || username.isEmpty || password.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Server, username, and password are all required.')),
          );
          return;
        }

        // Some panels disable the get.php/xmltv.php export shortcuts while
        // keeping the real Xtream API (player_api.php) active — so the
        // playlist itself always goes through the real API, not a derived
        // M3U URL. xmltv.php is still used for EPG since that endpoint is
        // commonly left enabled even when get.php isn't.
        epgUrl = XtreamHelper.buildEpgUrl(server: server, username: username, password: password);
        await storage.setEpgUrl(epgUrl);

        await playlist.loadFromXtream(server: server, username: username, password: password);

        if (mounted && playlist.error == null) {
          await _promptDownloadScope(playlist);
        }
      } else {
        final m3uUrl = _m3uController.text.trim();
        epgUrl = _epgController.text.trim();

        await storage.setM3uUrl(m3uUrl);
        await storage.setEpgUrl(epgUrl);

        if (m3uUrl.isNotEmpty) {
          await playlist.loadFromUrl(m3uUrl);
        }
      }

      if (!mounted) return;
      final refreshInterval = storage.getRefreshInterval();
      if (epgUrl.isNotEmpty) {
        epg.startAutoRefresh(refreshInterval, epgUrl);
        // Not awaited — reported directly as "confirm the groups, and it
        // just goes back to the URL/username/password screen instead of
        // the main app." Root cause: this was awaited, so a slow EPG
        // fetch (network-dependent, can take a while for a large XMLTV
        // file) blocked reaching the code below that pops back to the
        // main app — and if the fetch ever threw (a timeout, a malformed
        // response), it aborted the rest of this method silently, with
        // no error shown, leaving the form sitting there looking stuck.
        // Warming the catalog already works this same fire-and-forget
        // way for the identical reason.
        unawaited(epg.refresh(epgUrl));
      } else {
        epg.stopAutoRefresh();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Playlist added.')));
      // Land back on the main app instead of leaving the user sitting on
      // this form — reported directly: finishing the whole add-playlist
      // (and Group Management confirm) flow left them stuck back here,
      // still with a text field focused, instead of on the TV/Movies/
      // TV Shows tabs. `scaffoldMessengerKey` is app-wide (see main.dart),
      // so the snackbar above still shows after this pop.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Asks "download everything, or choose groups first?" — and, crucially,
  /// doesn't start the background catalog warm-up until this is settled,
  /// so a "choose groups" pick actually takes effect on what gets fetched
  /// instead of racing an already-running fetch-everything pass.
  Future<void> _promptDownloadScope(PlaylistManager playlist) async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Download content'),
        content: const Text(
          'This provider has a large catalog. Download everything in the '
          'background, or choose which groups to include first?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('choose'),
            child: const Text('Choose Groups First'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('all'),
            child: const Text('Download All'),
          ),
        ],
      ),
    );

    if (choice == 'choose' && mounted) {
      final finished = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const GroupManagementScreen(deferLoading: true)),
      );
      if (finished != true) {
        // Left without pressing "Done" — physical back, or (what was
        // actually reported) an accidental pop while navigating between
        // categories. Silently downloading everything not yet hidden in
        // that case defeats the entire point of choosing groups first, so
        // this just stops here instead — the chosen hides are still saved,
        // and "Update content" (or reopening Group Management) picks up
        // right where they left off whenever they're ready.
        return;
      }
    }
    unawaited(playlist.warmAllCategories());
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();

    return withTvThemeIfNeeded(context, (context) => Scaffold(
      appBar: AppBar(title: const Text('Add Playlist')),
      // No custom D-pad handling for anything but the text fields' own
      // Next/Done wiring above — see SettingsMenuScreen's doc comment for
      // why: plain Flutter default focus traversal is what actually
      // works reliably on real remote hardware here.
      body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SectionLabel('Playlist source'),
            const SizedBox(height: 8),
            // Was a `SegmentedButton` — reported directly as making D-pad
            // navigation into this form erratic ("click multiple times
            // down up down up... got lucky"). `SegmentedButton` wraps its
            // segments in their own internal focus-traversal handling that
            // doesn't reliably follow this screen's simple top-to-bottom
            // document order. Two plain single-target buttons behave
            // exactly like every other row on this screen.
            Row(
              children: [
                Expanded(
                  child: ModeButton(
                    icon: Icons.link,
                    label: 'M3U URL',
                    selected: _mode == 'm3u',
                    onTap: () => setState(() => _mode = 'm3u'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ModeButton(
                    icon: Icons.dns,
                    label: 'Xtream Codes',
                    selected: _mode == 'xtream',
                    onTap: () => setState(() => _mode = 'xtream'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_mode == 'm3u') ...[
              TextField(
                controller: _m3uController,
                focusNode: _m3uFocus,
                decoration: const InputDecoration(
                  labelText: 'M3U Playlist URL',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _epgFocus.requestFocus(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _epgController,
                focusNode: _epgFocus,
                decoration: const InputDecoration(
                  labelText: 'EPG (XMLTV) URL',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addButtonFocus.requestFocus(),
              ),
            ] else ...[
              TextField(
                controller: _xtreamServerController,
                focusNode: _serverFocus,
                decoration: const InputDecoration(
                  labelText: 'Server URL (e.g. http://host:port)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _usernameFocus.requestFocus(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _xtreamUsernameController,
                focusNode: _usernameFocus,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _xtreamPasswordController,
                focusNode: _passwordFocus,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addButtonFocus.requestFocus(),
              ),
              const SizedBox(height: 8),
              Text(
                'The EPG (xmltv.php) URL is derived automatically from these credentials.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            if (playlist.isLoading) ...[
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(playlist.loadingPhase ?? 'Loading...')),
                ],
              ),
              const SizedBox(height: 12),
            ] else if (playlist.error != null) ...[
              Text(
                'Failed to add playlist.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton(
              focusNode: _addButtonFocus,
              onPressed: (playlist.isLoading || _saving) ? null : _save,
              child: const Text('Add Playlist'),
            ),
          ],
        ),
    ));
  }
}
