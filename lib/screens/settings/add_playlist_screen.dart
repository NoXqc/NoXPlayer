import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_profile.dart';
import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/constants.dart';
import '../../utils/smart_add_parser.dart';
import '../../utils/tv_theme.dart';
import '../../utils/xtream.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_menu_tile.dart';
import '../catalog_sync_screen.dart';
import 'group_management_screen.dart';

/// `TextField`/`EditableText` scrolls itself into view on focus for free —
/// plain buttons don't. Reported directly: once Smart Add's Stage 2 review
/// adds its extra "Paste different text" button, the form's total height
/// grows past the viewport and the "Add Playlist" button at the bottom
/// ends up half cut off with no way to bring it fully into view. Same
/// fix/pattern as `TvHomeScreen`'s own `_ensureVisible` helper.
void _ensureVisible(BuildContext context) {
  Scrollable.ensureVisible(context,
      duration: const Duration(milliseconds: 150), alignment: 0.5);
}

/// Playlist source configuration — M3U URL or Xtream Codes login — plus the
/// "download everything, or choose groups first?" choice for Xtream
/// accounts, which decides what the catalog warm-up (see [PlaylistManager])
/// actually fetches.
class AddPlaylistScreen extends StatefulWidget {
  const AddPlaylistScreen({super.key, this.editPlaylistId});

  /// Set when opened from `PlaylistManagerScreen`'s detail panel to edit
  /// an existing playlist's login details, instead of adding a new one —
  /// the whole reason this screen takes an *optional* id rather than being
  /// two separate screens: it's the exact same form either way, just
  /// prefilled from a `PlaylistProfile` instead of starting blank, and
  /// saving updates that profile in place instead of creating a new one.
  final String? editPlaylistId;

  @override
  State<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends State<AddPlaylistScreen> {
  late String _mode; // 'm3u', 'xtream', or 'smart' (a UI-only tab — see _save)
  late TextEditingController _nameController;
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
  final _nameFocus = FocusNode();
  final _m3uFocus = FocusNode();
  final _epgFocus = FocusNode();
  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  /// Focus nodes for the three mode rows in the left-hand "Playlist
  /// source" list — LokTV-style (requested directly): a vertical mode
  /// *list* in its own pane, reached via Left, rather than the old
  /// horizontal `ModeButton` row sitting inline above the fields. Also
  /// the Left-arrow pane-switch target (see [_currentModeListFocus]) and
  /// this screen's initial autofocus (see [initState]).
  final _modeM3uFocus = FocusNode();
  final _modeXtreamFocus = FocusNode();
  final _modeSmartFocus = FocusNode();

  FocusNode get _currentModeListFocus => switch (_mode) {
        'xtream' => _modeXtreamFocus,
        'smart' => _modeSmartFocus,
        _ => _modeM3uFocus,
      };

  /// Where Down/`onSubmitted` out of the Name field lands — the first
  /// field of whichever mode is currently selected. Smart Add has two
  /// different "firsts" depending on stage: the paste box before it's
  /// been parsed, the server field once it has (same fields the Xtream
  /// tab uses from then on).
  FocusNode get _firstModeFieldFocus => switch (_mode) {
        'm3u' => _m3uFocus,
        'smart' => _smartParsed ? _serverFocus : _smartPasteFocus,
        _ => _serverFocus,
      };

  /// Three independent `Left`/`Right`-switchable focus zones, left to
  /// right: mode list, fields, status/Add-Playlist — same
  /// `FocusScopeNode`-per-zone pattern `PlayerScreen`'s own top/bottom
  /// bars already use. Reported directly: an earlier version of this only
  /// had two zones (mode list, fields), leaving Right from inside the
  /// fields pane a no-op instead of reaching the status/button pane —
  /// that pane is still also reachable the old way too (Down escaping
  /// past the last tracked field), this just adds the direct route.
  final _modeScope = FocusScopeNode(debugLabel: 'add-playlist-modes');
  final _fieldsScope = FocusScopeNode(debugLabel: 'add-playlist-fields');
  final _statusScope = FocusScopeNode(debugLabel: 'add-playlist-status');

  /// Smart Add's paste box and Parse button — reported directly: with no
  /// `onSubmitted` wired here (unlike every other field on this screen),
  /// pressing the remote's Select button on the keyboard's own action key
  /// did nothing reliable, leaving the user stuck unable to reach "Add
  /// Playlist" at all. Only need a *forward* path here (paste box ->
  /// Parse), unlike the other fields' full escape mechanism below — this
  /// is the only text field on its stage, so there's no sibling to escape
  /// *between*, just one to escape *out of*.
  final _smartPasteFocus = FocusNode();
  final _parseButtonFocus = FocusNode();

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
    for (final node in _allTrackedFields) {
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

  /// The profile being edited, or null when adding a brand-new playlist —
  /// resolved once in [initState] rather than re-looked-up on every
  /// build, since `_save` needs the *original* profile's `sortOrder`/
  /// `createdAt` even after the user's edits change every other field.
  PlaylistProfile? _editingProfile;

  @override
  void initState() {
    super.initState();
    final editId = widget.editPlaylistId;
    PlaylistProfile? existing;
    if (editId != null) {
      for (final p in context.read<PlaylistManager>().profiles) {
        if (p.id == editId) {
          existing = p;
          break;
        }
      }
    }
    _editingProfile = existing;

    _mode = existing?.mode ?? 'm3u';
    _nameController = TextEditingController(text: existing?.name ?? '');
    _m3uController = TextEditingController(text: existing?.m3uUrl ?? '');
    // For an Xtream profile, epgUrl is usually just the auto-derived
    // xmltv.php link (see _save) rather than something the user actually
    // typed in — pre-filling this field with that would make a later
    // credential edit (server/username/password) silently keep the *old*
    // auto-derived URL instead of re-deriving it, since a non-empty field
    // here is taken as a deliberate override. Only genuinely-custom EPG
    // URLs (saved because they didn't match what today's credentials
    // would derive) get pre-filled.
    final existingAutoEpg = (existing != null && existing.mode == 'xtream')
        ? XtreamHelper.buildEpgUrl(
            server: existing.xtreamServer ?? '',
            username: existing.xtreamUsername ?? '',
            password: existing.xtreamPassword ?? '')
        : null;
    _epgController = TextEditingController(
        text: existing?.epgUrl == existingAutoEpg
            ? ''
            : (existing?.epgUrl ?? ''));
    _xtreamServerController =
        TextEditingController(text: existing?.xtreamServer ?? '');
    _xtreamUsernameController =
        TextEditingController(text: existing?.xtreamUsername ?? '');
    _xtreamPasswordController =
        TextEditingController(text: existing?.xtreamPassword ?? '');
    HardwareKeyboard.instance.addHandler(_handleFieldEscapeKey);
    for (final node in _allTrackedFields) {
      node.addListener(_trackTextFieldFocus);
    }
    // Lands on the mode list with the current mode highlighted — matches
    // LokTV's own default (its screenshot opens with Xtream already
    // focused in the left pane) rather than leaving initial focus to
    // Flutter's own scan across two now-separate FocusScopes, which has
    // no reason to prefer one over the other.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _currentModeListFocus.requestFocus());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleFieldEscapeKey);
    for (final node in _allTrackedFields) {
      node.removeListener(_trackTextFieldFocus);
    }
    _nameController.dispose();
    _m3uController.dispose();
    _epgController.dispose();
    _xtreamServerController.dispose();
    _xtreamUsernameController.dispose();
    _xtreamPasswordController.dispose();
    _smartPasteController.dispose();
    _nameFocus.dispose();
    _m3uFocus.dispose();
    _epgFocus.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _addButtonFocus.dispose();
    _smartPasteFocus.dispose();
    _parseButtonFocus.dispose();
    _modeM3uFocus.dispose();
    _modeXtreamFocus.dispose();
    _modeSmartFocus.dispose();
    _modeScope.dispose();
    _fieldsScope.dispose();
    _statusScope.dispose();
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

    // OK/Select on a field that already has focus. Flutter only raises the
    // on-screen keyboard when a field *gains* focus, so once the keyboard
    // has been dismissed there is otherwise no way back into the field
    // you're standing on — pressing OK does nothing, while arrowing to the
    // next field works, because that's a focus change. Reported from a
    // real remote: stuck unable to type a username, while password (one
    // press further down) accepted input fine.
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA) {
      final focused = FocusManager.instance.primaryFocus;
      if (_allTrackedFields.any((n) => n == focused)) {
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        return true;
      }
      return false;
    }

    if (event.logicalKey != LogicalKeyboardKey.arrowDown &&
        event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return false;
    }

    // The field actually being escaped — `current` when it's a tracked
    // field, otherwise the last one this handler saw focused (see
    // [_lastFocusedTextField]'s own doc comment for the real-hardware case
    // that fallback covers).
    final current = FocusManager.instance.primaryFocus;

    final effective =
        (current == _nameFocus || _allTrackedFields.contains(current))
            ? current
            : _lastFocusedTextField;

    // Name is folded in as the first entry below, not handled on its own
    // the way it used to be — that only existed because a whole
    // "Playlist source" `ModeButton` row used to sit between it and the
    // next tracked field, with no sibling relationship otherwise. Now
    // that mode selection lives in its own Left-reached pane (see this
    // class's own doc comment), Name is a genuine sibling of whichever
    // mode-specific field comes right after it, same as any other pair
    // in this list.
    //
    // Smart Add's stage 1 (the paste box) is the one real exception —
    // its own fields aren't part of this tracked-escape mechanism at all
    // (see `_smartPasteFocus`'s doc comment: forward-only via
    // `onSubmitted`, there's nothing to escape *between* on a single-field
    // stage), so Name is the *only* entry there; escaping down past it
    // goes to the paste box directly instead of by index below.
    final fields = switch (_mode) {
      'm3u' => [_nameFocus, _m3uFocus, _epgFocus],
      'smart' => _smartParsed
          ? [
              _nameFocus,
              _serverFocus,
              _usernameFocus,
              _passwordFocus,
              _epgFocus
            ]
          : [_nameFocus],
      _ => [
          _nameFocus,
          _serverFocus,
          _usernameFocus,
          _passwordFocus,
          _epgFocus
        ],
    };
    final index = fields.indexWhere((n) => n == effective);
    if (index < 0) return false;

    final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
    final next = index + delta;
    if (next < 0) {
      // Escaping UP past Name — genuinely the top of this pane now (the
      // mode list is a separate pane, reached via Left instead), so this
      // is a deliberate no-op rather than a jump anywhere. Still
      // consumed (not `return false`) so it doesn't fall through to
      // Flutter's own default traversal, which is exactly what this
      // whole mechanism exists to avoid trusting (see this method's own
      // doc comment).
      return true;
    }
    if (_mode == 'smart' && !_smartParsed && next >= fields.length) {
      // Only Name is tracked at stage 1 (see the comment above) —
      // escaping down from it goes to the paste box, not by index.
      _smartPasteFocus.requestFocus();
      return true;
    }
    if (next >= fields.length) {
      // Escaping DOWN past the last tracked field — same reasoning as
      // above, landing explicitly on Add Playlist instead of trusting
      // default traversal to find it. Reported directly: stuck unable to
      // reach Add Playlist at all once the keyboard was closed.
      _addButtonFocus.requestFocus();
      return true;
    }
    fields[next].requestFocus();
    _lastFocusedTextField = fields[next];
    return true;
  }

  /// Every text field this screen's escape mechanism tracks, across every
  /// mode — used by [_handleFieldEscapeKey] to tell "a tracked field lost
  /// bare focus but is still the logical last-known one" apart from "focus
  /// moved somewhere this handler has no opinion about".
  List<FocusNode> get _allTrackedFields => [
        _nameFocus,
        _m3uFocus,
        _epgFocus,
        _serverFocus,
        _usernameFocus,
        _passwordFocus
      ];

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
        const SnackBar(
            content: Text("Couldn't find anything usable in that text.")),
      );
      return;
    }
    setState(() {
      _smartServerCandidates = result.serverCandidates;
      _smartSelectedServer = result.serverCandidates.isNotEmpty
          ? result.serverCandidates.first
          : null;
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
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist name is required.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final mode = _effectiveMode;
      final isEditing = _editingProfile != null;
      // Fixed, identifiable, generated once and never reused for the
      // lifetime of this playlist — every per-playlist prefs key, cache
      // file, and catalog-database row this playlist owns is namespaced
      // by this same id (see Channel.playlistId's doc comment).
      final playlistId = _editingProfile?.id ??
          DateTime.now().microsecondsSinceEpoch.toString();

      if (!mounted) return;
      final playlist = context.read<PlaylistManager>();
      final epg = context.read<EpgService>();

      String epgUrl;
      PlaylistProfile profile;

      if (mode == 'xtream') {
        final server = _xtreamServerController.text.trim();
        final username = _xtreamUsernameController.text.trim();
        final password = _xtreamPasswordController.text.trim();

        if (server.isEmpty || username.isEmpty || password.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('Server, username, and password are all required.')),
          );
          return;
        }

        // Some panels disable the get.php/xmltv.php export shortcuts while
        // keeping the real Xtream API (player_api.php) active — so the
        // playlist itself always goes through the real API, not a derived
        // M3U URL. xmltv.php is still used for EPG since that endpoint is
        // commonly left enabled even when get.php isn't.
        //
        // A panel's own xmltv.php can also just be empty/unreliable even
        // when it responds — reported directly (Trex). The EPG field
        // (same one M3U mode always exposes) lets a third-party XMLTV
        // (e.g. EPGgenius) override the auto-derived link; blank means
        // "use the panel's own", so nothing changes for anyone who
        // doesn't touch it. It only fills in a channel's guide if that
        // feed's <channel id> matches this panel's own epg_channel_id.
        final customEpgUrl = _epgController.text.trim();
        epgUrl = customEpgUrl.isNotEmpty
            ? customEpgUrl
            : XtreamHelper.buildEpgUrl(
                server: server, username: username, password: password);
        profile = PlaylistProfile(
          id: playlistId,
          name: name,
          mode: 'xtream',
          xtreamServer: server,
          xtreamUsername: username,
          xtreamPassword: password,
          epgUrl: epgUrl,
          enabled: _editingProfile?.enabled ?? true,
          sortOrder: _editingProfile?.sortOrder ?? playlist.profiles.length,
          syncFrequencyDays: _editingProfile?.syncFrequencyDays ??
              AppConstants.defaultSyncFrequencyDays,
          createdAt: _editingProfile?.createdAt ?? DateTime.now(),
        );
      } else {
        final m3uUrl = _m3uController.text.trim();
        epgUrl = _epgController.text.trim();
        if (m3uUrl.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('M3U playlist URL is required.')),
          );
          return;
        }
        profile = PlaylistProfile(
          id: playlistId,
          name: name,
          mode: 'm3u',
          m3uUrl: m3uUrl,
          epgUrl: epgUrl,
          enabled: _editingProfile?.enabled ?? true,
          sortOrder: _editingProfile?.sortOrder ?? playlist.profiles.length,
          syncFrequencyDays: _editingProfile?.syncFrequencyDays ??
              AppConstants.defaultSyncFrequencyDays,
          createdAt: _editingProfile?.createdAt ?? DateTime.now(),
        );
      }

      if (isEditing) {
        await playlist.updatePlaylist(profile);
      } else {
        await playlist.addPlaylist(profile);
      }
      await playlist.loadPlaylist(playlistId);

      // A failed authenticate() (bad credentials, server down/blocked,
      // account expired) sets the session's error and returns normally
      // rather than throwing — so this must be checked explicitly.
      // `loadPlaylist` sets this playlist as the "foreground" session, so
      // `playlist.error` here reflects specifically this add/edit, not any
      // other playlist. Previously the success toast + pop-to-main-app
      // below ran unconditionally, meaning a genuine auth failure still
      // told the user "Playlist added" and dropped them on the empty-
      // catalog home screen with no indication anything went wrong —
      // confirmed directly against a backup server that was actually
      // rejecting the credentials.
      if (!mounted) return;
      if (playlist.error != null) {
        // A failed *new* add previously still left `addPlaylist`'s
        // just-created profile permanently saved — reported directly:
        // several genuinely-failed attempts (a provider's server being
        // down/blocking requests at the time) silently persisted anyway,
        // each as its own empty, unloaded playlist with no content and
        // no visible sign anything was added — "Failed to add playlist"
        // said nothing was added, but something was. Once the provider's
        // server came back, *all* of them finally connected on their own
        // and populated for real, producing several duplicate copies of
        // the same login with no way to tell which one had actually been
        // configured (hidden groups, etc.) and which were the orphaned
        // failures. Roll the profile back out here so a failed add
        // genuinely adds nothing, matching what the error message says.
        // Editing an *existing* playlist's login is deliberately left
        // alone on failure — that profile (and its real cached catalog,
        // hidden groups, favorites) predates this attempt and shouldn't
        // be destroyed just because a credential change didn't verify.
        if (!isEditing) await playlist.removePlaylist(playlistId);
        return;
      }

      if (!isEditing && mode == 'xtream') {
        await _promptDownloadScope(playlist, playlistId);
      }

      if (!mounted) return;
      if (epgUrl.isNotEmpty) {
        // Not awaited — reported directly as "confirm the groups, and it
        // just goes back to the URL/username/password screen instead of
        // the main app." Root cause: this was awaited, so a slow EPG
        // fetch (network-dependent, can take a while for a large XMLTV
        // file) blocked reaching the code below that pops back to the
        // main app — and if the fetch ever threw (a timeout, a malformed
        // response), it aborted the rest of this method silently, with
        // no error shown, leaving the form sitting there looking stuck.
        // The periodic app-wide EPG timer (see main.dart) already covers
        // this playlist going forward on its own; this is just the
        // immediate first-fetch so the guide isn't empty until that
        // timer's next tick.
        unawaited(epg.refresh(epgUrl,
            knownChannelIds: playlist.knownChannelIdsFor(playlistId)));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isEditing ? 'Playlist updated.' : 'Playlist added.')));
      if (isEditing) {
        // Back to PlaylistManagerScreen's detail panel, which is what
        // pushed this screen in edit mode — one level up, not all the way
        // to the app root (unlike a brand-new add, below).
        Navigator.of(context).pop();
      } else {
        // Land back on the main app instead of leaving the user sitting on
        // this form — reported directly: finishing the whole add-playlist
        // (and Group Management confirm) flow left them stuck back here,
        // still with a text field focused, instead of on the TV/Movies/
        // TV Shows tabs. `scaffoldMessengerKey` is app-wide (see main.dart),
        // so the snackbar above still shows after this pop.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Asks "download everything, or choose groups first?" — and, crucially,
  /// doesn't start the background catalog warm-up until this is settled,
  /// so a "choose groups" pick actually takes effect on what gets fetched
  /// instead of racing an already-running fetch-everything pass. Only
  /// asked for a brand-new Xtream playlist — editing an existing one's
  /// login already has its hidden-group choices saved from the first time
  /// around.
  Future<void> _promptDownloadScope(
      PlaylistManager playlist, String playlistId) async {
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
          ModeButton(
              label: 'Download All',
              selected: false,
              onTap: () => Navigator.of(context).pop('all')),
        ],
      ),
    );

    if (choice == 'choose' && mounted) {
      final finished = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
            builder: (_) => GroupManagementScreen(
                playlistId: playlistId, deferLoading: true)),
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

    // Was `unawaited(playlist.warmAllCategories(playlistId))` — fired the
    // download invisibly in the background with no indication of progress
    // or even that anything was happening, confirmed directly as
    // confusing ("I don't know if I'll get a prompt when it's done... we
    // don't have the same *freeze* loading page"). Same blocking progress
    // screen "Update Content"/Clear Cache already use, so every path that
    // triggers a full catalog load behaves identically — deliberately
    // still mandatory here for every playlist add, first or not (adding a
    // second/third playlist while others are already loaded must not let
    // the user wander off and start playback while this one's still
    // warming up, competing for memory in the background).
    if (!mounted) return;
    final warmFuture = playlist.warmAllCategories(playlistId);
    final navigator = Navigator.of(context);
    unawaited(navigator.push(MaterialPageRoute(
      builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: CatalogSyncBody(playlist: playlist)),
    )));
    await warmFuture;
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
            title: _editingProfile != null ? 'Edit Playlist' : 'Add Playlist',
            // Left/Right switch between the mode list and the fields —
            // same explicit-zone pattern `PlayerScreen`'s own top/bottom
            // bars use, not default traversal (see [_modeScope]/
            // [_fieldsScope]'s doc comment) — LokTV-style (requested
            // directly), replacing the old single scrollable column with
            // an inline horizontal mode row above the fields. Up/Down
            // *within* either pane is still plain default traversal
            // (simple single-type lists, the one case that's reliably
            // fine — see SettingsMenuScreen's own doc comment) plus the
            // text fields' own Next/Done + [_handleFieldEscapeKey]
            // wiring, both unchanged from before.
            //
            // Three columns now, not two: mode list (new, narrow, left),
            // the form fields (scrollable, middle), and the fixed
            // status/Add-Playlist panel (right) that never scrolls.
            // Reported directly, from before the mode list existed as
            // its own column: the "Connecting to server..."/error block
            // and the Add Playlist button itself could end up below the
            // fold with nothing making them visible again short of a
            // manual scroll (an auto-scroll-on-submit fix was tried and
            // rejected here — the ask was to not need one at all, not a
            // better-timed one). Pinning the status+button in their own
            // never-scrolling column means they're always on screen
            // regardless of which mode's fields — or how many Smart Add
            // server candidates — make the middle column tall.
            body: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                // Strict left-to-right cycle: modes -> fields -> status.
                // EditableText claims Left/Right for caret movement
                // whenever a text field has focus, so these only ever
                // actually fire while focus is on a mode row, a field's
                // own non-text-field sibling (e.g. the radio list, the
                // visibility toggle), or the status/Add-Playlist pane —
                // never mid-typing.
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
                  if (_statusScope.hasFocus) {
                    _nameFocus.requestFocus();
                  } else if (_fieldsScope.hasFocus) {
                    _currentModeListFocus.requestFocus();
                  }
                  // Already in the mode list — no-op, nothing further left.
                },
                const SingleActivator(LogicalKeyboardKey.arrowRight): () {
                  if (_modeScope.hasFocus) {
                    _nameFocus.requestFocus();
                  } else if (_fieldsScope.hasFocus) {
                    _addButtonFocus.requestFocus();
                  }
                  // Already in the status pane — no-op, nothing further right.
                },
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: FocusScope(
                      node: _modeScope,
                      child: ListView(
                        padding: const EdgeInsets.all(8),
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: SectionLabel('Playlist source'),
                          ),
                          const SizedBox(height: 4),
                          TvMenuTile(
                            focusNode: _modeM3uFocus,
                            icon: Icons.link,
                            title: 'M3U URL',
                            trailing: _mode == 'm3u'
                                ? Icon(Icons.check,
                                    color:
                                        Theme.of(context).colorScheme.primary)
                                : const SizedBox.shrink(),
                            onTap: () => setState(() => _mode = 'm3u'),
                          ),
                          TvMenuTile(
                            focusNode: _modeXtreamFocus,
                            icon: Icons.dns,
                            title: 'Xtream Codes',
                            trailing: _mode == 'xtream'
                                ? Icon(Icons.check,
                                    color:
                                        Theme.of(context).colorScheme.primary)
                                : const SizedBox.shrink(),
                            onTap: () => setState(() => _mode = 'xtream'),
                          ),
                          TvMenuTile(
                            focusNode: _modeSmartFocus,
                            icon: Icons.auto_fix_high,
                            title: 'Smart Add',
                            trailing: _mode == 'smart'
                                ? Icon(Icons.check,
                                    color:
                                        Theme.of(context).colorScheme.primary)
                                : const SizedBox.shrink(),
                            onTap: () => setState(() => _mode = 'smart'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FocusScope(
                      node: _fieldsScope,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          const SectionLabel('Playlist name'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _nameController,
                            focusNode: _nameFocus,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              hintText: 'e.g. My Provider, or 8kStrong',
                              border: OutlineInputBorder(),
                            ),
                            textInputAction: TextInputAction.next,
                            // Goes to the first field *of the current
                            // mode* now, not a mode row that used to sit
                            // right below it — [_firstModeFieldFocus]'s
                            // doc comment has the per-mode mapping
                            // (including Smart Add's two stages).
                            onSubmitted: (_) =>
                                _firstModeFieldFocus.requestFocus(),
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
                              onSubmitted: (_) =>
                                  _addButtonFocus.requestFocus(),
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
                              focusNode: _smartPasteFocus,
                              maxLines: 6,
                              minLines: 3,
                              decoration: const InputDecoration(
                                labelText: 'Paste provider message',
                                hintText:
                                    'username=...\npassword=...\nhttp://server.example.com/get.php?...',
                                alignLabelWithHint: true,
                                border: OutlineInputBorder(),
                              ),
                              // A paste (the normal way this field gets filled, via the
                              // Fire Stick's QR-code-to-phone-keyboard relay) inserts the
                              // whole multi-line block directly — it doesn't need the
                              // IME's own return key to type newlines one at a time, so
                              // claiming that key for a real "next field" action instead
                              // costs nothing real.
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) =>
                                  _parseButtonFocus.requestFocus(),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              focusNode: _parseButtonFocus,
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text('Parse'),
                              onPressed: _handleSmartParse,
                              onFocusChange: (f) {
                                if (f) _ensureVisible(context);
                              },
                            ),
                          ] else if (_mode == 'smart') ...[
                            // Stage 2: review. Reuses the exact same server/username/
                            // password controllers (and fields, below) the Xtream tab
                            // has — Smart Add is just a different way to fill them in,
                            // not a different destination for the data.
                            Text('Confirm the server',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            if (_smartServerCandidates.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'No server URL found in that text — enter it below.',
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error),
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
                                            title: Text(url,
                                                style: const TextStyle(
                                                    fontFamily: 'monospace')),
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
                                  icon: Icon(_obscurePassword
                                      ? Icons.visibility
                                      : Icons.visibility_off),
                                  onPressed: () => setState(() =>
                                      _obscurePassword = !_obscurePassword),
                                ),
                              ),
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) => _epgFocus.requestFocus(),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _epgController,
                              focusNode: _epgFocus,
                              decoration: const InputDecoration(
                                labelText: 'Custom EPG (XMLTV) URL — optional',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) =>
                                  _addButtonFocus.requestFocus(),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Leave blank to use the panel\'s own xmltv.php. Set this '
                              'if your provider\'s EPG is empty or unreliable (e.g. a '
                              'third-party feed like EPGgenius) — it only fills in a '
                              'channel if that feed\'s ids match this panel\'s.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('Paste different text'),
                              onPressed: _resetSmartAdd,
                              onFocusChange: (f) {
                                if (f) _ensureVisible(context);
                              },
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
                                  icon: Icon(_obscurePassword
                                      ? Icons.visibility
                                      : Icons.visibility_off),
                                  onPressed: () => setState(() =>
                                      _obscurePassword = !_obscurePassword),
                                ),
                              ),
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) => _epgFocus.requestFocus(),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _epgController,
                              focusNode: _epgFocus,
                              decoration: const InputDecoration(
                                labelText: 'Custom EPG (XMLTV) URL — optional',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) =>
                                  _addButtonFocus.requestFocus(),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Leave blank to use the panel\'s own xmltv.php. Set this '
                              'if your provider\'s EPG is empty or unreliable (e.g. a '
                              'third-party feed like EPGgenius) — it only fills in a '
                              'channel if that feed\'s ids match this panel\'s.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Fixed width, not Expanded/flex — a status panel and one
                  // button don't need to grow with a wide TV screen the way
                  // the form column benefits from the extra room.
                  SizedBox(
                    width: 320,
                    child: FocusScope(
                      node: _statusScope,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SectionLabel('Status'),
                          const SizedBox(height: 8),
                          // A colored accent bar + bold text when something's
                          // actually happening (connecting or failed) instead
                          // of the same flat panel style regardless of state
                          // — reported directly as easy to miss entirely
                          // during a fast connection/failure, since nothing
                          // about the panel itself drew the eye there over
                          // the form on the left.
                          // Reported directly, live, across two earlier
                          // attempts: a visible idle bubble here read as
                          // hiding the real connecting/failed status (fixed
                          // by removing its content/color/border below), but
                          // removing it *entirely* — collapsing this box to
                          // zero height at rest — made the Add Playlist
                          // button move up to sit right under "Status" while
                          // idle, then jump back down the instant a real
                          // status appeared, reported directly as "the
                          // status is under [the button] now". Reserving
                          // this fixed height *always*, regardless of state,
                          // is what actually fixes both reports at once: the
                          // button/hint below never move, and there's
                          // nothing painted here at rest to hide anything
                          // behind.
                          ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 56),
                            child: Builder(builder: (context) {
                              final error = playlist.error;
                              Color? accent;
                              Widget content = const SizedBox.shrink();
                              if (playlist.isLoading) {
                                accent = Theme.of(context).colorScheme.primary;
                                content = Row(
                                  children: [
                                    SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: accent),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        playlist.loadingPhase ?? 'Loading...',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                );
                              } else if (error != null) {
                                accent = Theme.of(context).colorScheme.error;
                                content = Text(
                                  // The raw reason (bad credentials vs. an
                                  // unreachable/timed-out server vs. an
                                  // inactive account all look different, e.g.
                                  // "Invalid Xtream username/password" vs.
                                  // "Xtream request failed... (HTTP 403)") —
                                  // shown instead of a generic "failed" message
                                  // so a typo can actually be told apart from a
                                  // genuinely bad server without guessing.
                                  'Failed to add playlist: ${error.replaceFirst('Exception: ', '')}',
                                  style: TextStyle(
                                      color: accent,
                                      fontWeight: FontWeight.bold),
                                );
                              }
                              // Idle: no fill, no border, no text — just the
                              // reserved height above, so there's genuinely
                              // nothing painted here to compete with or hide
                              // a real status.
                              return Container(
                                decoration: accent == null
                                    ? null
                                    : BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.07),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border(
                                            left: BorderSide(
                                                color: accent, width: 4)),
                                      ),
                                padding: const EdgeInsets.all(16),
                                child: content,
                              );
                            }),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            focusNode: _addButtonFocus,
                            onPressed:
                                (playlist.isLoading || _saving) ? null : _save,
                            child: Text(_editingProfile != null
                                ? 'Save Changes'
                                : 'Add Playlist'),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Fill in the form on the left, then press '
                            '${_editingProfile != null ? 'Save Changes' : 'Add Playlist'} above.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            )));
  }
}
