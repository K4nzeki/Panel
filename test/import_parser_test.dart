import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/utils/dates.dart';
import 'package:panel/utils/import_parser.dart';

void main() {
  group('parsePipeLine', () {
    test('parses a full line', () {
      final p = parsePipeLine('Solo Leveling | 120 | Reading | Manhwa | 1')!;
      expect(p.title, 'Solo Leveling');
      expect(p.chapter, 120);
      expect(p.status, EntryStatus.reading);
      expect(p.type, EntryType.manhwa);
      expect(p.reread, 1);
    });

    test('rejects bad values', () {
      expect(parsePipeLine('X | abc | Reading | Manga | 0'), isNull);
      expect(parsePipeLine('X | 1 | Nope | Manga | 0'), isNull);
      expect(parsePipeLine('X | 1 | Reading'), isNull);
    });
  });

  group('parseSpaceLine', () {
    test('title may contain spaces', () {
      final r = parseSpaceLine('One Piece Colored 1100 Finished Manga 0');
      expect(r.error, isNull);
      expect(r.entry!.title, 'One Piece Colored');
      expect(r.entry!.status, EntryStatus.finished);
    });

    test('handles the two-word "To Read" status', () {
      final r = parseSpaceLine('Berserk 0 To Read Manga 0');
      expect(r.error, isNull);
      expect(r.entry!.title, 'Berserk');
      expect(r.entry!.status, EntryStatus.toRead);
    });

    test('explains what is wrong', () {
      expect(parseSpaceLine('Berserk 10 Reading Novel 0').error,
          contains('unknown type'));
      expect(parseSpaceLine('too short').error, isNotNull);
    });
  });

  test('parseImportText collects entries and errors', () {
    final r = parseImportText('''
# comment
Solo Leveling | 120 | Reading | Manhwa | 0
Berserk 10 Reading Manga 0

broken line
''');
    expect(r.entries.length, 2);
    expect(r.errors.length, 1);
  });

  test('export round-trips through the pipe parser', () {
    const e = Entry(
      id: '1',
      title: 'Vagabond',
      type: EntryType.manga,
      status: EntryStatus.dropped,
      chapter: 300,
      reread: 2,
    );
    final p = parsePipeLine(exportPipeLines([e]))!;
    expect(p.title, e.title);
    expect(p.status, e.status);
    expect(p.chapter, 300);
    expect(p.reread, 2);
  });

  test('legacy "Ongoing" status maps to Reading', () {
    expect(EntryStatus.parse('Ongoing'), EntryStatus.reading);
  });

  test('progress is clamped and null without a total', () {
    const a = Entry(
        id: 'a', title: 'A', type: EntryType.manga, status: EntryStatus.reading,
        chapter: 50, totalChapters: 100);
    const b = Entry(
        id: 'b', title: 'B', type: EntryType.manga, status: EntryStatus.reading,
        chapter: 50);
    const c = Entry(
        id: 'c', title: 'C', type: EntryType.manga, status: EntryStatus.reading,
        chapter: 150, totalChapters: 100);
    expect(a.progress, 0.5);
    expect(b.progress, isNull);
    expect(c.progress, 1.0);
  });

  test('date keys use the local calendar', () {
    expect(localDayKey(DateTime(2026, 3, 7)), '2026-03-07');
    expect(localMonthKey(DateTime(2026, 11, 30)), '2026-11-01');
  });
}
