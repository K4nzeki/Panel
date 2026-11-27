import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/services/local_store.dart';
import 'package:panel/utils/dates.dart';
import 'package:shared_preferences/shared_preferences.dart';

Entry entry({int chapter = 0, int reread = 0, int banked = 0, int overlap = 0}) =>
    Entry(
      id: 'e1',
      title: 'Solo Leveling',
      type: EntryType.manhwa,
      status: EntryStatus.reading,
      chapter: chapter,
      reread: reread,
      chaptersBanked: banked,
      rereadOverlap: overlap,
    );

/// Applies a change the way EntriesNotifier.save does.
Entry change(Entry before, Entry after) => withChapterAccounting(before, after);

Future<int> today() async =>
    (await LocalStore.chaptersPerDay(days: 1)).single.chapters;

void main() {
  group('chapters counted on Stats', () {
    test('lowering the chapter takes the difference off', () {
      final a = entry(chapter: 50);
      final b = change(a, a.copyWith(chapter: 45));
      expect(b.chaptersCounted, 45);
    });

    test('adding a reread does not count the chapters twice', () {
      final a = entry(chapter: 50);
      final b = change(a, a.copyWith(reread: 1));
      expect(b.chaptersCounted, 50);
    });

    test('reread, then clearing the count keeps what was read', () {
      final a = entry(chapter: 50);
      final b = change(a, a.copyWith(reread: 1));
      final cleared = change(b, b.copyWith(chapter: 0));
      expect(cleared.chaptersCounted, 50);
      // Reading it again adds on top.
      final again = change(cleared, cleared.copyWith(chapter: 30));
      expect(again.chaptersCounted, 80);
      // A −1 fix during the reread takes one off.
      expect(change(again, again.copyWith(chapter: 29)).chaptersCounted, 79);
    });

    test('reread and clear in one change keeps the total', () {
      final a = entry(chapter: 50);
      final b = change(a, a.copyWith(reread: 1, chapter: 0));
      expect(b.chaptersCounted, 50);
    });

    test('reading on past the reread point without clearing counts once', () {
      final a = entry(chapter: 50);
      final b = change(a, a.copyWith(reread: 1));
      expect(change(b, b.copyWith(chapter: 55)).chaptersCounted, 55);
    });

    test('removing a reread keeps the total', () {
      final a = entry(chapter: 50);
      final b = change(a, a.copyWith(reread: 1));
      final c = change(b, b.copyWith(reread: 0));
      expect(c.chaptersCounted, 50);
      expect(c.rereadOverlap, 0);
    });

    test('survives a save / load round trip', () {
      final e = entry(chapter: 3, reread: 1, banked: 50, overlap: 0);
      final back = Entry.fromJson(e.toJson());
      expect(back.chaptersBanked, 50);
      expect(back.chaptersCounted, 53);
      // Older saves have no banked chapters.
      expect(Entry.fromJson({'id': 'x', 'chapter': 7}).chaptersCounted, 7);
    });

    test('new-chapter patches can never touch the banked chapters', () {
      final p = LocalStore.withoutProgress(
          {'chapters_banked': 0, 'reread_overlap': 0, 'latest_chapter': 9});
      expect(p, {'latest_chapter': 9});
    });
  });

  group('chapters per day', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('lowering the chapter takes it back off the day it was read',
        () async {
      final a = entry(chapter: 0);
      final b = a.copyWith(chapter: 10);
      await LocalStore.recordActivity(a, b, {'chapter': 10});
      expect(await today(), 10);
      await LocalStore.recordActivity(b, b.copyWith(chapter: 7), {'chapter': 7});
      expect(await today(), 7);
    });

    test('a reread keeps the days when the count is cleared', () async {
      final a = entry(chapter: 0);
      final b = a.copyWith(chapter: 10);
      await LocalStore.recordActivity(a, b, {'chapter': 10});
      final c = b.copyWith(reread: 1);
      await LocalStore.recordActivity(b, c, {'reread': 1});
      await LocalStore.recordActivity(c, c.copyWith(chapter: 0), {'chapter': 0});
      expect(await today(), 10);
    });

    test('deleting a title takes its chapters off; undo puts them back',
        () async {
      final a = entry(chapter: 0);
      await LocalStore.recordActivity(a, a.copyWith(chapter: 12), {'chapter': 12});
      final other = Entry(
          id: 'e2', title: 'Other', type: EntryType.manga, status: EntryStatus.reading);
      await LocalStore.recordActivity(
          other, other.copyWith(chapter: 3), {'chapter': 3});
      expect(await today(), 15);

      final log = await LocalStore.forgetEntry('e1');
      expect(await today(), 3);
      expect(log, isNotNull);

      await LocalStore.restoreEntry('e1', log!);
      expect(await today(), 15);
    });

    test('old activity without per-title data still loads', () async {
      SharedPreferences.setMockInitialValues({
        'activity_local_v1': '{"days":{"${localDayKey()}":4},"months":{}}',
      });
      expect(await today(), 4);
      expect(await LocalStore.forgetEntry('e1'), isNull);
      expect(await today(), 4);
    });
  });
}
