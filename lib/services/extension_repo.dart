import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

/// Link people paste for the Keiyoushi repo (shown as a suggestion).
const keiyoushiRepoUrl =
    'https://github.com/keiyoushi/extensions/raw/repo/index.pb';

/// One site an extension can read from.
class ExtSource {
  const ExtSource({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String lang;
  final String baseUrl;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'lang': lang, 'base_url': baseUrl};

  static ExtSource? fromJson(Object? j) {
    if (j is! Map) return null;
    final base = j['base_url'];
    if (base is! String || base.isEmpty) return null;
    return ExtSource(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? ''}',
      lang: '${j['lang'] ?? ''}',
      baseUrl: base,
    );
  }
}

/// How adult an extension's content is, as the repo labels it.
enum ContentRating { safe, mixed, nsfw }

/// An extension listed in a repo (a Mihon / Tachiyomi extension APK).
class Extension {
  const Extension({
    required this.name,
    required this.pkg,
    required this.apkUrl,
    required this.iconUrl,
    required this.versionName,
    required this.versionCode,
    required this.libVersion,
    required this.rating,
    required this.sources,
    required this.repoUrl,
  });

  final String name;
  final String pkg;
  final String apkUrl;
  final String? iconUrl;
  final String versionName;
  final int versionCode;
  final String libVersion;
  final ContentRating rating;
  final List<ExtSource> sources;

  /// The repo this came from.
  final String repoUrl;

  bool get isNsfw => rating == ContentRating.nsfw;

  /// From the package name: eu.kanade.tachiyomi.extension.<lang>.<name>.
  String get lang {
    final parts = pkg.split('.');
    final i = parts.indexOf('extension');
    if (i >= 0 && i + 1 < parts.length) return parts[i + 1];
    return sources.isEmpty ? 'all' : sources.first.lang;
  }
}

/// A repo's name and the extensions it lists.
class ExtRepo {
  const ExtRepo({
    required this.url,
    required this.name,
    required this.extensions,
    this.website,
    this.fingerprint,
  });

  final String url;
  final String name;
  final String? website;

  /// Signing key fingerprint the repo says its APKs are signed with.
  final String? fingerprint;
  final List<Extension> extensions;
}

class ExtensionRepoException implements Exception {
  const ExtensionRepoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads and reads extension repos. Understands the current format
/// (`index.pb`, a gzipped protobuf, used by Keiyoushi) and the older
/// `index.min.json` list.
class ExtensionRepoService {
  ExtensionRepoService({http.Client? client})
      : _client = client ?? http.Client();
  final http.Client _client;

  /// Cleans up what the user typed. Accepts the index link, a repo.json
  /// link, or a GitHub "blob" link to either.
  static String? normalizeUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    // github.com/<o>/<r>/blob/<branch>/x -> github.com/<o>/<r>/raw/<branch>/x
    if (uri.host == 'github.com' && uri.pathSegments.length > 3 &&
        uri.pathSegments[2] == 'blob') {
      final seg = [...uri.pathSegments]..[2] = 'raw';
      return uri.replace(pathSegments: seg).toString();
    }
    return uri.toString();
  }

  Future<ExtRepo> fetch(String url) async {
    var target = url;
    var bytes = await _get(target);
    // repo.json points at the real index.
    if (target.endsWith('repo.json')) {
      final meta = _json(bytes);
      final next = meta is Map ? meta['index_v2'] ?? meta['index'] : null;
      if (next is! String) {
        throw const ExtensionRepoException("That repo.json has no index link.");
      }
      target = next;
      bytes = await _get(target);
    }
    if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = Uint8List.fromList(const GZipDecoder().decodeBytes(bytes));
    }
    final first = bytes.isEmpty ? 0 : bytes[0];
    // '[' or '{' means the JSON format.
    if (first == 0x5b || first == 0x7b) return parseJsonIndex(url, bytes);
    try {
      return parseProtoIndex(url, bytes);
    } catch (_) {
      throw const ExtensionRepoException(
          "That link isn't an extension repo (expected index.pb or index.min.json).");
    }
  }

  Future<Uint8List> _get(String url) async {
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ExtensionRepoException(
          "Couldn't reach the repo. Check your connection.");
    }
    if (res.statusCode != 200) {
      throw ExtensionRepoException(
          "The repo didn't load (error ${res.statusCode}). Check the link.");
    }
    return res.bodyBytes;
  }

  static Object? _json(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Older repos: a JSON list of extensions; the APK and icon sit next to
  /// the index in `apk/` and `icon/`.
  static ExtRepo parseJsonIndex(String url, Uint8List bytes) {
    final list = _json(bytes);
    if (list is! List) {
      throw const ExtensionRepoException("That repo's list couldn't be read.");
    }
    final base = url.substring(0, url.lastIndexOf('/') + 1);
    final exts = <Extension>[];
    for (final j in list) {
      if (j is! Map) continue;
      final pkg = j['pkg'], apk = j['apk'], name = j['name'];
      if (pkg is! String || apk is! String || name is! String) continue;
      final version = '${j['version'] ?? ''}';
      exts.add(Extension(
        name: name.replaceFirst(RegExp(r'^Tachiyomi:\s*'), ''),
        pkg: pkg,
        apkUrl: '${base}apk/$apk',
        iconUrl: '${base}icon/$pkg.png',
        versionName: version,
        versionCode: (j['code'] as num?)?.toInt() ?? 0,
        libVersion: version.split('.').take(2).join('.'),
        rating: j['nsfw'] == 1 ? ContentRating.nsfw : ContentRating.safe,
        repoUrl: url,
        sources: [
          for (final s in (j['sources'] as List? ?? const []))
            if (s is Map && s['baseUrl'] is String)
              ExtSource(
                id: '${s['id'] ?? ''}',
                name: '${s['name'] ?? name}',
                lang: '${s['lang'] ?? ''}',
                baseUrl: s['baseUrl'] as String,
              ),
        ],
      ));
    }
    return ExtRepo(url: url, name: Uri.parse(url).host, extensions: exts);
  }

  /// index.pb layout (field numbers):
  ///   1 name, 2 short name, 3 signing fingerprint, 4 links {1 website},
  ///   101 extension list { 1 extension (repeated) }
  /// extension:
  ///   1 name, 2 package, 3 files {1 apk, 2 icon}, 4 lib version,
  ///   5 version code, 6 version name, 7 content rating (1 safe, 2 mixed,
  ///   3 nsfw), 8 source (repeated) {1 id, 2 name, 3 lang, 4 base url}
  static ExtRepo parseProtoIndex(String url, Uint8List bytes) {
    String? name, website, fingerprint;
    final exts = <Extension>[];
    for (final f in _Proto(bytes).fields()) {
      switch (f.number) {
        case 1:
          name = f.string;
        case 3:
          fingerprint = f.string;
        case 4:
          for (final g in _Proto(f.bytes).fields()) {
            if (g.number == 1) website = g.string;
          }
        case 101:
          for (final g in _Proto(f.bytes).fields()) {
            if (g.number == 1) {
              final e = _extension(url, g.bytes);
              if (e != null) exts.add(e);
            }
          }
      }
    }
    if (name == null && exts.isEmpty) {
      throw const FormatException('not an index');
    }
    return ExtRepo(
      url: url,
      name: name ?? Uri.parse(url).host,
      website: website,
      fingerprint: fingerprint,
      extensions: exts,
    );
  }

  static Extension? _extension(String repoUrl, Uint8List bytes) {
    String? name, pkg, apk, icon, libVersion, versionName;
    var code = 0, rating = 1;
    final sources = <ExtSource>[];
    for (final f in _Proto(bytes).fields()) {
      switch (f.number) {
        case 1:
          name = f.string;
        case 2:
          pkg = f.string;
        case 3:
          for (final g in _Proto(f.bytes).fields()) {
            if (g.number == 1) apk = g.string;
            if (g.number == 2) icon = g.string;
          }
        case 4:
          libVersion = f.string;
        case 5:
          code = f.varint;
        case 6:
          versionName = f.string;
        case 7:
          rating = f.varint;
        case 8:
          String id = '', sName = '', lang = '', base = '';
          for (final g in _Proto(f.bytes).fields()) {
            switch (g.number) {
              case 1:
                id = g.unsigned;
              case 2:
                sName = g.string;
              case 3:
                lang = g.string;
              case 4:
                base = g.string;
            }
          }
          if (base.isNotEmpty) {
            sources.add(
                ExtSource(id: id, name: sName, lang: lang, baseUrl: base));
          }
      }
    }
    if (name == null || pkg == null || apk == null) return null;
    return Extension(
      name: name,
      pkg: pkg,
      apkUrl: apk,
      iconUrl: icon,
      versionName: versionName ?? '',
      versionCode: code,
      libVersion: libVersion ?? '',
      rating: switch (rating) {
        3 => ContentRating.nsfw,
        2 => ContentRating.mixed,
        _ => ContentRating.safe,
      },
      sources: sources,
      repoUrl: repoUrl,
    );
  }
}

/// Minimal protobuf reader: just enough to walk fields.
class _Proto {
  _Proto(this._b);
  final Uint8List _b;
  int _i = 0;

  int _varint() {
    var result = 0, shift = 0;
    while (true) {
      if (_i >= _b.length) throw const FormatException('truncated');
      final x = _b[_i++];
      if (shift < 64) result |= (x & 0x7f) << shift;
      if (x < 0x80) return result;
      shift += 7;
    }
  }

  Iterable<_Field> fields() sync* {
    while (_i < _b.length) {
      final key = _varint();
      final number = key >> 3, wire = key & 7;
      switch (wire) {
        case 0:
          yield _Field(number, value: _varint());
        case 1:
          _i += 8;
        case 2:
          final len = _varint();
          if (len < 0 || _i + len > _b.length) {
            throw const FormatException('bad length');
          }
          yield _Field(number, bytes: Uint8List.sublistView(_b, _i, _i + len));
          _i += len;
        case 5:
          _i += 4;
        default:
          throw const FormatException('bad wire type');
      }
    }
  }
}

class _Field {
  _Field(this.number, {this.value = 0, Uint8List? bytes})
      : bytes = bytes ?? Uint8List(0);
  final int number;
  final int value;
  final Uint8List bytes;

  int get varint => value;
  String get string => utf8.decode(bytes, allowMalformed: true);

  /// 64-bit ids are unsigned; Dart ints are signed.
  String get unsigned => BigInt.from(value).toUnsigned(64).toString();
}
