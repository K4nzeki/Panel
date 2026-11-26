import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/utils/import_merge.dart';
import 'package:panel/utils/import_parser.dart';
import 'package:panel/utils/sheet_import.dart';

ParsedEntry p(String title, int chapter,
        {EntryStatus status = EntryStatus.reading, int reread = 0}) =>
    ParsedEntry(
        title: title,
        type: EntryType.manhwa,
        status: status,
        chapter: chapter,
        reread: reread);

Entry e(String id, String title, int chapter) => Entry(
    id: id,
    title: title,
    type: EntryType.manhwa,
    status: EntryStatus.reading,
    chapter: chapter);

void main() {
  group('planImport', () {
    test('new titles are added', () {
      final plan = planImport([], [p('Solo Leveling', 10)]);
      expect(plan.toAdd.single.title, 'Solo Leveling');
      expect(plan.toUpdate, isEmpty);
    });

    test('same title with same or fewer chapters is skipped', () {
      final plan = planImport(
          [e('1', 'Solo Leveling', 50)], [p('solo leveling', 50), p('Omniscient Reader!', 3)]);
      expect(plan.skipped, 1);
      expect(plan.toAdd.single.title, 'Omniscient Reader!');
      final plan2 = planImport([e('1', 'Solo Leveling', 50)], [p('Solo  Leveling', 20)]);
      expect(plan2.isEmpty, isTrue);
      expect(plan2.skipped, 1);
    });

    test('same title with more chapters updates the existing one', () {
      final plan = planImport([e('1', 'Solo Leveling', 50)], [p('Solo Leveling', 120)]);
      expect(plan.toAdd, isEmpty);
      expect(plan.toUpdate.single.existing.id, '1');
      expect(plan.toUpdate.single.incoming.chapter, 120);
    });

    test('repeats inside the file keep the higher chapter', () {
      final plan = planImport([], [p('Tower of God', 30), p('tower of god', 80)]);
      expect(plan.toAdd.single.chapter, 80);
      expect(plan.mergedInFile, 1);
    });

    test('existing duplicates compare against the one furthest along', () {
      final plan = planImport(
          [e('a', 'Berserk', 10), e('b', 'Berserk', 90)], [p('Berserk', 50)]);
      expect(plan.isEmpty, isTrue);
    });
  });

  group('parseSheetRows', () {
    test('reads header columns in any order, with defaults', () {
      final r = parseSheetRows([
        ['Chapter', 'Title', 'Status'],
        ['120', 'Solo Leveling', 'Completed'],
        ['', 'Berserk', ''],
        [],
      ]);
      expect(r.errors, isEmpty);
      expect(r.entries.length, 2);
      expect(r.entries[0].status, EntryStatus.finished);
      expect(r.entries[0].type, EntryType.manga);
      expect(r.entries[1].chapter, 0);
      expect(r.entries[1].status, EntryStatus.reading);
    });

    test('no header means Title, Chapter, Status, Type, Reread', () {
      final r = parseSheetRows([
        ['Solo Leveling', '120.0', 'Reading', 'Manhwa', '1'],
        ['Berserk', 'Ch. 300', 'Plan to Read', 'Manga'],
      ]);
      expect(r.entries[0].chapter, 120);
      expect(r.entries[0].reread, 1);
      expect(r.entries[1].chapter, 300);
      expect(r.entries[1].status, EntryStatus.toRead);
    });

    test('reports bad rows with Excel row numbers', () {
      final r = parseSheetRows([
        ['Title', 'Type'],
        ['X', 'Novel'],
      ]);
      expect(r.errors.single, contains('Row 2'));
    });
  });

  test('parseCsv handles quotes and semicolons', () {
    expect(parseCsv('Title;Chapter\r\n"A; B";3\n"Say ""hi""";4'), [
      ['Title', 'Chapter'],
      ['A; B', '3'],
      ['Say "hi"', '4'],
    ]);
  });
}
