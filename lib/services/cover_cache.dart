import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show SynchronousFuture, kIsWeb, visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'mangadex.dart';
import 'sources/apk_source.dart' show ApkSource;
import 'sources/reader_source.dart' show ImageFetcher, ReaderSource;

/// Cover art saved in the app's private storage, so covers show with no
/// connection. A cover is saved the first time it loads, and every cover in
/// your list is saved in the background ([prefetch]) as soon as the list
/// knows it. Saved covers always load from the phone first; the network is
/// only used for covers that were never saved.
///
/// Not on the web (no file storage there): covers load from the network.
class CoverCache {
  CoverCache._();

  static Directory? _dir;
  static Future<Directory?>? _opening;

  /// Covers known to be saved, so redrawing a list doesn't check the disk
  /// for every cover every time.
  static final _known = <String>{};

  /// Downloads in flight, so a cover shown in three places downloads once.
  static final _inFlight = <String, Future<Uint8List>>{};

  /// Covers not in your list (search results, Discover) are dropped after
  /// this long unused; covers in your list are kept.
  static const _keepOthers = Duration(days: 30);
  static const _timeout = Duration(seconds: 20);
  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

  static bool get supported => !kIsWeb;

  /// Swapped for a fake in tests.
  @visibleForTesting
  static http.Client? client;

  // ---- Headers per image host ----

  /// Headers covers from a host need, from the source they came from
  /// (many sites refuse images without their Referer).
  static final _hostHeaders = <String, Map<String, String>>{};

  /// Extensions that can load their own images (cookies, interceptors), for
  /// covers a plain download can't get.
  static final _hostFetchers = <String, ImageFetcher>{};

  static String _host(String url) =>
      (Uri.tryParse(url.trim())?.host ?? '').toLowerCase();

  /// Remembers that the cover [url] comes from a source whose images need
  /// [headers] (and, for extensions, can be loaded through [fetcher]).
  /// Applies to every cover on the same host. MangaDex covers always use
  /// MangaDex's own rules ([headersFor]).
  static void useSource(String? url,
      {Map<String, String> headers = const {}, ImageFetcher? fetcher}) {
    if (url == null) return;
    final host = _host(url);
    if (host.isEmpty || MangaDexService.isMangaDexHost(host)) return;
    // AniList's image CDN is shared by every title: no site's headers there.
    if (host == 'anilist.co' || host.endsWith('.anilist.co')) return;
    final clean = {
      for (final e in headers.entries)
        if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
          e.key.trim(): e.value.trim(),
    };
    if (clean.isNotEmpty) _hostHeaders[host] = clean;
    if (fetcher != null) _hostFetchers[host] = fetcher;
  }

  /// [useSource] for covers that [source] returned: its image headers, and
  /// for extensions that run natively, the extension itself as a fallback.
  static void useReaderSource(ReaderSource source, Iterable<String?> urls) {
    final ImageFetcher? fetcher = switch (source) {
      ApkSource(available: false) => null, // can't load anything
      ImageFetcher f => f,
      _ => null,
    };
    for (final u in urls) {
      useSource(u, headers: source.imageHeaders, fetcher: fetcher);
    }
  }

  /// The headers a download of [url] is sent with.
  static Map<String, String> headersFor(String url) {
    const accept = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
    final host = _host(url);
    if (MangaDexService.isMangaDexHost(host)) {
      // MangaDex refuses fake browser User-Agents and other sites' Referers.
      return {...MangaDexService.imageHeaders, 'Accept': accept};
    }
    final known = _hostHeaders[host];
    final out = {'User-Agent': _ua, 'Accept': accept};
    if (known != null) {
      // Header names are case-insensitive: the source's spelling wins.
      for (final e in known.entries) {
        out.removeWhere((k, _) => k.toLowerCase() == e.key.toLowerCase());
        out[e.key] = e.value;
      }
    }
    return out;
  }

  // ---- Covers that can't be loaded ----

  /// Covers the server definitely refused (not found, gone, not an image) —
  /// as opposed to the phone being offline. Titles with a reading source
  /// then look their cover up again.
  static final _broken = <String>{};

  /// Called when a cover turns out to be broken (see [isBroken]).
  static void Function(String url)? onBroken;

  static bool isBroken(String? url) =>
      url != null && _broken.contains(url.trim());

  static void _markBroken(String url) {
    if (_broken.add(url.trim())) onBroken?.call(url.trim());
  }

  @visibleForTesting
  static void resetForTest() {
    _hostHeaders.clear();
    _hostFetchers.clear();
    _broken.clear();
    _known.clear();
    _inFlight.clear();
    onBroken = null;
    client = null;
  }

  /// Opens the folder. Called in main() so the first frame can already show
  /// saved covers straight from the phone (no flash of the placeholder).
  static Future<Directory?> init() => _opening ??= _open();

  static Future<Directory?> _open() async {
    if (!supported) return null;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}cover_cache');
      if (!await d.exists()) await d.create(recursive: true);
      return _dir = d;
    } catch (_) {
      return null;
    }
  }

  /// Two 32-bit FNV-1a hashes: a short, file-safe name for any URL.
  static String fileName(String url) {
    final s = utf8.encode(url.trim());
    var a = 0x811c9dc5, b = 0x050c5d1f;
    for (final c in s) {
      a = ((a ^ c) * 0x01000193) & 0xffffffff;
      b = ((b ^ c) * 0x01000193) & 0xffffffff;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}'
        '${b.toRadixString(16).padLeft(8, '0')}.img';
  }

  static File? _fileIn(Directory? d, String url) =>
      d == null ? null : File('${d.path}${Platform.pathSeparator}${fileName(url)}');

  /// The saved copy of [url], if there is one (checked without waiting, once
  /// [init] has finished).
  static File? savedSync(String url) {
    final f = _fileIn(_dir, url);
    if (f == null) return null;
    final name = fileName(url);
    if (_known.contains(name)) return f;
    try {
      if (f.existsSync() && f.lengthSync() > 0) {
        _known.add(name);
        return f;
      }
    } catch (_) {}
    return null;
  }

  static bool isSaved(String url) => savedSync(url) != null;

  /// Deletes the saved copy of [url] (it couldn't be shown: a damaged file
  /// or not really a picture), so it downloads again next time.
  static Future<void> forget(String url) async {
    final f = _fileIn(await init(), url.trim());
    _known.remove(fileName(url));
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// The cover's bytes: from the phone when saved, otherwise downloaded and
  /// saved. Throws when it isn't saved and can't be downloaded (offline).
  static Future<Uint8List> bytes(String url) async {
    url = url.trim();
    final d = await init();
    final f = _fileIn(d, url);
    if (f != null) {
      try {
        if (await f.exists()) {
          final b = await f.readAsBytes();
          if (b.isNotEmpty) {
            unawaited(_touch(f));
            return b;
          }
        }
      } catch (_) {
        // Unreadable copy: download it again below.
      }
      _known.remove(fileName(url));
    }
    return _inFlight[url] ??= _download(url, f).whenComplete(() {
      _inFlight.remove(url);
    });
  }

  static Future<Uint8List> _download(String url, File? f) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      _markBroken(url);
      throw HttpException('Not a cover link', uri: uri);
    }
    Uint8List? body;
    Object? failure;
    var refused = false;
    try {
      final res = await (client ?? _defaultClient)
          .get(uri, headers: headersFor(url))
          .timeout(_timeout);
      final type = (res.headers['content-type'] ?? '').toLowerCase();
      if (res.statusCode == 200 &&
          res.bodyBytes.isNotEmpty &&
          !type.startsWith('text/') &&
          !type.contains('json')) {
        body = res.bodyBytes;
      } else {
        // 4xx, or a web page / error message instead of a picture. A 5xx or
        // 429 is the server having a bad moment: not broken.
        refused = (res.statusCode >= 400 &&
                res.statusCode < 500 &&
                res.statusCode != 408 &&
                res.statusCode != 429) ||
            (res.statusCode == 200);
        failure = HttpException('Cover not available (${res.statusCode})',
            uri: uri);
      }
    } catch (e) {
      failure = e; // offline, timeout…
    }
    if (body == null) {
      // The extension the cover came from can often load it itself
      // (it has the site's cookies and request rules).
      final fetcher = _hostFetchers[uri.host.toLowerCase()];
      if (fetcher != null) {
        try {
          final img = await fetcher.fetchImage(url).timeout(_timeout);
          final type = img.contentType?.toLowerCase() ?? '';
          if (img.bytes.isNotEmpty && !type.startsWith('text/')) {
            body = img.bytes;
          }
        } catch (_) {}
      }
    }
    if (body == null) {
      if (refused) _markBroken(url);
      throw failure ?? HttpException('Cover not available', uri: uri);
    }
    _broken.remove(url);
    if (f != null) {
      // Write to a temp file, then rename: a half-written cover never
      // counts as saved.
      try {
        final tmp = File('${f.path}.part');
        await tmp.writeAsBytes(body, flush: true);
        await tmp.rename(f.path);
        _known.add(fileName(url));
      } catch (_) {}
    }
    return body;
  }

  static final _defaultClient = http.Client();

  /// Marks a cover as recently used (for [prune]).
  static Future<void> _touch(File f) async {
    try {
      final age = DateTime.now().difference(await f.lastModified());
      if (age > const Duration(days: 1)) await f.setLastModified(DateTime.now());
    } catch (_) {}
  }

  static bool _prefetching = false;
  static bool _pruned = false;

  /// Covers asked for while a prefetch was running: saved right after it,
  /// so a cover found meanwhile isn't left unsaved until the next refresh.
  static Set<String>? _pending;

  /// Saves every cover in [urls] that isn't saved yet (a few at a time).
  /// Stops quietly at the first connection problem; the next call carries
  /// on. Once per app run, also drops old covers that aren't in [urls].
  static Future<void> prefetch(Iterable<String?> urls) async {
    if (!supported) return;
    final all = {
      for (final u in urls)
        if (u != null && u.trim().isNotEmpty) u.trim(),
    };
    if (_prefetching) {
      _pending = {...?_pending, ...all};
      return;
    }
    _prefetching = true;
    try {
      await _prefetch(all);
    } finally {
      _prefetching = false;
      final next = _pending;
      _pending = null;
      if (next != null && next.isNotEmpty) unawaited(prefetch(next));
    }
  }

  static Future<void> _prefetch(Set<String> all) async {
    await init();
    if (!_pruned) {
      _pruned = true;
      await prune(keep: all);
    }
    // Broken covers are skipped until the app restarts (or they're replaced).
    final missing = [
      for (final u in all)
        if (!isSaved(u) && !isBroken(u)) u,
    ];
    var failedInARow = 0;
    for (var i = 0; i < missing.length; i += 2) {
      final batch = missing.skip(i).take(2);
      final results = await Future.wait(batch.map((u) async {
        try {
          await bytes(u);
          return true;
        } on SocketException {
          return null; // offline
        } on TimeoutException {
          return null;
        } on http.ClientException {
          return null;
        } catch (_) {
          return false; // that one cover is broken; keep going
        }
      }));
      if (results.every((r) => r == null)) {
        if (++failedInARow >= 2) return; // offline: try again later
      } else {
        failedInARow = 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  /// Deletes saved covers not in [keep] that weren't used for a while.
  static Future<void> prune({required Set<String> keep}) async {
    final d = await init();
    if (d == null) return;
    final keepNames = {for (final u in keep) fileName(u)};
    final cutoff = DateTime.now().subtract(_keepOthers);
    try {
      await for (final f in d.list()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (keepNames.contains(name)) continue;
        if (name.endsWith('.part') ||
            (await f.lastModified()).isBefore(cutoff)) {
          _known.remove(name);
          await f.delete();
        }
      }
    } catch (_) {}
  }
}

/// Shows a cover from [CoverCache]: the saved copy if there is one,
/// otherwise the network (and saves it for next time).
class CachedCoverProvider extends ImageProvider<CachedCoverProvider> {
  const CachedCoverProvider(this.url);

  final String url;

  @override
  Future<CachedCoverProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedCoverProvider>(this);

  @override
  ImageStreamCompleter loadImage(
          CachedCoverProvider key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1.0,
        debugLabel: 'Cover',
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final b = await CoverCache.bytes(url);
    return decode(await ui.ImmutableBuffer.fromUint8List(b));
  }

  @override
  bool operator ==(Object other) =>
      other is CachedCoverProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
