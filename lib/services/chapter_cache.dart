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
