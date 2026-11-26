import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/reader.dart';
import 'package:panel/state/providers.dart';
import 'package:panel/state/reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> container([Map<String, Object> saved = const {}]) async {
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('default reading mode by type', () {
    test('manga reads right to left', () {
      expect(defaultReadingMode('manga'), ReadingMode.pagedRtl);
      expect(defaultReadingMode('Manga'), ReadingMode.pagedRtl);
      expect(defaultReadingMode(' MANGA '), ReadingMode.pagedRtl);
    });

    test('manhwa, manhua and webtoons read as a long strip', () {
      for (final t in ['manhwa', 'Manhwa', 'manhua', 'MANHUA', 'webtoon', 'Webtoon']) {
        expect(defaultReadingMode(t), ReadingMode.longStrip, reason: t);
      }
    });

    test('anything else reads left to right', () {
      for (final t in ['comic', 'Comic', 'novel', '', null]) {
        expect(defaultReadingMode(t), ReadingMode.pagedLtr, reason: '$t');
      }
    });
  });

  test('modes round-trip through their saved key', () {
    for (final m in ReadingMode.values) {
      expect(ReadingMode.fromKey(m.key), m);
    }
    expect(ReadingMode.fromKey('sideways'), isNull);
    expect(ReadingMode.fromKey(null), isNull);
    expect(ReadingMode.longStrip.paged, isFalse);
    expect(ReadingMode.pagedRtl.paged, isTrue);
  });

  group('picked modes', () {
    test('are saved per title and read back', () async {
      final c = await container();
      c.read(readingModesProvider.notifier).set('e1', ReadingMode.longStrip);
      expect(c.read(readingModesProvider), {'e1': ReadingMode.longStrip});

      final prefs = c.read(sharedPrefsProvider);
      final again = await container(
          {'reading_modes_v1': prefs.getString('reading_modes_v1')!});
      expect(again.read(readingModesProvider)['e1'], ReadingMode.longStrip);
      expect(again.read(readingModesProvider)['e2'], isNull);
    });

    test('override the default; clearing goes back to it', () async {
      final c = await container();
      // No library loaded: unknown type, so left to right.
      expect(c.read(readingModeProvider('e1')), ReadingMode.pagedLtr);
      c.read(readingModesProvider.notifier).set('e1', ReadingMode.pagedRtl);
      expect(c.read(readingModeProvider('e1')), ReadingMode.pagedRtl);
      c.read(readingModesProvider.notifier).set('e1', null);
      expect(c.read(readingModeProvider('e1')), ReadingMode.pagedLtr);
    });

    test('ignore unreadable saved data', () async {
      final c = await container({'reading_modes_v1': '{"e1":"bogus","e2":"long_strip"}'});
      expect(c.read(readingModesProvider), {'e2': ReadingMode.longStrip});
      final broken = await container({'reading_modes_v1': 'not json'});
      expect(broken.read(readingModesProvider), isEmpty);
    });
  });
}
