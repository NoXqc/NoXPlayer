import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml_events.dart';

import '../models/epg_program.dart';
import '../utils/constants.dart';
import 'storage_service.dart';

/// Top-level (isolate-safe) so [compute] can run them off the main
/// isolate — a full-catalog EPG cache is easily tens of thousands of
/// programmes, and decoding/encoding that much JSON synchronously on the
/// UI isolate was blocking every single app start (cold launch, and any
/// resume after Android killed the backgrounded process) for a
/// noticeable, janky stretch.
Map<String, List<EpgProgram>> _decodeEpgCache(String json) {
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  final result = <String, List<EpgProgram>>{};
  decoded.forEach((channelId, list) {
    result[channelId] =
        (list as List).map((e) => EpgProgram.fromJson(e as Map<String, dynamic>)).toList();
  });
  return result;
}

String _encodeEpgCache(Map<String, List<EpgProgram>> programs) {
  final map = <String, dynamic>{};
  programs.forEach((channelId, list) {
    map[channelId] = list.map((p) => p.toJson()).toList();
  });
  return jsonEncode(map);
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
  DateTime? lastUpdated;
  bool isLoading = false;
  String? error;

  Timer? _refreshTimer;

  Future<void> init() async {
    lastUpdated = _storage.getEpgLastUpdated();
    final cached = await _storage.readCacheFile(AppConstants.cacheFileEpgPrograms);
    if (cached != null) {
      try {
        final decoded = await compute(_decodeEpgCache, cached);
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

  /// (Re)starts the periodic auto-refresh timer. Call again whenever the
  /// interval or URL changes; safe to call with an empty [url] to no-op.
  void startAutoRefresh(int minutes, String url) {
    _refreshTimer?.cancel();
    if (url.isEmpty) return;
    _refreshTimer = Timer.periodic(Duration(minutes: minutes), (_) => refresh(url));
  }

  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> refresh(String url) async {
    if (url.isEmpty) return;
    isLoading = true;
    error = null;
    notifyListeners();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse = await client.send(request).timeout(const Duration(seconds: 30));
      if (streamedResponse.statusCode != 200) {
        throw Exception('Failed to load EPG (HTTP ${streamedResponse.statusCode})');
      }

      final parsed = await _parseXmltvStream(streamedResponse.stream)
          .timeout(const Duration(minutes: 10));

      _programs.clear();
      _programs.addAll(parsed);

      lastUpdated = DateTime.now();
      final encoded = await compute(_encodeEpgCache, _programs);
      await _storage.writeCacheFile(AppConstants.cacheFileEpgPrograms, encoded);
      await _storage.setEpgLastUpdated(lastUpdated!);
    } catch (e) {
      error = e.toString();
      debugPrint('EpgService error: $e');
    } finally {
      client.close();
      isLoading = false;
      notifyListeners();
    }
  }

  /// Parses XMLTV as a stream of events rather than building a full DOM —
  /// full program guides (many channels x many days) are routinely well
  /// over 100MB of XML, and loading that into one String plus a full
  /// [XmlDocument] tree is exactly the kind of allocation that triggers an
  /// OutOfMemoryError on a phone's capped per-app heap.
  Future<Map<String, List<EpgProgram>>> _parseXmltvStream(Stream<List<int>> byteStream) async {
    final result = <String, List<EpgProgram>>{};

    String? channelId;
    String? startRaw;
    String? stopRaw;
    String? currentTextTag; // 'title' or 'desc' while collecting its text
    String? title;
    String? desc;

    void finalizeProgramme() {
      if (channelId == null || startRaw == null || stopRaw == null) return;
      try {
        final start = _parseXmltvTime(startRaw);
        final stop = _parseXmltvTime(stopRaw);
        result.putIfAbsent(channelId, () => []).add(
              EpgProgram(
                channelId: channelId,
                title: title?.trim().isNotEmpty == true ? title!.trim() : 'No Title',
                description: (desc?.trim().isNotEmpty ?? false) ? desc!.trim() : null,
                start: start,
                stop: stop,
              ),
            );
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
                channelId = attr.value;
              case 'start':
                startRaw = attr.value;
              case 'stop':
                stopRaw = attr.value;
            }
          }
          // A self-closing <programme/> has no title/desc children and no
          // matching end event, so it must be recorded right here.
          if (event.isSelfClosing) finalizeProgramme();
        } else if ((event.name == 'title' || event.name == 'desc') && !event.isSelfClosing) {
          // Self-closing <title/> / <desc/> carry no text — leave
          // currentTextTag unset so we don't wait on an end event that
          // will never arrive for them.
          currentTextTag = event.name;
        }
      } else if (event is XmlTextEvent) {
        if (currentTextTag == 'title') {
          title = (title ?? '') + event.value;
        } else if (currentTextTag == 'desc') {
          desc = (desc ?? '') + event.value;
        }
      } else if (event is XmlEndElementEvent) {
        if (event.name == 'title' || event.name == 'desc') {
          currentTextTag = null;
        } else if (event.name == 'programme') {
          finalizeProgramme();
        }
      }
    }

    for (final list in result.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    return result;
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
    final list = _programs[channelId];
    if (list == null) return null;
    final now = DateTime.now();
    for (final p in list) {
      if (p.isNowPlaying(now)) return p;
    }
    return null;
  }

  EpgProgram? getNextProgram(String channelId) {
    final list = _programs[channelId];
    if (list == null) return null;
    final now = DateTime.now();
    for (final p in list) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }

  List<EpgProgram> getPrograms(String channelId) => _programs[channelId] ?? [];

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
