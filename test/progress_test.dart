import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/models/reader.dart';
import 'package:panel/services/local_store.dart';
import 'package:panel/state/providers.dart';
import 'package:panel/state/reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The library without storage or network: records what the reader asks.
class FakeEntries extends EntriesNotifier {
  FakeEntries([this.initial = const []]);
  final List<Entry> initial;
  final readUpTo = <(String, int)>[];

  @override
  Future<List<Entry>> build() async => initial;

  @override
  Future<void> markReadUpTo(String entryId, int number) async =>
      readUpTo.add((entryId, number));
}

Future<(ProviderContainer, FakeEntries)> container(
    [Map<String, Object> saved = const {}]) async {
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final fake = FakeEntries();
  final c = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
    entriesProvider.overrideWith(() => fake),
  ]);
  addTearDown(c.dispose);
  return (c, fake);
}

Entry entry({int chapter = 0, int? total, int? latest}) => Entry(
      id: 'e1',
      title: 'Solo Leveling',
      type: EntryType.manhwa,
      status: EntryStatus.reading,
      chapter: chapter,
      totalChapters: total,
      latestChapter: latest,
    );

ChapterInfo ch(String key, double? n) =>
    ChapterInfo(key: key, name: 'Chapter $n', number: n, scanlator: 'A');

ReadingLink link({
  String? lastKey,
  double? lastN,
  int page = 0,
  double offset = 0,
  bool finished = false,
}) =>
    ReadingLink(
      sourceId: 'mangadex',
      sourceName: 'MangaDex',
      seriesKey: 's',
      seriesTitle: 'Solo Leveling',
      lastChapterKey: lastKey,
      lastChapterNumber: lastN,
      lastPage: page,
      lastPageOffset: offset,
      lastPageCount: 20,
      lastFinished: finished,
    );

void main() {
  group('a new chapter coming out', () {
    test('moves only the newest chapter, never chapters read', () {
      final before = entry(chapter: 10, latest: 10);
      // What the update check / reader chapter list saves.
      final after = LocalStore.applyPatch(before, {'latest_chapter': 11});
      expect(after.chapter, 10);
      expect(after.latestChapter, 11);
      expect(after.unreadChapters, 1);
    });

    test('a stray chapter / status in a new-chapter patch is dropped', () {
      final patch = LocalStore.withoutProgress({
        'latest_chapter': 11,
        'chapter': 11,
        'status': 'Finished',
      });
      expect(patch, {'latest_chapter': 11});
      final patched = LocalStore.applyPatches([entry(chapter: 10)], {
        'e1': {'latest_chapter': 11, 'chapter': 11},
      });
      expect(patched.single.chapter, 10);
      expect(patched.single.latestChapter, 11);
    });

    test('does not count as chapters read in Stats', () {
      final before = entry(chapter: 10, latest: 10);
      final after = before.copyWith(latestChapter: const Nullable(11));
      expect(
          LocalStore.chaptersReadDelta(before, after, {'latest_chapter': 11}), 0);
      final total = before.copyWith(totalChapters: const Nullable(11));
      expect(LocalStore.chaptersReadDelta(before, total, {'total_chapters': 11}),
          0);
    });
  });

  group('chapters read in Stats', () {
    test('counts how far the chapter moved forward', () {
      final before = entry(chapter: 10);
      expect(
          LocalStore.chaptersReadDelta(
              before, before.copyWith(chapter: 13), {'chapter': 13}),
          3);
    });

    test('going back (a −1 fix) counts nothing', () {
      final before = entry(chapter: 50);
      // Used to log 49 chapters "read today".
      expect(
          LocalStore.chaptersReadDelta(
              before, before.copyWith(chapter: 49), {'chapter': 49}),
          0);
    });
  });

  group('progress', () {
    test('read / total', () {
      expect(entry(chapter: 25, total: 100).progress, 0.25);
    });

    test('a new chapter grows the total, not the chapters read', () {
      final e = entry(chapter: 10, total: 10, latest: 11);
      expect(e.knownChapters, 11);
      expect(e.chapter, 10);
      expect(e.progress, closeTo(10 / 11, 1e-9));
    });

    test('ongoing series with no total uses the newest chapter', () {
      final e = entry(chapter: 30, latest: 120);
      expect(e.knownChapters, 120);
      expect(e.progress, 0.25);
    });

    test('unknown when neither is known', () {
      expect(entry(chapter: 5).progress, isNull);
      expect(entry(chapter: 5).knownChapters, isNull);
    });
  });

  group('saved reading spot', () {
    test('survives a save / load round trip (page + offset)', () {
      final l = link(lastKey: 'c12', lastN: 12, page: 3, offset: 0.4);
      final back = ReadingLink.fromJson(l.toJson())!;
      expect(back.lastChapterKey, 'c12');
      expect(back.lastChapterNumber, 12);
      expect(back.lastPage, 3);
      expect(back.lastPageOffset, 0.4);
    });

    test('older saves without an offset load as the top of the page', () {
      final json = link(lastKey: 'c1', lastN: 1, page: 2).toJson()
        ..remove('last_page_offset');
      expect(ReadingLink.fromJson(json)!.lastPageOffset, 0);
    });

    test('resume opens the exact page and offset', () {
      final list = [ch('c3', 3), ch('c2', 2), ch('c1', 1)];
      final t = resolveResume(entry(chapter: 1),
          link(lastKey: 'c2', lastN: 2, page: 7, offset: 0.6), list)!;
      expect(t.chapter.key, 'c2');
      expect(t.page, 7);
      expect(t.offset, 0.6);
    });
  });

  group('read button', () {
    final list = [ch('c3', 3), ch('c2', 2), ch('c1', 1)];

    test('new series', () {
      expect(readButtonLabel(entry(), link(), list), 'Start Reading');
      expect(readButtonLabel(entry(), null, const []), 'Start Reading');
    });

    test('mid-chapter', () {
      expect(
          readButtonLabel(
              entry(chapter: 1), link(lastKey: 'c2', lastN: 2, page: 3), list),
          'Continue Reading: Ch. 2, Page 4');
    });

    test('finished a chapter: names the next one', () {
      expect(
          readButtonLabel(entry(chapter: 2),
              link(lastKey: 'c2', lastN: 2, finished: true), list),
          'Continue Reading: Ch. 3, Page 1');
    });

    test('without the chapter list, uses the bookmark', () {
      expect(
          readButtonLabel(entry(chapter: 1),
              link(lastKey: 'c2', lastN: 2, page: 3), const []),
          'Continue Reading: Ch. 2, Page 4');
    });

    test('caught up', () {
      expect(readButtonLabel(entry(chapter: 3), link(), list),
          'Caught up · Ch. 3');
    });
  });

  group('finishing a chapter in the reader', () {
    test('records it and moves the library forward, once', () async {
      final (c, library) = await container();
      final chapters = c.read(readChaptersProvider.notifier);
      final ch12 = ch('c12', 12);

      expect(chapters.finish('e1', ch12), isTrue);
      expect(chapters.isRead('e1', 'c12'), isTrue);
      expect(library.readUpTo, [('e1', 12)]);

      // Last page again, scrolling past the end, "Next chapter": no repeats.
      expect(chapters.finish('e1', ch12), isFalse);
      expect(chapters.finish('e1', ch12), isFalse);
      expect(library.readUpTo, [('e1', 12)]);
    });

    test('extras count as the chapter before them (12.5 → 12)', () async {
      final (c, library) = await container();
      c.read(readChaptersProvider.notifier).finish('e1', ch('c12.5', 12.5));
      expect(library.readUpTo, [('e1', 12)]);
    });

    test('a chapter without a number is still recorded as read', () async {
      final (c, library) = await container();
      final chapters = c.read(readChaptersProvider.notifier);
      expect(chapters.finish('e1', ch('oneshot', null)), isTrue);
      expect(chapters.isRead('e1', 'oneshot'), isTrue);
      expect(library.readUpTo, isEmpty);
    });

    test('kept per title', () async {
      final (c, _) = await container();
      final chapters = c.read(readChaptersProvider.notifier);
      chapters.finish('e1', ch('c1', 1));
      expect(chapters.isRead('e2', 'c1'), isFalse);
      expect(chapters.finish('e2', ch('c1', 1)), isTrue);
    });

    test('survives closing the app, and still does not repeat', () async {
      final (c, _) = await container();
      c.read(readChaptersProvider.notifier).finish('e1', ch('c3', 3));
      final saved =
          c.read(sharedPrefsProvider).getString('read_chapters_v1')!;

      final (again, library) = await container({'read_chapters_v1': saved});
      final chapters = again.read(readChaptersProvider.notifier);
      expect(chapters.isRead('e1', 'c3'), isTrue);
      expect(chapters.finish('e1', ch('c3', 3)), isFalse);
      expect(library.readUpTo, isEmpty);
    });

    test('ignores unreadable saved data', () async {
      final (c, _) = await container({'read_chapters_v1': 'not json'});
      expect(c.read(readChaptersProvider), isEmpty);
      final (d, _) =
          await container({'read_chapters_v1': '{"e1":["c1",4],"e2":"x"}'});
      expect(d.read(readChaptersProvider), {
        'e1': {'c1'}
      });
    });

    test('the reader bookmark stays finished after scrolling back up',
        () async {
      // A linked title (no source lookups needed for saving progress).
      final (c, _) = await container({
        'reading_links_v1': jsonEncode({'e1': link().toJson()}),
      });
      final links = c.read(readingLinksProvider.notifier);
      final ch2 = ch('c2', 2);
      links.saveProgress('e1', ch2, page: 19, pageCount: 20, finished: true);
      links.saveProgress('e1', ch2, page: 4, pageCount: 20);
      final l = c.read(readingLinksProvider)['e1']!;
      expect(l.lastFinished, isTrue);
      expect(l.lastChapterKey, 'c2');
    });
  });
}
