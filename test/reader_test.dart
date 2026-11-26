import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:panel/models/entry.dart';
import 'package:panel/models/reader.dart';
import 'package:panel/services/local_store.dart';
import 'package:panel/services/mangadex.dart';
import 'package:panel/services/sources/site_source.dart';
import 'package:panel/state/reader.dart';

ChapterInfo ch(String key, double? n, {String group = 'A'}) =>
    ChapterInfo(key: key, name: 'Chapter $n', number: n, scanlator: group);

Entry entry({int chapter = 0}) => Entry(
      id: 'e1',
      title: 'Solo Leveling',
      type: EntryType.manhwa,
      status: EntryStatus.reading,
      chapter: chapter,
    );

ReadingLink link({
  String? lastKey,
  double? lastN,
  int page = 0,
  bool finished = false,
  Set<String> groups = const {},
}) =>
    ReadingLink(
      sourceId: 'mangadex',
      sourceName: 'MangaDex',
      seriesKey: 's',
      seriesTitle: 'Solo Leveling',
      scanlators: groups,
      lastChapterKey: lastKey,
      lastChapterNumber: lastN,
      lastPage: page,
      lastFinished: finished,
    );

void main() {
  group('chapter numbers', () {
    test('reads common chapter names', () {
      expect(parseChapterNumber('Chapter 12'), 12);
      expect(parseChapterNumber('Ch. 7.5 - The Gate'), 7.5);
      expect(parseChapterNumber('Episode 40'), 40);
      expect(parseChapterNumber('Vol.2 Chapter 15'), 15);
      expect(parseChapterNumber('Oneshot'), isNull);
    });
  });

  group('reading order', () {
    // Sources list newest first.
    final list = [ch('c3', 3), ch('c2b', 2, group: 'B'), ch('c2', 2), ch('c1', 1)];

    test('oldest first, one release per number', () {
      final order = readingOrder(list);
      expect(order.map((c) => c.number), [1, 2, 3]);
    });

    test('prefers the group you were reading', () {
      final order = readingOrder(list, preferred: 'B');
      expect(order[1].key, 'c2b');
    });

    test('scanlator filter', () {
      expect(filterByScanlator(list, {'B'}).map((c) => c.key), ['c2b']);
      expect(filterByScanlator(list, const {}).length, 4);
    });
  });

  group('resume', () {
    final list = [ch('c3', 3), ch('c2', 2), ch('c1', 1)];

    test('not started opens the first chapter', () {
      final t = resolveResume(entry(), link(), list)!;
      expect(t.chapter.key, 'c1');
      expect(t.page, 0);
    });

    test('goes back to the page you stopped at', () {
      final t = resolveResume(entry(chapter: 1), link(lastKey: 'c2', lastN: 2, page: 7), list)!;
      expect(t.chapter.key, 'c2');
      expect(t.page, 7);
    });

    test('finished chapter opens the next one', () {
      final t = resolveResume(
          entry(chapter: 2), link(lastKey: 'c2', lastN: 2, finished: true), list)!;
      expect(t.chapter.key, 'c3');
    });

    test('no reader progress: next unread after the library chapter', () {
      final t = resolveResume(entry(chapter: 1), link(), list)!;
      expect(t.chapter.key, 'c2');
    });

    test('library moved ahead by hand wins over old reader position', () {
      final t = resolveResume(entry(chapter: 2), link(lastKey: 'c1', lastN: 1, page: 3), list)!;
      expect(t.chapter.key, 'c3');
    });

    test('caught up', () {
      final t = resolveResume(entry(chapter: 3), link(), list)!;
      expect(t.caughtUp, isTrue);
      expect(t.chapter.key, 'c3');
    });

    test('another source: matches by chapter number', () {
      final t = resolveResume(
          entry(chapter: 1), link(lastKey: 'other-site-key', lastN: 2, page: 4), list)!;
      expect(t.chapter.key, 'c2');
      expect(t.page, 4);
    });
  });

  group('website sources', () {
    final page = Uri.parse('https://example.com/manga/solo/');

    test('Madara chapter list', () {
      final doc = html_parser.parse('''
        <ul><li class="wp-manga-chapter"><a href="/manga/solo/chapter-2/"> Chapter 2 </a>
          <span class="chapter-release-date"><i>November 20, 2026</i></span></li>
        <li class="wp-manga-chapter"><a href="/manga/solo/chapter-1/">Chapter 1</a></li></ul>''');
      final list = SiteSource.parseChapterList(doc, page, 'Example');
      expect(list.map((c) => c.number), [2, 1]);
      expect(list.first.key, 'https://example.com/manga/solo/chapter-2/');
      expect(list.first.scanlator, 'Example');
      expect(list.first.uploadedAt?.year, 2026);
    });

    test('MangaThemesia chapter list', () {
      final doc = html_parser.parse('''
        <div id="chapterlist"><ul>
          <li data-num="10.5"><a href="https://example.com/solo-10-5/">
            <span class="chapternum">Chapter 10.5</span><span class="chapterdate">2 days ago</span></a></li>
        </ul></div>''');
      final list = SiteSource.parseChapterList(doc, page, 'Example');
      expect(list.single.number, 10.5);
      expect(list.single.uploadedAt, isNotNull);
    });

    test('MangaThemesia pages from ts_reader', () {
      final doc = html_parser.parse('''<script>ts_reader.run({"sources":[{"source":"Server 1",
        "images":["https://cdn.example.com/1.jpg","https://cdn.example.com/2.jpg"]}]});</script>''');
      expect(SiteSource.parsePages(doc, page),
          ['https://cdn.example.com/1.jpg', 'https://cdn.example.com/2.jpg']);
    });

    test('Madara pages with lazy images', () {
      final doc = html_parser.parse('''<div class="reading-content">
        <img src="data:image/gif;base64,R0" data-src="  https://cdn.example.com/01.webp ">
        <img src="/wp-content/02.webp"></div>''');
      expect(SiteSource.parsePages(doc, page), [
        'https://cdn.example.com/01.webp',
        'https://example.com/wp-content/02.webp',
      ]);
    });

    test('search results', () {
      final doc = html_parser.parse('''<div class="c-tabs-item__content">
        <div class="tab-thumb"><img data-src="/c.jpg"></div>
        <div class="post-title"><h3><a href="/manga/solo/">Solo Leveling</a></h3></div></div>''');
      final r = SiteSource.parseSearch(doc, Uri.parse('https://example.com/?s=solo'));
      expect(r.single.title, 'Solo Leveling');
      expect(r.single.key, 'https://example.com/manga/solo/');
      expect(r.single.coverUrl, 'https://example.com/c.jpg');
    });
  });

  test('MangaDex feed skips external chapters and keeps group names', () {
    final list = MangaDexService.parseFeed({
      'data': [
        {
          'id': 'a',
          'attributes': {'chapter': '5', 'title': 'Gate', 'publishAt': '2026-11-01T00:00:00+00:00'},
          'relationships': [
            {'type': 'scanlation_group', 'attributes': {'name': 'Asura'}},
          ],
        },
        {
          'id': 'b',
          'attributes': {'chapter': '6', 'externalUrl': 'https://official.example'},
          'relationships': const [],
        },
      ],
    });
    expect(list.single.id, 'a');
    expect(list.single.group, 'Asura');
  });

  test('background patches apply on top of an entry', () {
    final e = entry(chapter: 3);
    final p = LocalStore.applyPatch(e, {'latest_chapter': 9, 'cover_url': 'x'});
    expect(p.latestChapter, 9);
    expect(p.coverUrl, 'x');
    expect(p.chapter, 3);
    expect(p.unreadChapters, 6);
  });

  test('reading link survives a round trip', () {
    final l = link(lastKey: 'c2', lastN: 2, page: 4, groups: {'A'});
    final back = ReadingLink.fromJson(l.toJson())!;
    expect(back.lastChapterKey, 'c2');
    expect(back.lastPage, 4);
    expect(back.scanlators, {'A'});
  });
}
