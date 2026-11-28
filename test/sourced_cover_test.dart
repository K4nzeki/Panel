import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/services/cover_cache.dart';
import 'package:panel/services/mangadex.dart';
import 'package:panel/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real notifier, minus loading the list from the phone and the
/// background refresh it starts.
class _Entries extends EntriesNotifier {
  _Entries(this.initial);
  final List<Entry> initial;

  @override
  Future<List<Entry>> build() async => initial;
}

const _old = 'https://uploads.mangadex.org/covers/abc/old.jpg.512.jpg';
const _new = 'https://uploads.mangadex.org/covers/abc/new.jpg.512.jpg';

Entry _entry({String? cover, String? sourceId = 'mangadex:abc'}) => Entry(
      id: 'e1',
      title: 'Solo Leveling',
      type: EntryType.manhwa,
      status: EntryStatus.reading,
      chapter: 3,
      coverUrl: cover,
      sourceId: sourceId,
    );

/// MangaDex answering with series "abc" whose cover file is [file].
/// [aggregateGate] holds back the newest-chapter answer.
MockClient _mangaDex(String file, {Completer<void>? aggregateGate}) =>
    MockClient((req) async {
      if (req.url.path.endsWith('/aggregate')) {
        await aggregateGate?.future;
        return http.Response(
            jsonEncode({
              'volumes': {
                'none': {
                  'chapters': {'40': {}}
                }
              }
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'result': 'ok',
            'data': {
              'id': 'abc',
              'attributes': {
                'title': {'en': 'Solo Leveling'}
              },
              'relationships': [
                {
                  'id': 'c1',
                  'type': 'cover_art',
                  'attributes': {'fileName': file}
                }
              ],
            },
          }),
          200);
    });

Future<(ProviderContainer, EntriesNotifier)> _setup(Entry e,
    {required MockClient mangaDex}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
    mangaDexProvider.overrideWithValue(MangaDexService(client: mangaDex)),
    entriesProvider.overrideWith(() => _Entries([e])),
  ]);
  addTearDown(c.dispose);
  await c.read(entriesProvider.future);
  return (c, c.read(entriesProvider.notifier));
}

Entry _current(ProviderContainer c) => c.read(entriesProvider).value!.single;

void main() {
  setUp(() {
    CoverCache.resetForTest();
    // Saving covers on the phone after a change: answered locally.
    CoverCache.client = MockClient((_) async => http.Response.bytes(
        Uint8List.fromList(const [1, 2, 3]), 200,
        headers: {'content-type': 'image/jpeg'}));
  });
  tearDown(CoverCache.resetForTest);

  group('which titles need their cover looked up', () {
    test('no cover, or a broken one', () {
      expect(coverNeedsLookup(_entry()), isTrue);
      expect(coverNeedsLookup(_entry(cover: '  ')), isTrue);
      expect(coverNeedsLookup(_entry(cover: _old), broken: true), isTrue);
      expect(coverNeedsLookup(_entry(cover: _old)), isFalse);
    });

    test('a MangaDex cover that cannot belong to the linked series', () {
      for (final bad in [
        'https://uploads.mangadex.org/covers/abc/.512.jpg',
        'https://uploads.mangadex.org/covers/zzz/x.jpg.512.jpg',
      ]) {
        expect(coverNeedsLookup(_entry(cover: bad), mangaDexId: 'abc'), isTrue,
            reason: bad);
      }
      expect(coverNeedsLookup(_entry(cover: _old), mangaDexId: 'abc'), isFalse);
      // A cover from elsewhere is fine on a MangaDex-linked title.
      expect(
          coverNeedsLookup(_entry(cover: 'https://s4.anilist.co/x.jpg'),
              mangaDexId: 'abc'),
          isFalse);
    });

    test('old MangaDex link forms are fixed without a lookup', () {
      expect(
          repairedMangaDexCover(
              _entry(cover: 'http://mangadex.org/covers/abc/old.jpg.512.jpg'),
              'abc'),
          _old);
      expect(repairedMangaDexCover(_entry(cover: _old), 'abc'), isNull);
    });
  });

  group('titles with a source get their cover', () {
    test('a MangaDex-linked title with no cover gets the series cover',
        () async {
      final (c, n) = await _setup(_entry(), mangaDex: _mangaDex('new.jpg'));
      await n.fillCoverFromSource('e1');
      expect(_current(c).coverUrl, _new);
    });

    test('a cover the source already showed is used as is', () async {
      var asked = 0;
      final (c, n) = await _setup(_entry(),
          mangaDex: MockClient((_) async {
            asked++;
            return http.Response('{}', 500);
          }));
      await n.fillCoverFromSource('e1', known: _new);
      expect(_current(c).coverUrl, _new);
      expect(asked, 0);
    });

    test('a working cover is never replaced', () async {
      final (c, n) =
          await _setup(_entry(cover: _old), mangaDex: _mangaDex('new.jpg'));
      await n.fillCoverFromSource('e1', known: _new);
      expect(_current(c).coverUrl, _old);
    });

    test('a broken cover is replaced from the source, once', () async {
      final (c, n) =
          await _setup(_entry(cover: _old), mangaDex: _mangaDex('new.jpg'));
      CoverCache.client = MockClient((req) async => req.url.toString() == _old
          ? http.Response('', 404)
          : http.Response.bytes(Uint8List.fromList(const [1]), 200,
              headers: {'content-type': 'image/jpeg'}));
      await expectLater(CoverCache.bytes(_old), throwsA(anything));
      expect(CoverCache.isBroken(_old), isTrue);

      await n.fillCoverFromSource('e1');
      expect(_current(c).coverUrl, _new);
    });

    test('a title already in the list takes a search result cover', () async {
      final (c, n) =
          await _setup(_entry(sourceId: null), mangaDex: _mangaDex('x.jpg'));
      n.adoptCover('e1', 'https://s4.anilist.co/cover.jpg');
      expect(_current(c).coverUrl, 'https://s4.anilist.co/cover.jpg');
      n.adoptCover('e1', 'https://s4.anilist.co/other.jpg');
      expect(_current(c).coverUrl, 'https://s4.anilist.co/cover.jpg');
    });
  });

  group('linking to a MangaDex series', () {
    test("doesn't overwrite what changed while MangaDex answered", () async {
      final gate = Completer<void>();
      final start = _entry(sourceId: null);
      final (c, n) = await _setup(start,
          mangaDex: _mangaDex('new.jpg', aggregateGate: gate));

      // Linked from the source picker with no cover in the result...
      final linking = n.linkSource(
          start, const SourceManga(id: 'abc', title: 'Solo Leveling'),
          keepCover: true);
      // ...meanwhile the reading source's cover arrives and a chapter is read.
      await n.fillCoverFromSource('e1', known: _old);
      await n.setChapter(_current(c), 7);
      gate.complete();
      await linking;

      final e = _current(c);
      expect(e.sourceId, 'mangadex:abc');
      expect(e.latestChapter, 40);
      expect(e.coverUrl, _old, reason: 'cover found meanwhile is kept');
      expect(e.chapter, 7, reason: 'progress made meanwhile is kept');
    });

    test('a result without a cover still ends with the series cover',
        () async {
      final start = _entry(sourceId: null);
      final (c, n) = await _setup(start, mangaDex: _mangaDex('new.jpg'));
      await n.linkSource(
          start, const SourceManga(id: 'abc', title: 'Solo Leveling'));
      expect(_current(c).coverUrl, _new);
    });
  });
}
