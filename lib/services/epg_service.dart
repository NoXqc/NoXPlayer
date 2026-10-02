import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml_events.dart';

import '../models/epg_program.dart';
import '../utils/constants.dart';
import 'storage_service.dart';

/// One playlist's EPG URL plus the channel ids it's allowed to populate
/// programmes for — see [EpgService.refresh]'s doc comment.
typedef EpgSource = ({String url, Set<String> knownChannelIds});

/// Every EPG channel id this service touches — a feed's own `<channel id>`,
/// a provider's `epg_channel_id`, a manual override, an M3U `tvg-id` — is
/// normalized through this before it's ever used as a map key or compared.
/// Two real providers were confirmed to disagree on casing for the exact
/// same channel (`espn.us` vs `ESPN.us`) despite XMLTV ids conventionally
/// being case-insensitive identifiers in practice; a plain exact-string
/// map lookup silently failed on that alone, with no error to show for
/// it — indistinguishable from "the feed just doesn't have this channel".
String normalizeEpgId(String id) => id.trim().toLowerCase();

/// Top-level (isolate-safe) so [compute] can run them off the main
/// isolate — a full-catalog EPG cache is easily tens of thousands of
/// programmes, and decoding/encoding that much JSON synchronously on the
/// UI isolate was blocking every single app start (cold launch, and any
/// resume after Android killed the backgrounded process) for a
/// noticeable, janky stretch.
/// Isolate entry point: reads the EPG cache straight from disk so the file
/// read and UTF-8 decode happen off the main thread too.
///
/// Streams the file through the decoder rather than `readAsStringSync()` +
/// `jsonDecode()` on the whole thing — the same class of problem as
/// [_writeEpgCacheFile]'s doc comment describes for the write side: the
/// old approach meant the full raw JSON text and the full decoded object
/// tree were both resident at once, and this read happens unconditionally
/// on *every* cold start (not just a manual "Update EPG Now"), so a stale,
/// pre-fix cache file left over from before this change could still hit
/// the same low-memory kill on launch alone. `Stream<String>.transform`ing
/// through `JsonDecoder` consumes the text incrementally as it's decoded
/// instead of needing it all pre-loaded.
Future<Map<String, List<EpgProgram>>> _readEpgCacheFile(String path) async {
  final decoded = await File(path)
      .openRead()
      .transform(const Utf8Decoder())
      .transform(const JsonDecoder())
      .single as Map<String, dynamic>;
  return _decodeEpgCache(decoded);
}

Map<String, List<EpgProgram>> _decodeEpgCache(Map<String, dynamic> decoded) {
  final result = <String, List<EpgProgram>>{};
  decoded.forEach((channelId, list) {
    result[channelId] = (list as List)
        .map((e) => EpgProgram.fromJson(e as Map<String, dynamic>))
        .toList();
  });
  return result;
}

/// Isolate entry point for [EpgService._persistCache] — writes straight to
/// disk one channel's programme list at a time instead of building one
/// `jsonEncode` `String` for the *entire* combined cache first. Confirmed
/// on real hardware (Fire Stick) as a real OOM cause: a full-catalog EPG
/// cache is tens of MB, and the old approach meant a full copy of every
/// [EpgProgram] object *plus* the complete JSON `String` *plus* its
/// UTF-8-encoded byte buffer were all alive simultaneously at the exact
/// moment the app's own working set was already at its peak from parsing —
/// confirmed by a live memory trace showing the crash landing right after
/// "update complete", during this exact step. Streaming keeps only one
/// channel's small JSON fragment in memory at a time.
Future<void> _writeEpgCacheFile(
    ({Map<String, List<EpgProgram>> programs, String path}) args) async {
  final sink = File(args.path).openWrite();
  sink.write('{');
  var first = true;
  for (final entry in args.programs.entries) {
    if (!first) sink.write(',');
    first = false;
    sink.write(jsonEncode(entry.key));
    sink.write(':');
    sink.write(jsonEncode(entry.value.map((p) => p.toJson()).toList()));
  }
  sink.write('}');
  await sink.flush();
  await sink.close();
}

/// Fetches, parses, caches, and serves XMLTV EPG data.
///
/// Programmes are cached to [StorageService] as JSON so the guide has
/// something to show immediately on launch, before the first network
/// refresh completes.
class EpgService extends ChangeNotifier {
  EpgService(this._storage);

  final StorageService _storage;

  final Map<String, List<EpgProgram>> _programs = {};

  /// Every URL's own most recently parsed set of channel ids — lets
  /// [_refreshOne] clear only the ids *that exact URL* actually produced
  /// last time, instead of every id the owning playlist happens to know
  /// about (which used to include a channel's manually-assigned
  /// [Channel.epgIdOverride] even when that id actually belongs to a
  /// *different* playlist's own EPG source). Reported directly: assigning
  /// Trex's channel to a candidate id from a different, already-loaded
  /// feed worked at first (that id's cached programme data was already
  /// there from the other feed's own refresh), then silently emptied out
  /// the next time Trex's own source refreshed — its filter now included
  /// that id (an override is still part of "my known ids" for parse-time
  /// filtering, which is correct), so the stale-removal step deleted it
  /// before Trex's own feed's parse, which never defined that id at all,
  /// could put anything back. Scoping removal to what the URL itself last
  /// contributed means a source only ever clears its *own* prior
  /// contribution, never another source's. Not persisted to disk — same
  /// "rebuilt fresh each launch" tradeoff as [_channelCatalog]: the first
  /// refresh of a URL each session skips stale-removal entirely (nothing
  /// recorded yet), so a channel genuinely dropped from a feed keeps
  /// showing its last cached programme data until that URL's second
  /// refresh this session, rather than risking any correctness issue.
  final Map<String, Set<String>> _idsByUrl = {};

  /// Every `<channel id>` -> its first `<display-name>` this session has
  /// seen, across every source refreshed so far — *not* scoped to any one
  /// playlist's [EpgSource.knownChannelIds] the way [_programs] itself is
  /// (see [refresh]'s doc comment): the whole point is letting "Assign
  /// EPG channel" browse the *feed's* full channel directory to search
  /// for a match, independent of which ids a given playlist happens to
  /// already own. Small either way (a few thousand short strings, not
  /// full programme data) so keeping every source's entries around at
  /// once costs nothing worth guarding. Rebuilt fresh each app launch
  /// (not cached to disk like [_programs] is) — acceptable for now since
  /// "Update EPG Now" is right there in the same settings screen that
  /// would use this.
  final Map<String, String> _channelCatalog = {};
  Map<String, String> get channelCatalog => Map.unmodifiable(_channelCatalog);

  /// Every `<channel id>`'s own currently-airing programme, as of
  /// whenever it was last refreshed — lets "Assign EPG channel" show what
  /// a *candidate* id is airing right now (e.g. telling `espn.us` apart
  /// from `espn2.us`/`espnu.us` by matching it against what the real
  /// channel is actually showing), not just its display name. Reported
  /// directly: several plausible-looking candidates for the same channel,
  /// no way to tell which one is actually right without trial and error.
  /// Same unfiltered-by-[EpgSource.knownChannelIds] reasoning as
  /// [_channelCatalog] — see [_parseXmltvStream]'s doc comment.
  final Map<String, EpgProgram> _nowPlayingCatalog = {};
  EpgProgram? currentProgramInCatalog(String id) =>
      _nowPlayingCatalog[normalizeEpgId(id)];

  DateTime? lastUpdated;
  bool isLoading = false;
  String? error;

  Timer? _refreshTimer;

  /// Evaluated fresh on every auto-refresh tick (not a frozen snapshot
  /// taken once at `startAutoRefresh` time) — playlists can be
  /// added/removed/enabled/disabled while the timer is running, and the
  /// next tick should reflect whichever playlists are enabled *then*, not
  /// whatever was true when the timer was first started.
  List<EpgSource> Function()? _sourcesProvider;

  Future<void> init() async {
    lastUpdated = _storage.getEpgLastUpdated();
    // Path, not contents — see StorageService.cacheFilePath. The EPG
    // cache (every programme for every channel) is one of the two largest
    // files this app reads at startup.
    final cachedPath =
        await _storage.cacheFilePath(AppConstants.cacheFileEpgPrograms);
    if (cachedPath != null) {
      try {
        final decoded = await compute(_readEpgCacheFile, cachedPath);
        _programs
          ..clear()
          ..addAll(decoded);
      } catch (_) {
        // Corrupt/old cache format — ignore, it will be repopulated on the
        // next successful refresh.
      }
    }
    notifyListeners();
  }

  /// (Re)starts the periodic auto-refresh timer, refreshing every source
  /// [sourcesProvider] returns (one per enabled playlist with a non-empty
  /// EPG URL — see [EpgSource]) each tick. Call again whenever the
  /// interval changes. Safe to call unconditionally; a tick with no
  /// sources just no-ops.
  void startAutoRefresh(
      int minutes, List<EpgSource> Function() sourcesProvider) {
    _refreshTimer?.cancel();
    _sourcesProvider = sourcesProvider;
    _refreshTimer =
        Timer.periodic(Duration(minutes: minutes), (_) => refreshAll());
  }

  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Refreshes every source [_sourcesProvider] currently returns, one at a
  /// time (each call to [refresh] below only ever replaces *that* source's
  /// own channels' programmes — see its doc comment — so there's no
  /// correctness reason these need to run concurrently, and running them
  /// one at a time keeps `isLoading`/`error` meaningful for whichever one
  /// is actually in flight).
  /// Refreshes every source, persisting the combined cache to disk exactly
  /// once at the end — not once per source. Each individual source's data
  /// can be tens of MB once parsed (a real 8kStrong feed: 3,080 channels,
  /// ~216,000 programmes), and [_persistCache] re-encodes the *entire*
  /// combined `_programs` map from scratch every time it runs. Calling it
  /// after every single source in a multi-playlist setup meant a 3-4
  /// playlist refresh cycle re-serialized the whole, ever-growing dataset
  /// 3-4 times over — full JSON string plus full object graph alive at
  /// once in the compute isolate, repeatedly, for no benefit over doing it
  /// once at the end.
  Future<void> refreshAll() async {
    final sources = _sourcesProvider?.call() ?? const [];
    isLoading = true;
    notifyListeners();
    try {
      for (final source in sources) {
        await _refreshOne(source.url, knownChannelIds: source.knownChannelIds);
      }
      await _persistCache();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Refreshes one EPG source and immediately persists the result — the
  /// entry point for every *single*-playlist caller (adding a playlist,
  /// "Update EPG Now" on one playlist). [refreshAll] above uses
  /// [_refreshOne] directly instead, so a multi-playlist refresh persists
  /// once at the end rather than once per source.
  ///
  /// [isLoading] spans the persist step too, not just [_refreshOne] — that
  /// used to flip back to false the moment parsing finished, so the UI
  /// reported "done" while the (heaviest) disk-write step was still
  /// actively running in the background. Confirmed on real hardware as
  /// genuinely misleading: a low-memory kill landed *after* the on-screen
  /// "EPG update completed" moment, during exactly that still-running
  /// write.
  Future<void> refresh(String url,
      {required Set<String> knownChannelIds}) async {
    isLoading = true;
    notifyListeners();
    try {
      await _refreshOne(url, knownChannelIds: knownChannelIds);
      await _persistCache();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _persistCache() async {
    final path = await _storage
        .cacheFilePathForWrite(AppConstants.cacheFileEpgPrograms);
    await compute(_writeEpgCacheFile, (programs: _programs, path: path));
    await _storage.setEpgLastUpdated(lastUpdated ?? DateTime.now());
  }

  /// Refreshes one EPG source's data into [_programs]/[_channelCatalog]/
  /// [_nowPlayingCatalog] without persisting anything to disk — see
  /// [refresh] and [refreshAll] for the two callers that each handle
  /// persistence at the point that actually makes sense for them.
  /// [knownChannelIds] scopes both the parse filter (see
  /// [_parseXmltvStream]'s doc comment) *and* which existing entries in
  /// [_programs] get replaced — a shared multi-provider EPG source can
  /// cover vastly more channels than one playlist actually has, and
  /// refreshing one playlist's source must never wipe another playlist's
  /// already-cached programmes (an earlier single-playlist-only version of
  /// this unconditionally cleared the whole map on every call, which is
  /// exactly wrong once there's more than one source). Empty
  /// [knownChannelIds] disables filtering entirely rather than risking an
  /// empty guide if this ever races ahead of the playlist's own channels
  /// finishing their load.
  Future<void> _refreshOne(String url,
      {required Set<String> knownChannelIds}) async {
    if (url.isEmpty) return;
    // isLoading is the caller's responsibility (see [refresh]/[refreshAll])
    // — it needs to stay true across the persist step that follows this,
    // not just this one source's parse.
    error = null;
    notifyListeners();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (streamedResponse.statusCode != 200) {
        throw Exception(
            'Failed to load EPG (HTTP ${streamedResponse.statusCode})');
      }

      // Normalized the same way the parser normalizes the feed's own ids
      // (see [normalizeEpgId]) — these are Channel.epgId values (rawId or
      // a manual override), compared against the feed's <channel>/
      // <programme channel="..."> ids below, and a caller's casing
      // convention won't generally match the feed's own.
      final effectiveFilter = knownChannelIds.isEmpty
          ? null
          : knownChannelIds.map(normalizeEpgId).toSet();
      final result = await _parseXmltvStream(
        await _autoGunzip(streamedResponse.stream),
        knownChannelIds: effectiveFilter,
      ).timeout(const Duration(minutes: 10));
      final parsed = result.programs;
      // First-seen wins on a duplicate id across sources — an arbitrary
      // but harmless tie-break; these are just display labels for a
      // picker, not something correctness depends on.
      for (final entry in result.channelNames.entries) {
        _channelCatalog.putIfAbsent(entry.key, () => entry.value);
      }
      // Overwrite (not putIfAbsent) — unlike a channel's name, "what's on
      // right now" for a given id goes stale, so a fresh refresh's answer
      // should replace whatever an earlier one found.
      _nowPlayingCatalog.addAll(result.nowPlaying);

      // Only ever removes *this URL's own* previously-seen ids (channels
      // this exact source used to have programmes for but no longer does)
      // before merging the new ones in — never the owning playlist's whole
      // known-id set (see [_idsByUrl]'s doc comment for why that used to
      // wrongly delete a different source's data when a channel's override
      // pointed at it), and never a blanket clear, since more than one URL
      // shares this same `_programs` map.
      final previousIds = _idsByUrl[url];
      if (previousIds != null) {
        _programs.removeWhere((id, _) => previousIds.contains(id));
      }
      _programs.addAll(parsed);
      _idsByUrl[url] = parsed.keys.toSet();

      lastUpdated = DateTime.now();
    } catch (e) {
      error = e.toString();
      debugPrint('EpgService error: $e');
    } finally {
      client.close();
      notifyListeners();
    }
  }

  /// Transparently decompresses gzip — plenty of third-party XMLTV sources
  /// (large ones especially) are served as `.xml.gz` to save bandwidth,
  /// and a plain file host (unlike a real web server) commonly serves that
  /// as its literal bytes with no `Content-Encoding: gzip` header, so
  /// there's nothing for the HTTP client to auto-decompress — confirmed
  /// directly against a real feed advertised for this app. Detected by
  /// sniffing the gzip magic number on the stream's first chunk rather
  /// than trusting the URL's extension (a redirect, or a server not
  /// bothering to name it `.gz`, would defeat that). Still fully
  /// streaming either way — `gzip.decoder` decompresses incrementally, so
  /// this never buffers the whole (routinely much larger, decompressed)
  /// file in memory, matching [_parseXmltvStream]'s own reason for
  /// avoiding a full DOM parse.
  Future<Stream<List<int>>> _autoGunzip(Stream<List<int>> input) async {
    final it = StreamIterator(input);
    if (!await it.moveNext()) return const Stream.empty();
    final first = it.current;
    Stream<List<int>> rebuilt() async* {
      yield first;
      while (await it.moveNext()) {
        yield it.current;
      }
    }

    final isGzip = first.length >= 2 && first[0] == 0x1F && first[1] == 0x8B;
    return isGzip ? rebuilt().transform(gzip.decoder) : rebuilt();
  }

  /// Parses XMLTV as a stream of events rather than building a full DOM —
  /// full program guides (many channels x many days) are routinely well
  /// over 100MB of XML, and loading that into one String plus a full
  /// [XmlDocument] tree is exactly the kind of allocation that triggers an
  /// OutOfMemoryError on a phone's capped per-app heap.
  ///
  /// [knownChannelIds], when non-null, discards a `<programme>` for any
  /// channel not in it right at parse time instead of retaining it — a
  /// shared multi-provider EPG source routinely covers far more channels
  /// than any one playlist actually has, and retaining every one of them
  /// is the one *unbounded* allocation left in this otherwise-streaming
  /// pipeline (see this method's own doc comment above, and
  /// [EpgService._knownChannelIds]).
  Future<
      ({
        Map<String, List<EpgProgram>> programs,
        Map<String, String> channelNames,
        Map<String, EpgProgram> nowPlaying
      })> _parseXmltvStream(
    Stream<List<int>> byteStream, {
    Set<String>? knownChannelIds,
  }) async {
    final result = <String, List<EpgProgram>>{};
    // Every <channel id>'s first <display-name> — unlike [result] above,
    // never filtered by [knownChannelIds]: see [EpgService._channelCatalog]'s
    // doc comment for why the *whole* feed's directory matters here, not
    // just whatever one playlist already owns.
    final channelNames = <String, String>{};
    // Every <channel id>'s own currently-airing programme, same
    // unfiltered-by-design reasoning as [channelNames] — "Assign EPG
    // channel" needs to show what's actually on right now for each
    // *candidate* id, most of which aren't in [knownChannelIds] at all
    // (that's the whole point of searching for one). Bounded the same
    // way [channelNames] is (one entry per channel, not per programme),
    // so keeping it unfiltered costs nothing worth guarding against.
    final nowPlaying = <String, EpgProgram>{};
    final now = DateTime.now();

    String? channelId;
    String? startRaw;
    String? stopRaw;
    // 'title'/'desc' while inside a <programme>, or 'display-name' while
    // inside a <channel> — safe to share one flag either way since XMLTV
    // never nests one inside the other.
    String? currentTextTag;
    String? title;
    String? desc;
    String? catalogChannelId;
    String? catalogDisplayName;

    void finalizeProgramme() {
      if (channelId == null || startRaw == null || stopRaw == null) return;
      try {
        final start = _parseXmltvTime(startRaw);
        final stop = _parseXmltvTime(stopRaw);
        final program = EpgProgram(
          channelId: channelId,
          title: title?.trim().isNotEmpty == true ? title!.trim() : 'No Title',
          description: (desc?.trim().isNotEmpty ?? false) ? desc!.trim() : null,
          start: start,
          stop: stop,
        );
        if (program.isNowPlaying(now)) nowPlaying[channelId] = program;
        if (knownChannelIds == null || knownChannelIds.contains(channelId)) {
          result.putIfAbsent(channelId, () => []).add(program);
        }
      } catch (_) {
        // Unparseable timestamp — skip this one programme, keep going.
      }
    }

    final events = byteStream
        .transform(const Utf8Decoder(allowMalformed: true))
        .toXmlEvents()
        .normalizeEvents()
        .flatten();

    // A full-catalog EPG can be hundreds of thousands of XML events. Stream
    // delivery yields between them at the microtask level, but that's not
    // the same as yielding to the Flutter engine's frame scheduler — on
    // weak hardware, long enough runs of back-to-back microtask work can
    // still stall UI responsiveness badly enough to look frozen. Force a
    // real yield periodically so a frame always gets a chance to run.
    var eventsSinceYield = 0;
    await for (final event in events) {
      if (++eventsSinceYield >= 500) {
        eventsSinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
      if (event is XmlStartElementEvent) {
        if (event.name == 'programme') {
          channelId = null;
          startRaw = null;
          stopRaw = null;
          title = null;
          desc = null;
          currentTextTag = null;
          for (final attr in event.attributes) {
            switch (attr.name) {
              case 'channel':
                channelId = normalizeEpgId(attr.value);
              case 'start':
                startRaw = attr.value;
              case 'stop':
                stopRaw = attr.value;
            }
          }
          // A self-closing <programme/> has no title/desc children and no
          // matching end event, so it must be recorded right here.
          if (event.isSelfClosing) finalizeProgramme();
        } else if (event.name == 'channel') {
          catalogChannelId = null;
          catalogDisplayName = null;
          currentTextTag = null;
          for (final attr in event.attributes) {
            if (attr.name == 'id') {
              catalogChannelId = normalizeEpgId(attr.value);
            }
          }
        } else if ((event.name == 'title' ||
                event.name == 'desc' ||
                event.name == 'display-name') &&
            !event.isSelfClosing) {
          // Self-closing versions of these carry no text — leave
          // currentTextTag unset so we don't wait on an end event that
          // will never arrive for them.
          currentTextTag = event.name;
        }
      } else if (event is XmlTextEvent) {
        if (currentTextTag == 'title') {
          title = (title ?? '') + event.value;
        } else if (currentTextTag == 'desc') {
          desc = (desc ?? '') + event.value;
        } else if (currentTextTag == 'display-name' &&
            catalogDisplayName == null) {
          // First <display-name> only — a channel can list several
          // (language variants, abbreviations); the first is XMLTV's own
          // convention for "the" name.
          catalogDisplayName = event.value;
        }
      } else if (event is XmlEndElementEvent) {
        if (event.name == 'title' || event.name == 'desc') {
          currentTextTag = null;
        } else if (event.name == 'display-name') {
          currentTextTag = null;
        } else if (event.name == 'programme') {
          finalizeProgramme();
        } else if (event.name == 'channel') {
          final id = catalogChannelId;
          if (id != null && catalogDisplayName != null) {
            channelNames.putIfAbsent(id, () => catalogDisplayName!.trim());
          }
        }
      }
    }

    for (final list in result.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    return (
      programs: result,
      channelNames: channelNames,
      nowPlaying: nowPlaying
    );
  }

  /// Parses XMLTV timestamps such as `20240101120000 +0000`.
  DateTime _parseXmltvTime(String raw) {
    final cleaned = raw.trim();
    final datePart = cleaned.substring(0, 14);
    final year = int.parse(datePart.substring(0, 4));
    final month = int.parse(datePart.substring(4, 6));
    final day = int.parse(datePart.substring(6, 8));
    final hour = int.parse(datePart.substring(8, 10));
    final minute = int.parse(datePart.substring(10, 12));
    final second = int.parse(datePart.substring(12, 14));

    var offsetHours = 0;
    var offsetMinutes = 0;
    if (cleaned.length > 15) {
      final offsetPart = cleaned.substring(15).trim();
      final sign = offsetPart.startsWith('-') ? -1 : 1;
      final digits = offsetPart.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length >= 4) {
        offsetHours = sign * int.parse(digits.substring(0, 2));
        offsetMinutes = sign * int.parse(digits.substring(2, 4));
      }
    }

    return DateTime.utc(year, month, day, hour, minute, second)
        .subtract(Duration(hours: offsetHours, minutes: offsetMinutes))
        .toLocal();
  }

  EpgProgram? getCurrentProgram(String channelId) {
    final list = _programs[normalizeEpgId(channelId)];
    if (list == null) return null;
    final now = DateTime.now();
    for (final p in list) {
      if (p.isNowPlaying(now)) return p;
    }
    return null;
  }

  EpgProgram? getNextProgram(String channelId) {
    final list = _programs[normalizeEpgId(channelId)];
    if (list == null) return null;
    final now = DateTime.now();
    for (final p in list) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }

  List<EpgProgram> getPrograms(String channelId) =>
      _programs[normalizeEpgId(channelId)] ?? [];

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
