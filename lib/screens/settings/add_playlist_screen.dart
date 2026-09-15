import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../utils/smart_add_parser.dart';
import '../../utils/tv_theme.dart';
import '../../utils/xtream.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../catalog_sync_screen.dart';
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
  late String _mode; // 'm3u', 'xtream', or 'smart' (a UI-only tab — see _save)
  late TextEditingController _m3uController;
  late TextEditingController _epgController;
  late TextEditingController _xtreamServerController;
  late TextEditingController _xtreamUsernameController;
  late TextEditingController _xtreamPasswordController;
  bool _obscurePassword = true;

  /// Smart Add: paste-and-parse for the common case of copying a
  /// provider's whole welcome message off a phone and typing it in via
  /// the Fire Stick's QR-code-to-phone-keyboard relay — one paste instead
  /// of three separate fields to hunt values out of by hand. See
  /// [parseSmartAddText]'s doc comment for the parsing approach.
  final _smartPasteController = TextEditingController();

  /// Every server URL the parser found, most-likely-correct first — shown
  /// as a pick list rather than silently committing to the first one,
  /// since a sloppy copy-paste (e.g. selecting across a line break) can
  /// glue a stray character from an adjacent line onto an otherwise-good
  /// URL. Requested directly: "that way they could select which server or
  /// proper URL they want."
  List<String> _smartServerCandidates = [];
  String? _smartSelectedServer;

  /// Whether Smart Add has parsed its pasted text yet — before this, the
  /// tab shows just the paste box; after, it shows the candidate picker
  /// plus the same server/username/password fields the Xtream tab uses
  /// (reusing those controllers directly, so there's exactly one place
  /// that actually gets saved regardless of which tab filled it in).
  bool _smartParsed = false;

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
    _smartPasteController.dispose();
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

  /// Smart Add has no save path of its own — parsing just fills the same
  /// controllers the Xtream tab reads from, so from here on it's really an
  /// Xtream login, and is persisted/loaded as one.
  String get _effectiveMode => _mode == 'smart' ? 'xtream' : _mode;

  void _handleSmartParse() {
    final raw = _smartPasteController.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste some text first.')),
      );
      return;
    }
    final result = parseSmartAddText(raw);
    if (result.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't find anything usable in that text.")),
      );
      return;
    }
    setState(() {
      _smartServerCandidates = result.serverCandidates;
      _smartSelectedServer = result.serverCandidates.isNotEmpty ? result.serverCandidates.first : null;
      _xtreamServerController.text = _smartSelectedServer ?? '';
      _xtreamUsernameController.text = result.username;
      _xtreamPasswordController.text = result.password;
      _smartParsed = true;
    });
  }

  void _resetSmartAdd() {
    setState(() {
      _smartParsed = false;
      _smartServerCandidates = [];
      _smartSelectedServer = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final storage = context.read<StorageService>();
      final mode = _effectiveMode;
      await storage.setPlaylistMode(mode);

      if (!mounted) return;
      final playlist = context.read<PlaylistManager>();
      final epg = context.read<EpgService>();

      String epgUrl;

      if (mode == 'xtream') {
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

        // A failed authenticate() (bad credentials, server down/blocked,
        // account expired) sets playlist.error and returns normally rather
        // than throwing — so this must be checked explicitly. Previously
        // the success toast + pop-to-main-app below ran unconditionally,
        // meaning a genuine auth failure still told the user "Playlist
        // added" and dropped them on the empty-catalog home screen with no
        // indication anything went wrong — confirmed directly against a
        // backup server that was actually rejecting the credentials.
        if (!mounted) return;
        if (playlist.error != null) return;

        await _promptDownloadScope(playlist);
      } else {
        final m3uUrl = _m3uController.text.trim();
        epgUrl = _epgController.text.trim();

        await storage.setM3uUrl(m3uUrl);
        await storage.setEpgUrl(epgUrl);

        if (m3uUrl.isNotEmpty) {
          await playlist.loadFromUrl(m3uUrl);
          if (!mounted) return;
          if (playlist.error != null) return;
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
        // Plain TextButton/FilledButton left which one has D-pad focus
        // ambiguous — same fix as everywhere else this was found (the
        // FilledButton's permanent solid fill looked selected regardless
        // of actual focus): ModeButton only fills solid on real focus.
        actions: [
          ModeButton(
            label: 'Choose Groups First',
            selected: false,
            onTap: () => Navigator.of(context).pop('choose'),
          ),
          ModeButton(label: 'Download All', selected: false, onTap: () => Navigator.of(context).pop('all')),
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

    // Was `unawaited(playlist.warmAllCategories())` — fired the download
    // invisibly in the background with no indication of progress or even
    // that anything was happening, confirmed directly as confusing
    // ("I don't know if I'll get a prompt when it's done... we don't have
    // the same *freeze* loading page"). Same blocking progress screen
    // "Update Content"/Clear Cache already use, so every path that
    // triggers a full catalog load behaves identically.
    if (!mounted) return;
    final warmFuture = playlist.warmAllCategories();
    final navigator = Navigator.of(context);
    unawaited(navigator.push(MaterialPageRoute(
      builder: (_) => Scaffold(backgroundColor: Colors.black, body: CatalogSyncBody(playlist: playlist)),
    )));
    await warmFuture;
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();

    return withTvThemeIfNeeded(context, (context) => SettingsScaffold(
      title: 'Add Playlist',
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
                const SizedBox(width: 12),
                Expanded(
                  child: ModeButton(
                    icon: Icons.auto_fix_high,
                    label: 'Smart Add',
                    selected: _mode == 'smart',
                    onTap: () => setState(() => _mode = 'smart'),
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
            ] else if (_mode == 'smart' && !_smartParsed) ...[
              // Stage 1: paste box. Deliberately doesn't try to guess a
              // name/activation-date the way this doesn't apply to us at
              // all — server/username/password are the only fields this
              // screen has, unlike iptv-manager's subscription tracker.
              Text(
                'Paste the message your provider sent you — we\'ll pull out '
                'the server, username, and password.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _smartPasteController,
                maxLines: 6,
                minLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Paste provider message',
                  hintText: 'username=...\npassword=...\nhttp://server.example.com/get.php?...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Parse'),
                onPressed: _handleSmartParse,
              ),
            ] else if (_mode == 'smart') ...[
              // Stage 2: review. Reuses the exact same server/username/
              // password controllers (and fields, below) the Xtream tab
              // has — Smart Add is just a different way to fill them in,
              // not a different destination for the data.
              Text('Confirm the server', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              if (_smartServerCandidates.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No server URL found in that text — enter it below.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                )
              else
                // A sloppy copy-paste (selecting across a line break, for
                // instance) can glue a stray character from an adjacent
                // line onto an otherwise-correct URL — requested directly:
                // offer every candidate found instead of silently
                // committing to the first, so a mangled one can be spotted
                // and a clean alternative picked instead. RadioGroup (not
                // each tile's own groupValue/onChanged, deprecated as of
                // this Flutter version) also gets D-pad Up/Down-between-
                // options and wraparound for free.
                RadioGroup<String>(
                  groupValue: _smartSelectedServer,
                  onChanged: (value) => setState(() {
                    _smartSelectedServer = value;
                    _xtreamServerController.text = value ?? '';
                  }),
                  child: Column(
                    children: _smartServerCandidates
                        .map((url) => RadioListTile<String>(
                              value: url,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(url, style: const TextStyle(fontFamily: 'monospace')),
                            ))
                        .toList(),
                  ),
                ),
              const SizedBox(height: 8),
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
              TextButton.icon(
                icon: const Icon(Icons.arrow_back),
                label: const Text('Paste different text'),
                onPressed: _resetSmartAdd,
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
                // The raw reason (bad credentials vs. an unreachable/timed-out
                // server vs. an inactive account all look different, e.g.
                // "Invalid Xtream username/password" vs. "Xtream request
                // failed... (HTTP 403)") — shown instead of a generic
                // "failed" message so a typo can actually be told apart from
                // a genuinely bad server without guessing.
                'Failed to add playlist: ${playlist.error!.replaceFirst('Exception: ', '')}',
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
