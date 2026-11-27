import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/reader.dart';
import 'sources/reader_source.dart';

/// A chapter saved on the phone.
class DownloadedChapter {
  const DownloadedChapter({
    required this.entryId,
    required this.entryTitle,
    required this.sourceId,
    required this.chapter,
    required this.dir,
    required this.files,
    required this.complete,
    this.downloadedAt,
  });

  final String entryId;
  final String entryTitle;
  final String sourceId;
  final ChapterInfo chapter;

  /// The chapter's folder.
  final String dir;

  /// Page file names inside [dir], in order.
  final List<String> files;
  final bool complete;
  final DateTime? downloadedAt;

  String get id => downloadId(entryId, chapter.key);

  List<String> get paths =>
      [for (final f in files) '$dir${Platform.pathSeparator}$f'];

  Map<String, dynamic> toJson() => {
        'entry_id': entryId,
        'entry_title': entryTitle,
        'source_id': sourceId,
        'chapter': chapter.toJson(),
        'files': files,
        'complete': complete,
        'downloaded_at': downloadedAt?.millisecondsSinceEpoch,
      };

  static DownloadedChapter? fromJson(Object? j, String dir) {
    if (j is! Map) return null;
    final entryId = j['entry_id'];
    final chapter = ChapterInfo.fromJson(j['chapter']);
    if (entryId is! String || chapter == null) return null;
    final at = j['downloaded_at'];
    return DownloadedChapter(
      entryId: entryId,
      entryTitle: '${j['entry_title'] ?? ''}',
      sourceId: '${j['source_id'] ?? ''}',
      chapter: chapter,
      dir: dir,
      files: [
        for (final f in (j['files'] as List?) ?? const [])
          if (f is String) f,
      ],
      complete: j['complete'] == true,
      downloadedAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

String downloadId(String entryId, String chapterKey) => '$entryId|$chapterKey';

/// Downloaded chapters live only on this phone, in Panel's own folder on
/// the phone's storage:
///
///   Android: Android/data/com.readlist.panel/files/Panel Downloads/
///            `<Title>/<Chapter (Scanlator)>/001.jpg`, `002.jpg`, …
///
/// That folder belongs to the app, so Android needs no storage permission
/// for it on any version (scoped storage friendly). A `.nomedia` file keeps
/// pages out of the gallery. Android removes the folder if Panel is
/// uninstalled. Each chapter folder has a `chapter.json` describing it, so
/// the list of downloads is rebuilt from the folder itself.
class DownloadStore {
  static const _manifest = 'chapter.json';
  static Directory? _root;

  static bool get supported => !kIsWeb;

  static Future<Directory?> root() async {
    if (!supported) return null;
    if (_root != null) return _root;
    Directory? base;
    if (Platform.isAndroid) {
      try {
        base = await getExternalStorageDirectory();
      } catch (_) {}
    }
    base ??= await getApplicationDocumentsDirectory();
    final d = Directory(
        '${base.path}${Platform.pathSeparator}${AppConfig.downloadsFolder}');
    if (!await d.exists()) await d.create(recursive: true);
    if (Platform.isAndroid) {
      final nomedia = File('${d.path}${Platform.pathSeparator}.nomedia');
      if (!await nomedia.exists()) await nomedia.create();
    }
    return _root = d;
  }

  /// Every chapter folder with a readable chapter.json.
  static Future<List<DownloadedChapter>> scan() async {
    final r = await root();
    if (r == null) return const [];
    final out = <DownloadedChapter>[];
    await for (final title in r.list(followLinks: false)) {
      if (title is! Directory) continue;
      try {
        await for (final ch in title.list(followLinks: false)) {
          if (ch is! Directory) continue;
          final m = File('${ch.path}${Platform.pathSeparator}$_manifest');
          if (!await m.exists()) continue;
          try {
            final d = DownloadedChapter.fromJson(
                jsonDecode(await m.readAsString()), ch.path);
            if (d != null) out.add(d);
          } catch (_) {}
        }
      } catch (_) {}
    }
    return out;
  }

  /// File-system-safe folder name.
  static String safeName(String s) {
    var t = s
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    while (t.endsWith('.')) {
      t = t.substring(0, t.length - 1).trim();
    }
    if (t.length > 80) t = t.substring(0, 80).trim();
    return t.isEmpty ? 'Untitled' : t;
  }

  /// The folder for [chapter] of [entryTitle], created if needed. If another
  /// chapter already uses the natural name, a short id is added.
  static Future<Directory> chapterDir(
      String entryTitle, ChapterInfo chapter) async {
    final r = (await root())!;
    final sep = Platform.pathSeparator;
    final title = Directory('${r.path}$sep${safeName(entryTitle)}');
    final label = chapter.scanlator == null
        ? chapter.name
        : '${chapter.name} (${chapter.scanlator})';
    var dir = Directory('${title.path}$sep${safeName(label)}');
    final m = File('${dir.path}$sep$_manifest');
    if (await m.exists()) {
      try {
        final j = jsonDecode(await m.readAsString());
        final chapterJson = (j is Map) ? j['chapter'] : null;
        final key = (chapterJson is Map) ? chapterJson['key'] : null;
        if (key != chapter.key) {
          dir = Directory('${dir.path} [${_short(chapter.key)}]');
        }
      } catch (_) {}
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _short(String s) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0').substring(0, 6);
  }

  static Future<void> writeManifest(DownloadedChapter d) => File(
          '${d.dir}${Platform.pathSeparator}$_manifest')
      .writeAsString(jsonEncode(d.toJson()));

  /// Downloads one page image to [dir] as `NNN.ext`; returns the file name.
  static Future<String> savePage(http.Client client, String url, int index,
      Directory dir, Map<String, String> headers,
      {ImageFetcher? fetcher}) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (fetcher != null) {
          // Extension sources load their own images (headers, cookies...).
          final img = await fetcher
              .fetchImage(url)
              .timeout(const Duration(seconds: 90));
          final name = '${(index + 1).toString().padLeft(3, '0')}.'
              '${_extFor(img.contentType ?? '', '')}';
          await File('${dir.path}${Platform.pathSeparator}$name')
              .writeAsBytes(img.bytes, flush: true);
          return name;
        }
        final res = await client
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 45));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          throw HttpException('Page ${index + 1} failed (${res.statusCode})');
        }
        final name =
            '${(index + 1).toString().padLeft(3, '0')}.${_ext(res, url)}';
        await File('${dir.path}${Platform.pathSeparator}$name')
            .writeAsBytes(res.bodyBytes, flush: true);
        return name;
      } catch (e) {
        lastError = e;
        if (e is SocketException) rethrow; // offline: don't keep trying
        if (e is SourceException && e.offline) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 + attempt * 2));
      }
    }
    throw lastError ?? const HttpException('Download failed');
  }

  static String _ext(http.Response res, String url) =>
      _extFor(res.headers['content-type'] ?? '', url);

  static String _extFor(String type, String url) {
    if (type.contains('png')) return 'png';
    if (type.contains('webp')) return 'webp';
    if (type.contains('gif')) return 'gif';
    if (type.contains('avif')) return 'avif';
    if (type.contains('jpeg') || type.contains('jpg')) return 'jpg';
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final e in const ['png', 'webp', 'gif', 'avif', 'jpeg', 'jpg']) {
      if (path.endsWith('.$e')) return e == 'jpeg' ? 'jpg' : e;
    }
    return 'jpg';
  }

  static Future<void> delete(DownloadedChapter d) async {
    final dir = Directory(d.dir);
    if (await dir.exists()) await dir.delete(recursive: true);
    // Remove the title folder too once it's empty.
    final parent = dir.parent;
    try {
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (_) {}
  }

  static Future<void> deleteAll() async {
    final r = await root();
    if (r == null) return;
    await for (final f in r.list(followLinks: false)) {
      if (f is Directory) await f.delete(recursive: true);
    }
  }

  /// Bytes used by all downloads.
  static Future<int> usedBytes() async {
    final r = await root();
    if (r == null) return 0;
    var total = 0;
    await for (final f in r.list(recursive: true, followLinks: false)) {
      if (f is File) {
        try {
          total += await f.length();
        } catch (_) {}
      }
    }
    return total;
  }
}
