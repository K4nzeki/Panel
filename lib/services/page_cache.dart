import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';

/// Gets one page image's bytes from its source.
typedef PageBytesLoader = Future<Uint8List> Function(String url);

/// The page images of the chapters open in the reader, so each page is
/// downloaded once: the page on screen and the background prefetch share
/// the same request, and going back a page doesn't download it again.
///
/// Pages are kept as files in [dir] (a temporary folder) when there is one,
/// which keeps memory low on long chapters; otherwise (the web, or the
/// folder couldn't be made) in memory, up to [memoryBudget] bytes, dropping
/// the least recently used first. Only encoded bytes are kept here; decoded
/// images live in Flutter's image cache as usual.
class PageCache {
  PageCache({Future<Directory?>? dir, this.memoryBudget = 64 << 20})
      : _dir = dir ?? Future<Directory?>.value(null);

  final Future<Directory?> _dir;
  final int memoryBudget;

  final _files = <String, File>{};
  final _memory = <String, Uint8List>{};
  int _memoryBytes = 0;
  final _inFlight = <String, Future<Uint8List>>{};
  bool _disposed = false;

  /// [url] is saved (on disk or in memory).
  bool has(String url) =>
      _files.containsKey(url) || _memory.containsKey(url);

  int get memoryBytes => _memoryBytes;

  /// The bytes of [url]: saved ones straight away, otherwise loaded with
  /// [load] (once, however many callers ask at the same time). A failed
  /// load isn't remembered, so asking again tries again.
  Future<Uint8List> get(String url, PageBytesLoader load) {
    final mem = _memory.remove(url);
    if (mem != null) {
      _memory[url] = mem; // most recently used
      return SynchronousFuture(mem);
    }
    final running = _inFlight[url];
    if (running != null) return running;
    final f = _fetch(url, load);
    _inFlight[url] = f;
    f.whenComplete(() => _inFlight.remove(url)).ignore();
    return f;
  }

  Future<Uint8List> _fetch(String url, PageBytesLoader load) async {
    final file = _files[url];
    if (file != null) {
      try {
        return await file.readAsBytes();
      } catch (_) {
        _files.remove(url); // deleted under us: load it again
      }
    }
    final bytes = await load(url);
    if (bytes.isEmpty) throw const FormatException('Empty image');
    if (!_disposed) await _store(url, bytes);
    return bytes;
  }

  Future<void> _store(String url, Uint8List bytes) async {
    final d = await _dir;
    if (_disposed) return;
    if (d != null) {
      try {
        final f = File('${d.path}${Platform.pathSeparator}${fileName(url)}');
        await f.writeAsBytes(bytes, flush: false);
        if (_disposed) {
          unawaited(f.delete().then((_) {}, onError: (_) {}));
          return;
        }
        _files[url] = f;
        return;
      } catch (_) {
        // Disk full or folder gone: fall back to memory.
      }
    }
    _remember(url, bytes);
  }

  void _remember(String url, Uint8List bytes) {
    if (bytes.length > memoryBudget) return;
    final old = _memory.remove(url);
    if (old != null) _memoryBytes -= old.length;
    _memory[url] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > memoryBudget && _memory.isNotEmpty) {
      final first = _memory.keys.first;
      _memoryBytes -= _memory.remove(first)!.length;
    }
  }

  /// Drops every saved page except [urls] (e.g. the chapter you're in and
  /// the one before it), so a long reading session doesn't pile up pages.
  void retain(Iterable<String> urls) {
    final keep = urls.toSet();
    for (final url in _files.keys.where((u) => !keep.contains(u)).toList()) {
      final f = _files.remove(url)!;
      unawaited(f.delete().then((_) {}, onError: (_) {}));
    }
    for (final url in _memory.keys.where((u) => !keep.contains(u)).toList()) {
      _memoryBytes -= _memory.remove(url)!.length;
    }
  }

  /// Forgets everything and deletes the folder (the reader closed).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _files.clear();
    _memory.clear();
    _memoryBytes = 0;
    try {
      final d = await _dir;
      if (d != null && await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Two 32-bit FNV-1a hashes: a short, file-safe name for any URL.
  static String fileName(String url) {
    final s = utf8.encode(url);
    var a = 0x811c9dc5, b = 0x050c5d1f;
    for (final c in s) {
      a = ((a ^ c) * 0x01000193) & 0xffffffff;
      b = ((b ^ c) * 0x01000193) & 0xffffffff;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}'
        '${b.toRadixString(16).padLeft(8, '0')}.page';
  }
}

/// A reader page loaded through a [PageCache]. [attempt] is part of the key
/// so "Retry" really loads it again.
class CachedPageImage extends ImageProvider<CachedPageImage> {
  const CachedPageImage(this.url, this.cache, this.load, {this.attempt = 0});

  final String url;
  final PageCache cache;
  final PageBytesLoader load;
  final int attempt;

  @override
  Future<CachedPageImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedPageImage>(this);

  @override
  ImageStreamCompleter loadImage(
          CachedPageImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _decode(decode),
        scale: 1.0,
        debugLabel: 'CachedPageImage',
      );

  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    final bytes = await cache.get(url, load);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is CachedPageImage &&
      other.url == url &&
      other.attempt == attempt &&
      identical(other.cache, cache);

  @override
  int get hashCode => Object.hash(url, attempt, identityHashCode(cache));
}
