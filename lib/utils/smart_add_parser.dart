/// Parses the messy text an IPTV reseller sends a customer (a "welcome"
/// message, order confirmation, etc.) into a server/username/password —
/// the "Smart Add" tab on [AddPlaylistScreen]. Ported from the same
/// regex-based approach already proven out in the standalone iptv-manager
/// project (github.com/NoXqc — see its `www/app.js`), adapted for this
/// app's single-server Xtream form (no separate "backup servers" concept
/// here, so every URL found collapses down to a deduped list of server
/// *origins* the user picks from, rather than kept as distinct
/// url/server/backup fields).
library;

/// Every abbreviation actually confirmed in a real provider message this
/// session ("UN:", "psw:") plus their obvious neighbors — kept as their
/// own constants (rather than folded straight into [_labelWords]) so the
/// username/password extraction regexes below can reuse the exact same
/// alternation instead of drifting out of sync with it over time.
const _usernameLabels = 'username|user|login|un';
const _passwordLabels = 'password|pass|pwd|psw|pw';

/// Field labels this parser recognizes when scanning pasted provider text.
/// Used to split fields apart when a provider's message has zero
/// whitespace between them (e.g. "38827a0e8cf2Password:f8504889f9").
const _labelWords =
    '$_usernameLabels|$_passwordLabels|url|dns|server|domain|type|exp|expiry|backup|m3u';

/// Descriptor words that sometimes get glued directly onto a credential
/// with no separator (e.g. "f8504889f9SmartTV") — stops a value capture
/// early so it doesn't swallow the descriptor as part of the credential.
const _descriptorStopWords = r'smarttv|smarters|xtream|enigma|\bmag\b|m3u8?';

class SmartAddResult {
  const SmartAddResult(
      {required this.serverCandidates,
      required this.username,
      required this.password});

  /// Every distinct server origin (`scheme://host[:port]`) found in the
  /// pasted text, in best-guess-first order (a real Xtream/M3U stream URL
  /// outranks a bare domain, since it's less likely to be a typo/red
  /// herring elsewhere in the message) — shown to the user to pick from
  /// rather than silently committing to the first one, since a sloppy
  /// copy-paste can glue a stray character from an adjacent line onto an
  /// otherwise-correct URL.
  final List<String> serverCandidates;
  final String username;
  final String password;

  bool get isEmpty =>
      serverCandidates.isEmpty && username.isEmpty && password.isEmpty;
}

String _stripTrailingPunctuation(String s) =>
    s.replaceFirst(RegExp(r'''[),.;:'"]+$'''), '');

String _normalizeProviderText(String raw) {
  var text = raw.replaceAll('：', ':').replaceAll('＝', '=');
  // Split URLs glued directly onto preceding text with no separator
  // (e.g. "...comM3U:http://..." or "...comhttp://...").
  text = text.replaceAllMapped(
    RegExp(r'([^\s])(https?://)', caseSensitive: false),
    (m) => '${m[1]} ${m[2]}',
  );
  // Split known field labels glued directly onto preceding text
  // (e.g. "38827a0e8cf2Password:f8504889f9"). Excludes '?'/'&' so this
  // never touches a URL's own query string (e.g. "&type=m3u_plus").
  final labelRe =
      RegExp('([^\\s?&])(?=(?:$_labelWords)\\s*[:=])', caseSensitive: false);
  text = text.replaceAllMapped(labelRe, (m) => '${m[1]} ');
  return text;
}

bool _isStreamUrl(String u) {
  if (RegExp(r'[?&](username|user)=', caseSensitive: false).hasMatch(u))
    return true;
  if (RegExp(r'get\.php|player_api\.php|panel_api\.php|xmltv\.php',
          caseSensitive: false)
      .hasMatch(u)) {
    return true;
  }
  return false;
}

String? _originOf(String url) {
  try {
    final parsed = Uri.parse(url);
    if (!parsed.hasScheme || parsed.host.isEmpty) return null;
    return parsed.origin;
  } catch (_) {
    return null;
  }
}

SmartAddResult parseSmartAddText(String raw) {
  final text = _normalizeProviderText(raw);

  final urlRegex = RegExp(r'''https?://[^\s"'<>]+''', caseSensitive: false);
  final foundUrls = urlRegex
      .allMatches(text)
      .map((m) => _stripTrailingPunctuation(m.group(0)!));
  final urls = foundUrls.toSet().toList(); // dedupe, preserve first-seen order

  var username = '';
  var password = '';
  const stopLookahead = '(?=\\s|&|\$|$_descriptorStopWords)';
  // The separator between a label and its value is an explicit `:`/`=`/`-`
  // (same line, e.g. "username: bf268dcdc0", "Username - bf268dcdc0") OR a
  // bare newline with no punctuation at all — confirmed as a real, common
  // provider format (a panel's own "USERNAME" section header directly
  // above the value, copied as plain text keeps that layout). A single
  // plain space with none of the above is deliberately NOT accepted as a
  // separator, or "enter your username here" would grab "here" — that
  // risk gets worse, not better, now that short abbreviations like "un"/
  // "pw" are recognized labels too.
  const labelSeparator = '(?:\\s*[:=-]\\s*|\\s*\\n\\s*)';
  final userMatch = RegExp(
    '\\b(?:$_usernameLabels)\\b$labelSeparator([^\\s&]+?)$stopLookahead',
    caseSensitive: false,
  ).firstMatch(text);
  if (userMatch != null)
    username = _stripTrailingPunctuation(userMatch.group(1)!);
  final passMatch = RegExp(
    '\\b(?:$_passwordLabels)\\b$labelSeparator([^\\s&]+?)$stopLookahead',
    caseSensitive: false,
  ).firstMatch(text);
  if (passMatch != null)
    password = _stripTrailingPunctuation(passMatch.group(1)!);

  final streamUrls = urls.where(_isStreamUrl).toList();
  final plainUrls = urls.where((u) => !_isStreamUrl(u)).toList();

  // A stream URL's own query params are a more reliable source than the
  // label-based scan above for a provider that never actually labels the
  // fields in prose, just hands over a single get.php-style link.
  if (streamUrls.isNotEmpty) {
    final parsed = Uri.tryParse(streamUrls.first);
    if (parsed != null) {
      final qUser =
          parsed.queryParameters['username'] ?? parsed.queryParameters['user'];
      final qPass =
          parsed.queryParameters['password'] ?? parsed.queryParameters['pass'];
      if (username.isEmpty && qUser != null) username = qUser;
      if (password.isEmpty && qPass != null) password = qPass;
    }
  }

  final origins = <String>[];
  for (final u in [...streamUrls, ...plainUrls]) {
    final origin = _originOf(u);
    if (origin != null && !origins.contains(origin)) origins.add(origin);
  }

  return SmartAddResult(
      serverCandidates: origins, username: username, password: password);
}
