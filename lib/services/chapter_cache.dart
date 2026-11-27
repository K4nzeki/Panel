import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../models/reader.dart';

/// The last chapter list seen for each series, saved in the app's private
/// storage so chapter lists, Resume and the scanlator filter work offline.
class ChapterCache {
  static Directory? _dir;

  static Future<Directory?> _folder() async {
    if (kIsWeb) return null;
    if (_dir != null) return _dir;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}chapter_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  /// Two 32-bit FNV-1a hashes: a short, file-safe name for any URL.
  static String fileKey(String sourceId, String seriesKey) {
    final s = utf8.encode('$sourceId\n$seriesKey');
    var a = 0x811c9dc5, b = 0x050c5d1f;
    for (final c in s) {
      a = ((a ^ c) * 0x01000193) & 0xffffffff;
      b = ((b ^ c) * 0x01000193) & 0xffffffff;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}'
        '${b.toRadixString(16).padLeft(8, '0')}';
  }

  static Future<File?> _file(String sourceId, String seriesKey) async {
    final d = await _folder();
    if (d == null) return null;
    return File('${d.path}${Platform.pathSeparator}'
        '${fileKey(sourceId, seriesKey)}.json');
  }

  static Future<({List<ChapterInfo> chapters, DateTime fetchedAt})?> read(
      String sourceId, String seriesKey) async {
    try {
      final f = await _file(sourceId, seriesKey);
      if (f == null || !await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['series_key'] != seriesKey) return null;
      return (
        chapters: [
          for (final c in (j['chapters'] as List?) ?? const [])
            if (ChapterInfo.fromJson(c) case final ch?) ch,
        ],
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['fetched_at'] as num?)?.toInt() ?? 0),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(
      String sourceId, String seriesKey, List<ChapterInfo> chapters) async {
    try {
      final f = await _file(sourceId, seriesKey);
      if (f == null) return;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'source_id': sourceId,
        'series_key': seriesKey,
        'fetched_at': DateTime.now().millisecondsSinceEpoch,
        'chapters': [for (final c in chapters) c.toJson()],
      }));
      await tmp.rename(f.path);
    } catch (_) {}
  }
}

/// The page lists (image urls) of chapters asked for during one reading
/// session, kept in memory so the next / previous chapter can be fetched
/// ahead of time and opens at once when you scroll into it.
///
/// Not saved on the phone: some sources (MangaDex) hand out image urls that
/// stop working after a while, so entries expire after [maxAge]. A failed
/// load isn't remembered, so asking again tries again. Only the newest
/// [maxEntries] lists are kept.
class ChapterPagesCache {
  ChapterPagesCache({
    this.maxAge = const Duration(minutes: 10),
    this.maxEntries = 8,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration maxAge;
  final int maxEntries;
  final DateTime Function() _now;

  final _entries = <String, _PagesEntry>{};

  static String _key(String sourceId, String chapterKey) =>
      '$sourceId\n$chapterKey';

  _PagesEntry? _fresh(String key) {
    final e = _entries[key];
    if (e == null) return null;
    if (_now().difference(e.at) > maxAge) {
      _entries.remove(key);
      return null;
    }
    return e;
  }

  /// The page list of [chapterKey] on [sourceId]: a fresh saved one, the
  /// request already running for it, or a new one from [load].
  Future<List<String>> get(String sourceId, String chapterKey,
      Future<List<String>> Function() load) {
    final key = _key(sourceId, chapterKey);
    final hit = _fresh(key);
    if (hit != null) {
      _entries.remove(key);
      _entries[key] = hit; // most recently used
      return hit.pages;
    }
    final entry = _PagesEntry(_now(), load());
    _entries[key] = entry;
    entry.pages.then<void>((v) {
      entry.value = v;
    }, onError: (Object _) {
      if (identical(_entries[key], entry)) _entries.remove(key);
    }).ignore();
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return entry.pages;
  }

  /// The saved page list, if it has already arrived (no loading).
  List<String>? peek(String sourceId, String chapterKey) =>
      _fresh(_key(sourceId, chapterKey))?.value;

  bool has(String sourceId, String chapterKey) =>
      _fresh(_key(sourceId, chapterKey)) != null;

  void clear() => _entries.clear();
}

class _PagesEntry {
  _PagesEntry(this.at, this.pages);
  final DateTime at;
  final Future<List<String>> pages;
  List<String>? value;
}
