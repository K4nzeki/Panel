import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../../models/reader.dart';
import 'reader_source.dart';

/// A source from a Mihon / Tachiyomi extension installed on the phone, run
/// natively by Panel's Android side (android/app/src/main/kotlin). Android
/// only; on other platforms these sources simply don't exist.
///
/// A series' key is the extension's own manga url and a chapter's key its
/// chapter url (relative to the site, as Mihon stores them). Page "urls" are
/// tokens for [fetchImage], which loads them with the extension's own client.
class ApkSource implements ReaderSource, ImageFetcher {
  ApkSource({
    required this.sourceId,
    required this.name,
    required this.lang,
    this.baseUrl,
    this.pkg = '',
    this.extName = '',
    this.version = '',
    this.supportsLatest = false,
    this.nsfw = false,
    Map<String, String> headers = const {},
  })  : _headers = headers,
        available = true;

  /// A saved link whose extension isn't loaded here (uninstalled, not
  /// trusted, or not on Android). Every call explains that.
  ApkSource.missing({
    required String id,
    required this.name,
    required this.lang,
    this.baseUrl,
  })  : sourceId = id.startsWith(prefix) ? id.substring(prefix.length) : id,
        pkg = '',
        extName = '',
        version = '',
        supportsLatest = false,
        nsfw = false,
        _headers = const {},
        available = false;

  static ApkSource? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'], name = m['name'];
    if (id is! String || name is! String) return null;
    final headers = m['headers'];
    return ApkSource(
      sourceId: id,
      name: name,
      lang: '${m['lang'] ?? ''}',
      baseUrl: m['baseUrl'] as String?,
      pkg: '${m['pkg'] ?? ''}',
      extName: '${m['extName'] ?? ''}',
      version: '${m['version'] ?? ''}',
      supportsLatest: m['supportsLatest'] == true,
      nsfw: m['nsfw'] == true,
      headers: headers is Map
          ? {for (final e in headers.entries) '${e.key}': '${e.value}'}
          : const {},
    );
  }

  static const prefix = 'apk:';
  static String idFor(String sourceId) => '$prefix$sourceId';

  /// Mihon's 64-bit source id, as a string.
  final String sourceId;
  @override
  final String name;
  @override
  final String lang;
  final String? baseUrl;

  /// The extension app it comes from.
  final String pkg;
  final String extName;

  /// The extension app's version name.
  final String version;
  final bool supportsLatest;
  final bool nsfw;
  final bool available;
  final Map<String, String> _headers;

  @override
  String get id => idFor(sourceId);

  /// The extension's own request headers (User-Agent, Referer…).
  @override
  Map<String, String> get imageHeaders => _headers;

  // ---- Search ----

  @override
  Future<List<SourceSeries>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return (await searchPage(q)).series;
  }

  /// One page of search results. [filters] are states for [filters()], in
  /// the same order (null = leave that filter as is).
  Future<ApkMangasPage> searchPage(String query,
          {int page = 1, List<Object?>? filters}) =>
      _page({
        'mode': 'search',
        'query': query,
        'page': page,
        if (filters != null) 'filters': filters,
      });

  Future<ApkMangasPage> popular({int page = 1}) =>
      _page({'mode': 'popular', 'page': page});

  Future<ApkMangasPage> latest({int page = 1}) =>
      _page({'mode': 'latest', 'page': page});

  /// The source's search filters, as plain maps (see FilterCodec.kt).
  Future<List<Map<Object?, Object?>>> filters() async {
    final raw = await _call('getFilterList', {'sourceId': sourceId});
    return [for (final f in (raw as List?) ?? const []) if (f is Map) f];
  }

  Future<ApkMangasPage> _page(Map<String, Object?> args) async {
    final raw = await _call('searchManga', {'sourceId': sourceId, ...args});
    final m = raw is Map ? raw : const {};
    return ApkMangasPage(
      series: [
        for (final j in (m['mangas'] as List?) ?? const [])
          if (_series(j) case final s?) s,
      ],
      hasNextPage: m['hasNextPage'] == true,
    );
  }

  static SourceSeries? _series(Object? j) {
    if (j is! Map) return null;
    final url = j['url'], title = j['title'];
    if (url is! String || title is! String || title.trim().isEmpty) return null;
    final author = j['author'] as String?;
    return SourceSeries(
      key: url,
      title: title.trim(),
      coverUrl: (j['thumbnailUrl'] as String?)?.trim().nullIfEmpty,
      url: j['webUrl'] as String?,
      subtitle: author?.trim().nullIfEmpty,
    );
  }

  // ---- Reading ----

  @override
  Future<List<ChapterInfo>> chapters(String seriesKey) async {
    final raw = await _call('getChapterList', {
      'sourceId': sourceId,
      'mangaUrl': seriesKey,
    });
    return [
      for (final j in (raw as List?) ?? const [])
        if (_chapter(j) case final c?) c,
    ];
  }

  ChapterInfo? _chapter(Object? j) {
    if (j is! Map) return null;
    final url = j['url'], name = j['name'];
    if (url is! String || name is! String) return null;
    final n = (j['chapterNumber'] as num?)?.toDouble();
    final date = (j['dateUpload'] as num?)?.toInt() ?? 0;
    final scanlator = (j['scanlator'] as String?)?.trim();
    return ChapterInfo(
      key: url,
      name: name.trim().isEmpty ? url : name.trim(),
      // Mihon uses -1 for "unknown"; floats like 12.1 come back as 12.100000381.
      number: (n != null && n >= 0)
          ? (n * 1000).round() / 1000
          : parseChapterNumber(name),
      // Like website sources: no group listed → the site itself.
      scanlator: (scanlator == null || scanlator.isEmpty) ? this.name : scanlator,
      uploadedAt: date > 0 ? DateTime.fromMillisecondsSinceEpoch(date) : null,
      url: j['webUrl'] as String?,
    );
  }

  @override
  Future<List<String>> pages(ChapterInfo chapter) async {
    final raw = await _call('getPageList', {
      'sourceId': sourceId,
      'chapterUrl': chapter.key,
      'chapterName': chapter.name,
    });
    return [
      for (final (i, p) in ((raw as List?) ?? const []).indexed)
        if (p is Map)
          _pageToken((p['index'] as num?)?.toInt() ?? i, '${p['url'] ?? ''}',
              p['imageUrl'] as String?),
    ];
  }

  static const _pagePrefix = 'apkpage:';

  /// Everything the extension needs to load one page again, in one string.
  static String _pageToken(int index, String url, String? imageUrl) =>
      _pagePrefix +
      base64Url.encode(utf8.encode(
          jsonEncode({'i': index, 'u': url, if (imageUrl != null) 'm': imageUrl})));

  @override
  Future<FetchedImage> fetchImage(String url) async {
    var args = <String, Object?>{'index': 0, 'url': '', 'imageUrl': url};
    if (url.startsWith(_pagePrefix)) {
      final j = jsonDecode(
          utf8.decode(base64Url.decode(url.substring(_pagePrefix.length))));
      if (j is Map) {
        args = {'index': j['i'] ?? 0, 'url': j['u'] ?? '', 'imageUrl': j['m']};
      }
    }
    final raw = await _call('fetchImage', {'sourceId': sourceId, ...args});
    final m = raw is Map ? raw : const {};
    final bytes = m['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) {
      throw SourceException('$name sent an empty page.');
    }
    return FetchedImage(bytes, contentType: m['contentType'] as String?);
  }

  // ---- Channel ----

  void _checkAvailable() {
    if (!available || !ApkBridge.supported) throw _notAvailable;
  }

  SourceException get _notAvailable => SourceException(
      "$name's extension isn't installed or trusted on this phone. "
      'Trust it in the Extension store, or pick another source.');

  Future<Object?> _call(String method, Map<String, Object?> args) async {
    _checkAvailable();
    try {
      return await ApkBridge.channel
          .invokeMethod<Object?>(method, args)
          // Native gives up after 60 s; this only catches a stuck channel.
          .timeout(const Duration(seconds: 75));
    } on TimeoutException {
      throw SourceException('$name is taking too long. Try again.');
    } on MissingPluginException {
      throw _notAvailable;
    } on PlatformException catch (e) {
      throw _error(e);
    }
  }

  SourceException _error(PlatformException e) {
    switch (e.code) {
      case 'offline':
        return const SourceException(
            "You're offline. Downloaded chapters still work.",
            offline: true);
      case 'timeout':
        return SourceException('$name is taking too long. Try again.');
      case 'cloudflare':
        return SourceException(
            '$name: ${e.message ?? "Couldn't pass the site's Cloudflare check"}. '
            'Try again in a minute, or pick another source.');
      case 'not_found':
        return _notAvailable;
      case 'http':
        final d = e.details;
        final code = d is Map ? d['httpCode'] : null;
        if (code == 403 || code == 503) {
          return SourceException('$name refused the request (error $code).');
        }
        return SourceException('$name answered with error ${code ?? '?'}.');
      default:
        return SourceException('$name: ${e.message ?? e.code}');
    }
  }
}

/// One page of results from an extension.
class ApkMangasPage {
  const ApkMangasPage({required this.series, required this.hasNextPage});
  final List<SourceSeries> series;
  final bool hasNextPage;
}

/// An installed extension Panel didn't load, and why.
class ApkLoadError {
  const ApkLoadError({
    required this.pkg,
    required this.name,
    required this.version,
    required this.reason,
    this.untrusted = false,
    this.signature,
  });

  final String pkg;
  final String name;
  final String version;
  final String reason;

  /// Waiting to be trusted; [signature] is its signing key (SHA-256).
  final bool untrusted;
  final String? signature;

  static ApkLoadError? fromMap(Object? m) {
    if (m is! Map) return null;
    final pkg = m['pkg'];
    if (pkg is! String) return null;
    return ApkLoadError(
      pkg: pkg,
      name: '${m['name'] ?? pkg}',
      version: '${m['version'] ?? ''}',
      reason: '${m['reason'] ?? ''}',
      untrusted: m['untrusted'] == true,
      signature: m['signature'] as String?,
    );
  }
}

/// What the Android side loaded.
class ApkExtensions {
  const ApkExtensions({this.sources = const [], this.errors = const []});

  final List<ApkSource> sources;
  final List<ApkLoadError> errors;

  /// Extensions waiting to be trusted, by package.
  Map<String, ApkLoadError> get untrusted => {
        for (final e in errors)
          if (e.untrusted) e.pkg: e,
      };
}

/// Calls to the extension runtime that aren't about one source.
abstract final class ApkBridge {
  static const channel = MethodChannel('com.readlist.panel/extensions');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<ApkExtensions> load({bool reload = false}) async {
    if (!supported) return const ApkExtensions();
    final sources = await channel
        .invokeListMethod<Object?>('getInstalledSources', {'reload': reload});
    final errors = await channel.invokeListMethod<Object?>('getLoadErrors');
    return ApkExtensions(
      sources: [
        for (final m in sources ?? const [])
          if (ApkSource.fromMap(m) case final s?) s,
      ],
      errors: [
        for (final m in errors ?? const [])
          if (ApkLoadError.fromMap(m) case final e?) e,
      ],
    );
  }

  /// The signing fingerprints of your repos: their extensions are trusted.
  static Future<void> setTrustedKeys(Iterable<String> keys) async {
    if (!supported) return;
    await channel.invokeMethod('setTrustedKeys', {'keys': keys.toList()});
  }

  static Future<void> trust(String pkg, String signature) async {
    if (!supported) return;
    await channel
        .invokeMethod('trustExtension', {'pkg': pkg, 'signature': signature});
  }

  static Future<void> untrust(String pkg) async {
    if (!supported) return;
    await channel.invokeMethod('untrustExtension', {'pkg': pkg});
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
