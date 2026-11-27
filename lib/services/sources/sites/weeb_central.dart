import 'package:html/dom.dart' as dom;

import '../../../models/reader.dart';
import '../reader_source.dart';
import '../site_source.dart';
import 'site_adapter.dart';

/// weebcentral.com. Its pages are plain HTML pieces loaded by htmx:
///
/// * search:   /search/data?text=…            → `<article>` per series
/// * chapters: `/series/<id>/full-chapter-list` → `<a href="/chapters/<id>">`
/// * pages:    `/chapters/<id>/images?…`        → `<img>` per page
class WeebCentral extends SiteAdapter {
  const WeebCentral();

  static const _htmx = {'HX-Request': 'true'};

  // ---- Search ----

  @override
  Future<List<SourceSeries>> search(SiteSource site, String query) async {
    final uri = Uri.parse('${site.base}/search/data').replace(queryParameters: {
      'author': '',
      'text': query,
      'sort': 'Best Match',
      'order': 'Descending',
      'official': 'Any',
      'anime': 'Any',
      'adult': 'Any',
      'display_mode': 'Full Display',
    });
    return parseSearch(await site.fetchPage(uri, headers: _htmx), uri);
  }

  /// Public for tests.
  static List<SourceSeries> parseSearch(dom.Document doc, Uri page) {
    final out = <SourceSeries>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href*="/series/"]')) {
      final href = a.attributes['href']?.trim() ?? '';
      final url = _seriesUrl(page.resolve(href));
      if (url == null || seen.contains(url)) continue;

      // The link and its title / cover sit together in one <article>.
      final card = _closest(a, 'article') ?? a;
      final img = card.querySelector('img');
      var title = _clean(card.querySelector('.truncate')?.text ??
          card.querySelector('[class*="text-lg"]')?.text ??
          '');
      if (title.isEmpty) {
        title = _clean((img?.attributes['alt'] ?? '')
            .replaceFirst(RegExp(r'\s*cover$', caseSensitive: false), ''));
      }
      if (title.isEmpty) title = _clean(a.text);
      if (title.isEmpty) continue;

      seen.add(url);
      out.add(SourceSeries(
        key: url,
        url: url,
        title: title,
        coverUrl: img == null ? null : SiteSource.imageUrl(img, page),
      ));
    }
    return out;
  }

  // ---- Chapters ----

  @override
  Future<List<ChapterInfo>> chapters(SiteSource site, String seriesKey) async {
    final id = seriesId(seriesKey);
    if (id == null) {
      throw const SourceException("This Weeb Central link doesn't look right. "
          'Pick the title again from the source list.');
    }
    final uri = Uri.parse('${site.base}/series/$id/full-chapter-list');
    final list = parseChapters(
        await site.fetchPage(uri, headers: _htmx), uri, site.name);
    if (list.isEmpty) {
      throw SourceException("Couldn't find chapters on ${site.name}.");
    }
    return list;
  }

  /// Public for tests.
  static List<ChapterInfo> parseChapters(
      dom.Document doc, Uri page, String siteName) {
    final out = <ChapterInfo>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href*="/chapters/"]')) {
      final url = page.resolve(a.attributes['href']!.trim()).toString();
      if (!seen.add(url)) continue;
      // The name is in its own span; the link also holds the date and
      // little badges ("Last Read"), so don't use the whole link text.
      String label = '';
      for (final span in a.querySelectorAll('span')) {
        final t = _clean(span.text);
        if (span.children.isEmpty &&
            RegExp(r'(chapter|episode|ch\.?|ep\.?|#)\s*\d|^\d', caseSensitive: false)
                .hasMatch(t)) {
          label = t;
          break;
        }
      }
      if (label.isEmpty) {
        label = _clean(a.text)
            .replaceAll(RegExp(r'last read', caseSensitive: false), '')
            .trim();
      }
      final time = a.querySelector('time');
      out.add(ChapterInfo(
        key: url,
        url: url,
        name: label.isEmpty ? 'Chapter' : label,
        number: parseChapterNumber(label),
        scanlator: siteName,
        uploadedAt: DateTime.tryParse(time?.attributes['datetime'] ?? '') ??
            parseSiteDate(time?.text),
      ));
    }
    return out;
  }

  // ---- Pages ----

  @override
  Future<List<String>> pages(SiteSource site, ChapterInfo chapter) async {
    final chapterUrl = Uri.parse(chapter.url ?? chapter.key);
    final path = chapterUrl.path.endsWith('/')
        ? chapterUrl.path.substring(0, chapterUrl.path.length - 1)
        : chapterUrl.path;
    final uri = chapterUrl.replace(path: '$path/images', queryParameters: {
      'is_prev': 'False',
      'current_page': '1',
      'reading_style': 'long_strip',
    });
    final found = parsePages(await site.fetchPage(uri, headers: _htmx), uri);
    if (found.isEmpty) {
      throw SourceException(
          "Couldn't find the pages of this chapter on ${site.name}.");
    }
    return found;
  }

  /// Public for tests.
  static List<String> parsePages(dom.Document doc, Uri page) {
    var imgs = doc.querySelectorAll('section[x-data] img');
    final fallback = imgs.isEmpty;
    if (fallback) imgs = doc.querySelectorAll('img');
    final seen = <String>{};
    return [
      for (final img in imgs)
        if (SiteSource.imageUrl(img, page) case final u?
            when !(fallback && _isSiteArt(u)) && seen.add(u))
          u,
    ];
  }

  // ---- Helpers ----

  /// The series id in `/series/<id>/<slug>`.
  static String? seriesId(String url) {
    final seg = Uri.tryParse(url)?.pathSegments ?? const [];
    final i = seg.indexOf('series');
    return (i >= 0 && i + 1 < seg.length && seg[i + 1].isNotEmpty)
        ? seg[i + 1]
        : null;
  }

  /// `https://weebcentral.com/series/<id>/<slug>`, without extra parts.
  static String? _seriesUrl(Uri u) {
    final seg = u.pathSegments;
    final i = seg.indexOf('series');
    if (i < 0 || i + 1 >= seg.length || seg[i + 1].isEmpty) return null;
    // Skip links like /series/random or /series/<id>/full-chapter-list.
    if (seg[i + 1] == 'random') return null;
    final keep = seg.sublist(0, (i + 3).clamp(0, seg.length));
    if (keep.length > i + 2 && keep[i + 2] == 'full-chapter-list') {
      keep.removeLast();
    }
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      pathSegments: keep,
    ).toString();
  }

  static bool _isSiteArt(String url) {
    final u = url.toLowerCase();
    return u.contains('/static/') ||
        u.contains('/cover/') ||
        u.contains('favicon') ||
        u.contains('logo');
  }

  static dom.Element? _closest(dom.Element e, String tag) {
    dom.Element? p = e;
    while (p != null && p.localName != tag) {
      p = p.parent;
    }
    return p;
  }

  static String _clean(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');
}
