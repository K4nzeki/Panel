import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:panel/models/entry.dart';
import 'package:panel/models/reader.dart';
import 'package:panel/services/local_store.dart';
import 'package:panel/services/mangadex.dart';
import 'package:panel/services/page_cache.dart';
import 'package:panel/services/page_prefetcher.dart';
import 'package:panel/services/sources/site_source.dart';
import 'package:panel/services/sources/sites/site_adapter.dart';
import 'package:panel/services/sources/sites/weeb_central.dart';
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

    test('tells supported site themes from custom-built sites', () {
      // Madara search with zero hits: still a site Panel can read.
      expect(
          SiteSource.isSupportedSite(html_parser.parse(
              '<div class="search-wrap"><p>No matches</p></div>')),
          isTrue);
      expect(
          SiteSource.isSupportedSite(html_parser.parse(
              '<link href="/wp-content/themes/mangareader/style.css">')),
          isTrue);
      // A Next.js-style site: Panel can't read it, so no "No results".
      expect(
          SiteSource.isSupportedSite(html_parser.parse(
              '<div id="__next"><script src="/_next/static/app.js"></script></div>')),
          isFalse);
    });
  });

  group('Weeb Central', () {
    test('is picked by host', () {
      expect(SiteAdapter.forUrl('https://weebcentral.com'), isA<WeebCentral>());
      expect(SiteAdapter.forUrl('https://example.com'), isNull);
    });

    test('search results', () {
      final page = Uri.parse('https://weebcentral.com/search/data?text=double');
      final doc = html_parser.parse('''
        <article class="bg-base-300"><section class="w-full">
          <a href="https://weebcentral.com/series/01J76XYABC/Double-Click">
            <picture><img src="https://temp.compsci88.com/cover/normal/01J76XYABC.webp" alt="Double Click cover"></picture>
            <div class="text-ellipsis truncate text-white text-center text-lg z-20 w-[90%]">Double Click</div>
          </a></section>
          <section><a href="https://weebcentral.com/series/01J76XYABC/Double-Click">Double Click</a></section>
        </article>''');
      final r = WeebCentral.parseSearch(doc, page);
      expect(r.single.title, 'Double Click');
      expect(r.single.key, 'https://weebcentral.com/series/01J76XYABC/Double-Click');
      expect(r.single.coverUrl, contains('01J76XYABC.webp'));
      expect(WeebCentral.seriesId(r.single.key), '01J76XYABC');
    });

    test('chapter list', () {
      final page = Uri.parse('https://weebcentral.com/series/01J76XYABC/full-chapter-list');
      final doc = html_parser.parse('''
        <div x-data="{}"><a href="https://weebcentral.com/chapters/01JCH2">
          <span class="flex"><span>Chapter 2</span><span>Last Read</span></span>
          <time datetime="2026-11-20T10:00:00.000Z">Nov 20</time></a></div>
        <div x-data="{}"><a href="https://weebcentral.com/chapters/01JCH1">
          <span class="flex"><span>Chapter 1</span></span></a></div>''');
      final list = WeebCentral.parseChapters(doc, page, 'Weeb Central');
      expect(list.map((c) => c.number), [2, 1]);
      expect(list.first.name, 'Chapter 2');
      expect(list.first.uploadedAt?.year, 2026);
      expect(list.first.key, 'https://weebcentral.com/chapters/01JCH2');
    });

    test('pages', () {
      final page = Uri.parse('https://weebcentral.com/chapters/01JCH1/images');
      final doc = html_parser.parse('''
        <section x-data="{ scroll() {} }">
          <img src="https://hot.planeptune.us/manga/Double-Click/0001-001.png">
          <img src="https://hot.planeptune.us/manga/Double-Click/0001-002.png">
        </section>''');
      expect(WeebCentral.parsePages(doc, page), [
        'https://hot.planeptune.us/manga/Double-Click/0001-001.png',
        'https://hot.planeptune.us/manga/Double-Click/0001-002.png',
      ]);
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

  group('preloading a chapter', () {
    test('loads from the page you opened on, then the pages before it', () {
      expect(PagePrefetcher.prefetchOrder(6, 0), [0, 1, 2, 3, 4, 5]);
      expect(PagePrefetcher.prefetchOrder(6, 3), [3, 4, 5, 2, 1, 0]);
      // A saved page past the end (the chapter got shorter) is clamped.
      expect(PagePrefetcher.prefetchOrder(3, 9), [2, 1, 0]);
      expect(PagePrefetcher.prefetchOrder(0, 0), isEmpty);
    });

    test('loads every page of the chapter', () async {
      final loaded = <int>[];
      final p = PagePrefetcher(
          count: 8, start: 2, concurrency: 1, load: (i) async => loaded.add(i))
        ..start();
      await p.whenFinished;
      expect(loaded, [2, 3, 4, 5, 6, 7, 1, 0]);
      expect(p.done, {0, 1, 2, 3, 4, 5, 6, 7});
      expect(p.isFinished, isTrue);
    });

    test('runs only a few loads at a time', () async {
      var running = 0, peak = 0;
      final p = PagePrefetcher(
        count: 12,
        concurrency: 3,
        load: (i) async {
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          running--;
        },
      )..start();
      await p.whenFinished;
      expect(peak, 3);
      expect(p.done.length, 12);
    });

    test('a failing page does not stop the others', () async {
      final p = PagePrefetcher(
        count: 5,
        concurrency: 2,
        load: (i) async {
          if (i == 1) throw const SocketException('nope');
        },
      )..start();
      await p.whenFinished;
      expect(p.failed, {1});
      expect(p.done, {0, 2, 3, 4});
    });

    test('leaving the chapter stops loading (and records nothing more)',
        () async {
      final gates = <int, Completer<void>>{};
      final started = <int>[];
      final p = PagePrefetcher(
        count: 10,
        concurrency: 2,
        load: (i) {
          started.add(i);
          return (gates[i] = Completer<void>()).future;
        },
      )..start();
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1]);
      p.cancel();
      gates[0]!.complete();
      gates[1]!.completeError(Exception('late'));
      await p.whenFinished;
      expect(started, [0, 1], reason: 'no new pages after cancel');
      expect(p.done, isEmpty);
      expect(p.failed, isEmpty);
      expect(p.cancelled, isTrue);
    });

    test('cancelling before it starts finishes straight away', () async {
      var calls = 0;
      final p = PagePrefetcher(count: 4, load: (_) async => calls++)..cancel();
      p.start();
      await p.whenFinished;
      expect(calls, 0);
    });

    test('jumping ahead loads from the new page next', () async {
      final loaded = <int>[];
      late PagePrefetcher p;
      p = PagePrefetcher(
        count: 10,
        concurrency: 1,
        load: (i) async {
          loaded.add(i);
          if (i == 0) p.focus(7);
        },
      )..start();
      await p.whenFinished;
      expect(loaded.take(4), [0, 7, 8, 9]);
      expect(loaded.toSet().length, 10, reason: 'each page once');
    });
  });

  group('page cache', () {
    Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

    test('the page on screen and the prefetch share one download', () async {
      final cache = PageCache();
      var downloads = 0;
      final gate = Completer<Uint8List>();
      Future<Uint8List> load(String _) {
        downloads++;
        return gate.future;
      }

      final a = cache.get('p1', load);
      final b = cache.get('p1', load);
      gate.complete(bytes(10));
      expect((await a).length, 10);
      expect((await b).length, 10);
      expect(downloads, 1);
      // Saved: going back to it doesn't download again.
      await cache.get('p1', load);
      expect(downloads, 1);
      expect(cache.has('p1'), isTrue);
    });

    test('a failed page is tried again next time', () async {
      final cache = PageCache();
      var tries = 0;
      Future<Uint8List> load(String _) async {
        tries++;
        if (tries == 1) throw const SocketException('offline');
        return bytes(4);
      }

      await expectLater(cache.get('p', load), throwsA(isA<SocketException>()));
      expect(cache.has('p'), isFalse);
      expect((await cache.get('p', load)).length, 4);
      expect(tries, 2);
    });

    test('an empty image counts as failed', () async {
      final cache = PageCache();
      await expectLater(
          cache.get('p', (_) async => Uint8List(0)), throwsFormatException);
      expect(cache.has('p'), isFalse);
    });

    test('in memory, keeps within its budget (oldest dropped first)',
        () async {
      final cache = PageCache(memoryBudget: 25);
      for (final u in ['a', 'b', 'c']) {
        await cache.get(u, (_) async => bytes(10));
      }
      expect(cache.has('a'), isFalse);
      expect(cache.has('b'), isTrue);
      expect(cache.has('c'), isTrue);
      expect(cache.memoryBytes, 20);
    });

    test('keeps only the chapters you are near', () async {
      final cache = PageCache();
      for (final u in ['old1', 'old2', 'cur1']) {
        await cache.get(u, (_) async => bytes(3));
      }
      cache.retain(['cur1', 'cur2']);
      expect(cache.has('old1'), isFalse);
      expect(cache.has('old2'), isFalse);
      expect(cache.has('cur1'), isTrue);
      expect(cache.memoryBytes, 3);
    });

    test('on disk: saves pages as files and deletes them when closed',
        () async {
      final dir = await Directory.systemTemp.createTemp('pages');
      final cache = PageCache(dir: Future.value(dir));
      var downloads = 0;
      await cache.get('https://cdn.example.com/1.jpg', (_) async {
        downloads++;
        return bytes(16);
      });
      expect(cache.memoryBytes, 0, reason: 'not held in memory');
      expect(dir.listSync().length, 1);
      final again = await cache.get('https://cdn.example.com/1.jpg',
          (_) async => throw StateError('should come from disk'));
      expect(again.length, 16);
      expect(downloads, 1);

      await cache.dispose();
      expect(await dir.exists(), isFalse);
    });

    test('page images with the same url and attempt are the same image', () {
      final cache = PageCache();
      Future<Uint8List> load(String _) async => bytes(1);
      expect(CachedPageImage('u', cache, load),
          CachedPageImage('u', cache, (_) async => bytes(2)));
      expect(CachedPageImage('u', cache, load) == CachedPageImage('u', cache, load, attempt: 1),
          isFalse);
      expect(CachedPageImage('u', cache, load) == CachedPageImage('u', PageCache(), load),
          isFalse);
    });
  });
}
