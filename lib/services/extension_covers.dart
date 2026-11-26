import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'extension_repo.dart';
import 'mangadex.dart' show normalizeTitle;

/// Finds a cover on the sites of the extensions you installed, for titles
/// AniList and MangaDex don't have.
///
/// Panel can't run extension code (that needs a reader like Mihon), so it
/// searches each site's own search page and takes the cover next to an
/// exact title match. This works on most WordPress-style manga sites
/// (Madara, MangaThemesia and similar themes — a large share of the
/// Keiyoushi list); sites behind Cloudflare checks or apps-only APIs are
/// skipped quietly.
class ExtensionCoverFinder {
  ExtensionCoverFinder(List<ExtSource> sources, {http.Client? client})
      : _sources = _order(sources),
        _client = client ?? http.Client();

  static final empty = ExtensionCoverFinder(const []);

  static const _prefsKey = 'ext_cover_sources_v1';
  static const _maxSitesPerTitle = 8;
  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

  final List<ExtSource> _sources;
  final http.Client _client;

  bool get isNotEmpty => _sources.isNotEmpty;

  /// Changes when the installed extensions change, so titles that weren't
  /// found before get searched again.
  String get signature {
    var h = 0x811c9dc5;
    for (final s in _sources) {
      for (final c in s.baseUrl.codeUnits) {
        h = ((h ^ c) * 0x01000193) & 0xffffffff;
      }
    }
    return '${_sources.length}-${h.toRadixString(16)}';
  }

  /// English and multi-language sites first, one entry per site.
  static List<ExtSource> _order(List<ExtSource> sources) {
    final seen = <String>{};
    final unique = [
      for (final s in sources)
        if (seen.add(_origin(s.baseUrl))) s,
    ];
    int rank(ExtSource s) => switch (s.lang) {
          'en' => 0,
          'all' => 1,
          _ => 2,
        };
    unique.sort((a, b) => rank(a).compareTo(rank(b)));
    return unique;
  }

  static String _origin(String url) {
    final u = Uri.tryParse(url);
    return u == null ? url : '${u.scheme}://${u.host}';
  }

  /// Sites of the installed extensions, saved by the extension store so the
  /// background job (which can't ask Android) can use them too.
  static Future<void> saveSources(List<ExtSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode([for (final s in sources) s.toJson()]));
  }

  static Future<ExtensionCoverFinder> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return empty;
    try {
      final list = jsonDecode(raw) as List;
      return ExtensionCoverFinder([
        for (final j in list)
          if (ExtSource.fromJson(j) case final s?) s,
      ]);
    } catch (_) {
      return empty;
    }
  }

  /// A cover URL for [title], or null if no site has an exact match.
  Future<String?> find(String title) async {
    final key = normalizeTitle(title);
    if (key.isEmpty) return null;
    for (final s in _sources.take(_maxSitesPerTitle)) {
      final base = s.baseUrl.endsWith('/')
          ? s.baseUrl.substring(0, s.baseUrl.length - 1)
          : s.baseUrl;
      final q = Uri.encodeQueryComponent(title);
      // Madara's manga search first, then the plain WordPress search.
      for (final url in ['$base/?s=$q&post_type=wp-manga', '$base/?s=$q']) {
        try {
          final uri = Uri.parse(url);
          final res = await _client.get(uri, headers: const {
            'User-Agent': _ua,
            'Accept': 'text/html,application/xhtml+xml',
          }).timeout(const Duration(seconds: 8));
          if (res.statusCode != 200) break; // blocked or no search page
          final cover = pickCover(html_parser.parse(res.body), key, uri);
          if (cover != null) return cover;
        } catch (_) {
          break; // site down or too slow: next site
        }
      }
    }
    return null;
  }

  /// The image next to a link whose title matches [key] exactly
  /// (normalized). Public for tests.
  static String? pickCover(dom.Document doc, String key, Uri page) {
    for (final a in doc.querySelectorAll('a[href]')) {
      final img = a.querySelector('img');
      final labels = [
        a.attributes['title'],
        a.text,
        img?.attributes['alt'],
      ];
      if (!labels.any((l) => l != null && normalizeTitle(l) == key)) continue;

      // The cover is inside the link, or in the same result card.
      dom.Element? found = img;
      var parent = a.parent;
      for (var depth = 0; found == null && parent != null && depth < 4; depth++) {
        found = parent.querySelector('img');
        parent = parent.parent;
      }
      final url = found == null ? null : _imageUrl(found, page);
      if (url != null) return url;
    }
    return null;
  }

  static String? _imageUrl(dom.Element img, Uri page) {
    String? pick;
    for (final attr in const [
      'data-src',
      'data-lazy-src',
      'data-original',
      'data-cfsrc',
      'src',
    ]) {
      final v = img.attributes[attr]?.trim();
      if (v != null && v.isNotEmpty && !v.startsWith('data:')) {
        pick = v;
        break;
      }
    }
    pick ??= img.attributes['data-srcset']?.trim().split(RegExp(r'\s+')).first;
    pick ??= img.attributes['srcset']?.trim().split(RegExp(r'\s+')).first;
    if (pick == null || pick.isEmpty) return null;
    final abs = page.resolve(pick);
    if (!abs.isScheme('http') && !abs.isScheme('https')) return null;
    // WordPress thumbnails look like cover-110x150.jpg; the full size
    // is the same name without the size.
    return abs
        .toString()
        .replaceFirst(RegExp(r'-\d{2,4}x\d{2,4}(?=\.(jpe?g|png|webp)$)'), '');
  }
}
