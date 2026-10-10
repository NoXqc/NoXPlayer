import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../widgets/settings_scaffold.dart';

/// Where a user supplies their own free TMDB (The Movie Database) API
/// key — see `TmdbEnrichmentService`'s doc comment for why this can't
/// just be a key baked into the app itself. Off by default: nothing here
/// is required for the app to work, it only unlocks the "TMDB" sort
/// option on a group's "Expand catalog" screen, and sharpens "What's New"
/// (see `PlaylistManager.refreshWhatsNewTmdbIfDue`) once one's been set.
class TmdbSettingsScreen extends StatefulWidget {
  const TmdbSettingsScreen({super.key});

  @override
  State<TmdbSettingsScreen> createState() => _TmdbSettingsScreenState();
}

class _TmdbSettingsScreenState extends State<TmdbSettingsScreen> {
  late final TextEditingController _controller;
  bool _validating = false;
  bool _refreshing = false;

  final _apiKeyFocus = FocusNode();
  final _saveFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: context.read<StorageService>().getTmdbApiKey() ?? '');
    HardwareKeyboard.instance.addHandler(_handleApiKeyFieldEscapeKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleApiKeyFieldEscapeKey);
    _apiKeyFocus.dispose();
    _saveFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Same root cause/fix as `_AddProfileScreenState
  /// ._handleNameFieldEscapeKey` (see that method's own, fuller doc
  /// comment): `EditableText` claims arrow keys for itself whenever a
  /// text field has focus, regardless of direction, so plain default
  /// Down traversal never actually escapes this screen's API key field
  /// at all — reported directly as "can't reach [Refresh/Save] with
  /// D-pad", the same symptom that fix already covered elsewhere. This
  /// explicit `HardwareKeyboard` handler is the only reliable way out of
  /// a focused text field on real remote hardware.
  bool _handleApiKeyFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) return false;
    if (FocusManager.instance.primaryFocus != _apiKeyFocus) return false;
    _saveFocus.requestFocus();
    return true;
  }

  /// Saves immediately (so a key is never lost just because the
  /// validation check below fails/times out), then separately checks it
  /// against TMDB's own `/authentication` endpoint — the one endpoint
  /// TMDB provides specifically to answer "is this key good", at zero
  /// cost toward anything else. "Saved" alone said nothing about whether
  /// the key actually works, which is the thing someone pasting in a long
  /// string actually wants to know.
  Future<void> _save() async {
    final key = _controller.text.trim();
    await context.read<StorageService>().setTmdbApiKey(key);
    if (!mounted) return;
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cleared — TMDB sorting is now off')));
      return;
    }
    setState(() => _validating = true);
    final valid = await _checkKey(key);
    if (!mounted) return;
    setState(() => _validating = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(valid
          ? 'Saved — key verified with TMDB ✓'
          : 'Saved, but TMDB rejected this key — double-check it\'s correct'),
      backgroundColor: valid ? null : Colors.red.shade900,
    ));
  }

  /// Bypasses the normal once-a-week gate — see
  /// `PlaylistManager.refreshWhatsNewTmdbIfDue`'s own doc comment for why
  /// that gate exists and why a manual override is needed at all: its
  /// persisted "last run" timestamp survives an app *update*, not just a
  /// restart, so anyone whose weekly window already started under an
  /// older, narrower version of that lookup would otherwise see no
  /// change for up to another 7 days with nothing to explain why.
  Future<void> _refreshWhatsNew() async {
    setState(() => _refreshing = true);
    await context.read<PlaylistManager>().refreshWhatsNewTmdbIfDue(force: true);
    if (!mounted) return;
    setState(() => _refreshing = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('What\'s New refreshed from TMDB')));
  }

  Future<bool> _checkKey(String key) async {
    try {
      final uri =
          Uri.parse('https://api.themoviedb.org/3/authentication?api_key=$key');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['success'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'TMDB (Release Dates)',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'TMDB (The Movie Database) is a free, independent movie and TV '
            'database — not your IPTV provider. Adding your own free TMDB '
            'key lets VesperTV look up a title\'s actual real-world '
            'release date, which powers two things: a "TMDB" sort option '
            'on any group\'s "Expand catalog" screen, and a more accurate '
            '"What\'s New" row (ordered by real release date instead of '
            'just when your provider added the title).',
          ),
          const SizedBox(height: 12),
          const Text(
            'This is completely optional and free — VesperTV works '
            '100% without it. Without a key, sorting just falls back to '
            'whenever your provider added or updated each title, which is '
            'still available and works fine on its own.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text(
            'To get one: create a free account at themoviedb.org, then '
            'generate an API key under Settings > API (choose "Personal '
            'use" when asked) and paste it below. VesperTV never collects '
            'or shares it — it\'s stored only on this device.',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            focusNode: _apiKeyFocus,
            // Submitting straight from the on-screen keyboard's own
            // Done/Enter key — reachable without ever leaving the
            // keyboard — rather than requiring a D-pad trip down to the
            // Save button below. On Fire TV that trip is genuinely hard:
            // the on-screen keyboard overlay owns D-pad input while a
            // text field has focus (see CLAUDE.md's "Fire OS's on-screen
            // keyboard swallows the physical Back button" note — same
            // overlay, same root cause), so reported directly as "very
            // hard to reach" on Fire Stick but not Formuler, which has no
            // such overlay.
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'TMDB API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // OutlinedButton, not FilledButton: `_tvButtonStyle` only sets a
          // background on focus and leaves it `null` (falls back to the
          // button type's own default) otherwise. FilledButton's own
          // Material3 default background already IS `scheme.primary` —
          // identical to the focused fill — so focus was reported
          // directly as "barely visible on a white button": nothing
          // actually changes when focus arrives. OutlinedButton's default
          // is transparent, so the same focused fill reads as the obvious
          // solid highlight every other button in this app already has.
          OutlinedButton(
            focusNode: _saveFocus,
            onPressed: _validating ? null : _save,
            child: _validating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
          if (context.watch<StorageService>().getTmdbApiKey()?.isNotEmpty ??
              false) ...[
            const SizedBox(height: 16),
            const Text(
                'What\'s New only re-checks TMDB about once a week on its '
                'own. Use this to force it right now instead of waiting — '
                'useful right after saving a key for the first time.',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _refreshing ? null : _refreshWhatsNew,
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: const Text('Refresh What\'s New Now'),
            ),
          ],
          const SizedBox(height: 24),
          // TMDB's own terms require this attribution wherever their API
          // is actually used — not optional/cosmetic.
          const Text(
            'This product uses the TMDB API but is not endorsed or '
            'certified by TMDB.',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
