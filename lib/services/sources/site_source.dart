import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../../models/reader.dart';
import '../extension_repo.dart';
import 'reader_source.dart';

/// A manga website from an extension repo, read directly.
///
/// Works with the two WordPress themes a large share of manga sites use:
/// **Madara** (`li.wp-manga-chapter`, `.reading-content img`) and
/// **MangaThemesia** (`#chapterlist`, `ts_reader.run(...)`). Sites with their
/// own app-only APIs or behind Cloudflare's browser check can't be read this
/// way — the error says so, and you can pick another source.
///
/// Website sources have no scanlator list per chapter, so each chapter's
/// "scanlator" is the site itself.
class SiteSource implements ReaderSource {
  SiteSource({
    required this.name,
    required this.lang,
    required String baseUrl,
    http.Client? client,
  })  : base = _trimSlash(baseUrl),
        _client = client ?? _shared;

  factory SiteSource.fromExt(ExtSource s) =>
      SiteSource(name: s.name, lang: s.lang, baseUrl: s.baseUrl);

  static final _shared = http.Client();

  static String idFor(String baseUrl) => 'site:${origin(baseUrl)}';

  static String origin(String url) {
    final u = Uri.tryParse(url);
    return (u == null || u.host.isEmpty) ? url : '${u.scheme}://${u.host}';
  }

  static String _trimSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  @override
  final String name;
  @override
  final String lang;
  final String base;
  final http.Client _client;

  @override
  String get id => idFor(base);

  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Accept': 'text/html,application/xhtml+xml,*/*',
        'Referer': '$base/',
      };

  @override
  Map<String, String> get imageHeaders => {
        'User-Agent': _ua,
        'Referer': '$base/',
        'Accept': 'image/avif,image/webp,image/*,*/*',
      };

  Future<dom.Document> _page(Uri uri, {Map<String, String>? form}) async {
    final http.Response res;
    try {
      res = form == null
          ? await _client
              .get(uri, headers: _headers)
              .timeout(const Duration(seconds: 20))
          : await _client
              .post(uri,
                  headers: {..._headers, 'X-Requested-With': 'XMLHttpRequest'},
                  body: form)
              .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw sourceError(e, name);
    }
    if (res.statusCode == 403 || res.statusCode == 503) {
      final cloudflare = res.headers.containsKey('cf-ray') ||
          (res.headers['server'] ?? '').toLowerCase().contains('cloudflare');
      throw SourceException(cloudflare
          ? "$name is behind a Cloudflare check Panel can't pass. Try another source."
          : '$name refused the request (error ${res.statusCode}).');
    }
    if (res.statusCode != 200) {
      throw SourceException('$name answered with error ${res.statusCode}.');
    }
    // Decode as UTF-8 ourselves: without a charset header, http assumes Latin-1.
    return html_parser.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  // ---- Search ----

  @override
  Future<List<SourceSeries>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final enc = Uri.encodeQueryComponent(q);
    SourceException? last;
    // Madara's manga search first, then the plain WordPress search.
    for (final url in ['$base/?s=$enc&post_type=wp-manga', '$base/?s=$enc']) {
      try {
        final uri = Uri.parse(url);
        final found = parseSearch(await _page(uri), uri);
        if (found.isNotEmpty) return found;
      } on SourceException catch (e) {
        if (e.offline) rethrow;
        last = e;
      }
    }
    if (last != null) throw last;
    return const [];
  }

  /// Search results on a Madara or MangaThemesia page. Public for tests.
  static List<SourceSeries> parseSearch(dom.Document doc, Uri page) {
    final out = <SourceSeries>[];
    final seen = <String>{};
    void add(String? href, String? title, dom.Element? img) {
      final t = title?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
      if (href == null || href.trim().isEmpty || t.isEmpty) return;
      final abs = page.resolve(href.trim()).toString();
      if (!seen.add(abs)) return;
      out.add(SourceSeries(
        key: abs,
        title: t,
        url: abs,
        coverUrl: img == null ? null : imageUrl(img, page),
      ));
    }

    // Madara
    for (final item
        in doc.querySelectorAll('.c-tabs-item__content, .page-item-detail')) {
      final a = item.querySelector('.post-title a') ??
          item.querySelector('h3 a') ??
          item.querySelector('h4 a');
      add(a?.attributes['href'], a?.text, item.querySelector('img'));
    }
    if (out.isNotEmpty) return out;

    // MangaThemesia
    for (final a in doc.querySelectorAll('.bsx > a, .bs a, .listupd a')) {
      if (a.querySelector('img') == null) continue;
      add(a.attributes['href'],
          a.attributes['title'] ?? a.querySelector('.tt')?.text,
          a.querySelector('img'));
    }
    return out;
  }

  // ---- Chapters ----

  @override
  Future<List<ChapterInfo>> chapters(String seriesKey) async {
    final uri = Uri.parse(seriesKey);
    final doc = await _page(uri);
    var list = parseChapterList(doc, uri, name);
    if (list.isEmpty) {
      // Newer Madara sites load the list separately.
      final slash = seriesKey.endsWith('/') ? seriesKey : '$seriesKey/';
      try {
        list = parseChapterList(
            await _page(Uri.parse('${slash}ajax/chapters/'), form: const {}),
            uri,
            name);
      } on SourceException catch (e) {
        if (e.offline) rethrow;
      }
    }
    if (list.isEmpty) {
      // Older Madara: through admin-ajax with the post id.
      final id = doc
              .querySelector('#manga-chapters-holder')
              ?.attributes['data-id'] ??
          doc.querySelector('.rating-post-id')?.attributes['value'] ??
          doc.querySelector('[data-post-id]')?.attributes['data-post-id'];
      if (id != null && id.isNotEmpty) {
        try {
          list = parseChapterList(
              await _page(Uri.parse('$base/wp-admin/admin-ajax.php'),
                  form: {'action': 'manga_get_chapters', 'manga': id}),
              uri,
              name);
        } on SourceException catch (e) {
          if (e.offline) rethrow;
        }
      }
    }
    if (list.isEmpty) {
      throw SourceException("Couldn't find chapters on $name. This site "
          "isn't one Panel can read — try another source.");
    }
    return list;
  }

  /// Chapter links on a series page (or an ajax chapter-list response).
  /// Public for tests.
  static List<ChapterInfo> parseChapterList(
      dom.Document doc, Uri page, String siteName) {
    final out = <ChapterInfo>[];
    final seen = <String>{};
    String clean(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

    // MangaThemesia
    for (final li in doc.querySelectorAll('#chapterlist li')) {
      final a = li.querySelector('a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.trim().isEmpty) continue;
      final url = page.resolve(href.trim()).toString();
      if (!seen.add(url)) continue;
      final label = clean(li.querySelector('.chapternum')?.text ?? a.text);
      out.add(ChapterInfo(
        key: url,
        url: url,
        name: label.isEmpty ? 'Chapter' : label,
        number: double.tryParse(li.attributes['data-num'] ?? '') ??
            parseChapterNumber(label),
        scanlator: siteName,
        uploadedAt: parseSiteDate(li.querySelector('.chapterdate')?.text),
      ));
    }
    if (out.isNotEmpty) return out;

    // Madara
    for (final li in doc.querySelectorAll('li.wp-manga-chapter')) {
      final a = li.querySelector('a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.trim().isEmpty) continue;
      final url = page.resolve(href.trim()).toString();
      if (!seen.add(url)) continue;
      final label = clean(a.text);
      final date = li.querySelector('.chapter-release-date');
      out.add(ChapterInfo(
        key: url,
        url: url,
        name: label.isEmpty ? 'Chapter' : label,
        number: parseChapterNumber(label),
        scanlator: siteName,
        // New chapters show "2 hours ago" in a link title instead of text.
        uploadedAt: parseSiteDate(date?.querySelector('a')?.attributes['title']) ??
            parseSiteDate(date?.text),
      ));
    }
    return out;
  }

  // ---- Pages ----

  @override
  Future<List<String>> pages(ChapterInfo chapter) async {
    final uri = Uri.parse(chapter.url ?? chapter.key);
    // Madara shows every page at once with style=list; others ignore it.
    final target = uri.queryParameters.containsKey('style')
        ? uri
        : uri.replace(
            queryParameters: {...uri.queryParameters, 'style': 'list'});
    final found = parsePages(await _page(target), target);
    if (found.isEmpty) {
      throw SourceException("Couldn't find the pages of this chapter on $name.");
    }
    return found;
  }

  /// Page images of a chapter page. Public for tests.
  static List<String> parsePages(dom.Document doc, Uri page) {
    // MangaThemesia keeps the image list in a script: ts_reader.run({...});
    for (final s in doc.querySelectorAll('script')) {
      final t = s.text;
      final at = t.indexOf('ts_reader.run(');
      if (at < 0) continue;
      final start = t.indexOf('{', at);
      final end = t.lastIndexOf('})');
      if (start < 0 || end <= start) continue;
      try {
        final j = jsonDecode(t.substring(start, end + 1));
        final sources = j is Map ? j['sources'] : null;
        if (sources is List) {
          for (final src in sources) {
            final images = src is Map ? src['images'] : null;
            if (images is List && images.isNotEmpty) {
              return [
                for (final i in images)
                  if (i is String && i.trim().isNotEmpty)
                    page.resolve(i.trim()).toString(),
              ];
            }
          }
        }
      } catch (_) {}
    }

    // Madara and most others: plain images in the reading area.
    for (final sel in const [
      '.reading-content img',
      '#readerarea img',
      '.page-break img',
      '.wp-manga-chapter-img',
      '.chapter-content img',
      '.container-chapter-reader img',
    ]) {
      final seen = <String>{};
      final urls = [
        for (final img in doc.querySelectorAll(sel))
          if (imageUrl(img, page) case final u? when seen.add(u)) u,
      ];
      if (urls.isNotEmpty) return urls;
    }
    return const [];
  }

  /// The real image of an <img>, looking past lazy-loading placeholders.
  static String? imageUrl(dom.Element img, Uri page) {
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
    return abs.toString();
  }
}

/// Dates as manga sites print them: "November 26, 2026", "26/11/2026",
/// "2 hours ago", "yesterday". Null when it can't tell.
DateTime? parseSiteDate(String? raw, {DateTime? now}) {
  final s = raw?.trim().toLowerCase() ?? '';
  if (s.isEmpty) return null;
  final today = now ?? DateTime.now();
  if (s.contains('today') || s.contains('just now')) return today;
  if (s.contains('yesterday')) return today.subtract(const Duration(days: 1));
  final rel = RegExp(r'(\d+)\s*(sec|min|hour|hr|day|week|month|year)')
      .firstMatch(s);
  if (rel != null && (s.contains('ago') || s.contains('before'))) {
    final n = int.parse(rel.group(1)!);
    final unit = rel.group(2)!;
    final d = switch (unit) {
      'sec' => Duration(seconds: n),
      'min' => Duration(minutes: n),
      'hour' || 'hr' => Duration(hours: n),
      'day' => Duration(days: n),
      'week' => Duration(days: 7 * n),
      'month' => Duration(days: 30 * n),
      _ => Duration(days: 365 * n),
    };
    return today.subtract(d);
  }
  final text = raw!.trim();
  for (final f in const [
    'MMMM d, yyyy',
    'MMM d, yyyy',
    'd MMMM yyyy',
    'd MMM yyyy',
    'yyyy-MM-dd',
    'dd/MM/yyyy',
    'MM/dd/yyyy',
  ]) {
    try {
      return DateFormat(f, 'en_US').parseLoose(text);
    } catch (_) {}
  }
  return null;
}
