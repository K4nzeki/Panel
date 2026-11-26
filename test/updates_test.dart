import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/services/mangadex.dart';

void main() {
  group('MangaDex latest chapter', () {
    test('takes the highest chapter across volumes, rounded down', () {
      final json = {
        'result': 'ok',
        'volumes': {
          '1': {
            'chapters': {'1': {}, '2': {}, '10': {}}
          },
          'none': {
            'chapters': {'120.5': {}, '119': {}, 'extra': {}}
          },
        },
      };
      expect(MangaDexService.parseLatest(json), 120);
    });

    test('no chapters comes back as an empty list', () {
      expect(MangaDexService.parseLatest({'volumes': []}), isNull);
    });
  });

  group('title matching', () {
    final m = MangaDexService.parseManga({
      'id': 'abc',
      'attributes': {
        'title': {'en': 'Solo Leveling'},
        'altTitles': [
          {'ko': '나 혼자만 레벨업'},
          {'en': 'Only I Level Up'},
        ],
        'status': 'completed',
      },
      'relationships': [
        {
          'type': 'cover_art',
          'attributes': {'fileName': 'cover.png'}
        }
      ],
    });

    test('ignores case and punctuation, checks alt titles', () {
      expect(m.matchesTitle('solo leveling!'), isTrue);
      expect(m.matchesTitle('Only I Level Up'), isTrue);
      expect(m.matchesTitle('Solo Leveling: Ragnarok'), isFalse);
    });

    test('builds the cover url and source id', () {
      expect(m.coverUrl,
          'https://uploads.mangadex.org/covers/abc/cover.png.512.jpg');
      expect(m.sourceId, 'mangadex:abc');
      expect(MangaDexService.idFrom(m.sourceId), 'abc');
      expect(MangaDexService.idFrom(noSourceFound), isNull);
    });
  });

  group('New badge', () {
    Entry e({int chapter = 10, int? latest, EntryStatus? status}) => Entry(
          id: '1',
          title: 'X',
          type: EntryType.manhwa,
          status: status ?? EntryStatus.reading,
          chapter: chapter,
          latestChapter: latest,
          sourceId: 'mangadex:abc',
        );

    test('shows when the source is ahead of you', () {
      expect(e(latest: 13).unreadChapters, 3);
      expect(e(latest: 13).hasNewChapters, isTrue);
    });

    test('hidden when caught up, unknown, or not reading', () {
      expect(e(latest: 10).hasNewChapters, isFalse);
      expect(e(latest: 8).hasNewChapters, isFalse);
      expect(e().hasNewChapters, isFalse);
      expect(e(latest: 13, status: EntryStatus.dropped).hasNewChapters, isFalse);
    });
  });
}
