import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/state/providers.dart';
import 'package:panel/widgets/common.dart';

class FakeEntries extends EntriesNotifier {
  FakeEntries(this.initial);
  final List<Entry> initial;

  @override
  Future<List<Entry>> build() async => initial;

  void replace(List<Entry> list) => state = AsyncData(list);
}

Entry entry(String id, String title, {int chapter = 0}) => Entry(
      id: id,
      title: title,
      type: EntryType.manhwa,
      status: EntryStatus.reading,
      chapter: chapter,
    );

void main() {
  group('cover decode size', () {
    test('matches the drawn size, with a little headroom, in steps of 64', () {
      // 150 px wide grid cell at 3x: 450 px drawn → 563 → 576.
      expect(CoverImage.decodeWidth(150, 3), 576);
      expect(CoverImage.decodeWidth(50, 2), 128);
      // Similar sizes share one decoded image.
      expect(CoverImage.decodeWidth(148, 3), CoverImage.decodeWidth(150, 3));
    });

    test('never tiny, never huge', () {
      expect(CoverImage.decodeWidth(4, 1), 64);
      expect(CoverImage.decodeWidth(4000, 3), 1024);
    });

    test('full size when the width is unknown', () {
      expect(CoverImage.decodeWidth(null, 3), isNull);
      expect(CoverImage.decodeWidth(double.infinity, 3), isNull);
      expect(CoverImage.decodeWidth(0, 3), isNull);
    });
  });

  group('library titles (Discover "already added")', () {
    test('ignore reading progress; follow added and renamed titles', () async {
      final fake = FakeEntries([entry('a', 'Solo Leveling')]);
      final c = ProviderContainer(
          overrides: [entriesProvider.overrideWith(() => fake)]);
      addTearDown(c.dispose);
      await c.read(entriesProvider.future);

      final first = c.read(libraryTitlesProvider);
      expect(first, {'solo leveling'});

      // Reading (chapter count, "last read"): same set, nothing rebuilds.
      fake.replace([
        entry('a', 'Solo Leveling', chapter: 5)
            .copyWith(lastReadAt: DateTime(2026)),
      ]);
      expect(identical(c.read(libraryTitlesProvider), first), isTrue);

      fake.replace([
        entry('a', 'Solo Leveling', chapter: 5),
        entry('b', '  Omniscient Reader '),
      ]);
      expect(c.read(libraryTitlesProvider),
          {'solo leveling', 'omniscient reader'});

      fake.replace(const []);
      expect(c.read(libraryTitlesProvider), isEmpty);
    });
  });
}
