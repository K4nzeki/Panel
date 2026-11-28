import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:panel/services/mangadex.dart';
import 'package:panel/services/sources/mangadex_source.dart';

Map<String, dynamic> manga(String id, List<Map<String, dynamic>> rels) => {
      'id': id,
      'type': 'manga',
      'attributes': {
        'title': {'en': 'Solo Leveling'},
      },
      'relationships': rels,
    };

http.Response reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

void main() {
  group('cover url from the API response', () {
    test('uses the cover_art fileName with the 512 thumbnail', () {
      final m = MangaDexService.parseManga(manga('abc', [
        {'type': 'author', 'attributes': {'name': 'Chugong'}},
        {
          'id': 'c1',
          'type': 'cover_art',
          'attributes': {'fileName': 'f1e2.jpg'}
        },
      ]));
      expect(m.coverUrl, 'https://uploads.mangadex.org/covers/abc/f1e2.jpg.512.jpg');
    });

    test('no cover when the relationship has no (or an empty) file name', () {
      for (final rel in <Map<String, dynamic>>[
        {'id': 'c1', 'type': 'cover_art'}, // not expanded (no includes[])
        {'id': 'c1', 'type': 'cover_art', 'attributes': {'fileName': ''}},
        {'id': 'c1', 'type': 'cover_art', 'attributes': {'fileName': null}},
        {'id': 'c1', 'type': 'cover_art', 'attributes': {'fileName': 42}},
      ]) {
        final m = MangaDexService.parseManga(manga('abc', [rel]));
        expect(m.coverUrl, isNull, reason: '$rel');
        expect(m.coverUrl?.contains('null'), isNot(true));
      }
    });

    test('skips an empty cover_art and takes the next one', () {
      final m = MangaDexService.parseManga(manga('abc', [
        {'id': 'c0', 'type': 'cover_art', 'attributes': {'fileName': ' '}},
        {'id': 'c1', 'type': 'cover_art', 'attributes': {'fileName': 'b.png'}},
      ]));
      expect(m.coverUrl, 'https://uploads.mangadex.org/covers/abc/b.png.512.jpg');
    });

    test('finds the cover id for a follow-up lookup', () {
      expect(
          MangaDexService.coverIdOf(manga('abc', [
            {'id': 'c9', 'type': 'cover_art'}
          ])),
          'c9');
      expect(MangaDexService.coverIdOf(manga('abc', const [])), isNull);
    });
  });

  group('cover url building and repair', () {
    test('builds thumbnails and originals, never doubles the suffix', () {
      expect(MangaDexService.coverUrlFor('abc', 'x.png'),
          'https://uploads.mangadex.org/covers/abc/x.png.512.jpg');
      expect(MangaDexService.coverUrlFor('abc', 'x.png', size: 256),
          'https://uploads.mangadex.org/covers/abc/x.png.256.jpg');
      expect(MangaDexService.coverUrlFor('abc', 'x.png', size: null),
          'https://uploads.mangadex.org/covers/abc/x.png');
      expect(MangaDexService.coverUrlFor('abc', 'x.png.512.jpg'),
          'https://uploads.mangadex.org/covers/abc/x.png.512.jpg');
      expect(MangaDexService.coverUrlFor('abc', null), isNull);
      expect(MangaDexService.coverUrlFor('abc', 'null'), isNull);
      expect(MangaDexService.coverUrlFor('', 'x.png'), isNull);
    });

    test('fixes old link forms of the same series', () {
      const good = 'https://uploads.mangadex.org/covers/abc/x.png.512.jpg';
      expect(MangaDexService.repairCoverUrl(good, 'abc'), good);
      expect(MangaDexService.isValidCoverUrl(good, 'abc'), isTrue);
      expect(
          MangaDexService.repairCoverUrl(
              'http://mangadex.org/covers/abc/x.png.512.jpg', 'abc'),
          good);
      expect(
          MangaDexService.repairCoverUrl(
              'https://uploads.mangadex.org/covers/abc/x.png.512.jpg.512.jpg',
              'abc'),
          good);
      expect(
          MangaDexService.repairCoverUrl(
              'https://uploads.mangadex.org/covers/abc/x.png.256.jpg', 'abc'),
          'https://uploads.mangadex.org/covers/abc/x.png.256.jpg');
    });

    test("a link that can't be this series' cover needs a lookup", () {
      for (final bad in [
        'https://uploads.mangadex.org/covers/abc/.512.jpg', // empty file name
        'https://uploads.mangadex.org/covers/abc/null.512.jpg',
        'https://uploads.mangadex.org/covers/other/x.png.512.jpg', // wrong series
        'https://uploads.mangadex.org/covers/abc', // no file
        'https://mangadex.org/title/abc',
      ]) {
        expect(MangaDexService.repairCoverUrl(bad, 'abc'), isNull, reason: bad);
        expect(MangaDexService.isValidCoverUrl(bad, 'abc'), isFalse);
      }
      expect(MangaDexService.repairCoverUrl('', 'abc'), isNull);
    });

    test('covers from elsewhere are left as they are', () {
      const anilist = 'https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/b1.jpg';
      expect(MangaDexService.repairCoverUrl(anilist, 'abc'), anilist);
    });
  });

  group('looking up a series cover', () {
    test('asks for the expanded cover_art and names the app', () async {
      late http.Request seen;
      final api = MangaDexService(client: MockClient((req) async {
        seen = req;
        return reply({
          'result': 'ok',
          'data': manga('abc', [
            {'id': 'c1', 'type': 'cover_art', 'attributes': {'fileName': 'f.jpg'}}
          ]),
        });
      }));
      final m = await api.manga('abc');
      expect(m?.coverUrl, 'https://uploads.mangadex.org/covers/abc/f.jpg.512.jpg');
      expect(seen.url.path, '/manga/abc');
      expect(seen.url.queryParametersAll['includes[]'], ['cover_art']);
      expect(seen.headers['User-Agent'], MangaDexService.userAgent);
    });

    test('looks the cover up by id when it comes back without its file',
        () async {
      final paths = <String>[];
      final api = MangaDexService(client: MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/cover/c1') {
          return reply({
            'result': 'ok',
            'data': {
              'id': 'c1',
              'type': 'cover_art',
              'attributes': {'fileName': 'late.webp'}
            },
          });
        }
        return reply({
          'result': 'ok',
          'data': manga('abc', [
            {'id': 'c1', 'type': 'cover_art'}
          ]),
        });
      }));
      final m = await api.manga('abc');
      expect(paths, ['/manga/abc', '/cover/c1']);
      expect(m?.coverUrl,
          'https://uploads.mangadex.org/covers/abc/late.webp.512.jpg');
    });

    test('a series MangaDex no longer has is null, not an error', () async {
      final api = MangaDexService(
          client: MockClient((_) async => reply({'result': 'error'}, 404)));
      expect(await api.manga('gone'), isNull);
      expect(await MangaDexSource(api).seriesCover('gone'), isNull);
    });

    test('a busy MangaDex is still an error (try again later)', () async {
      final api = MangaDexService(
          client: MockClient((_) async => reply({'result': 'error'}, 429)));
      await expectLater(api.manga('abc'), throwsA(isA<MangaDexException>()));
    });

    test('the MangaDex source hands out the same cover url', () async {
      final api = MangaDexService(client: MockClient((_) async => reply({
            'result': 'ok',
            'data': manga('abc', [
              {'id': 'c1', 'type': 'cover_art', 'attributes': {'fileName': 'f.jpg'}}
            ]),
          })));
      expect(await MangaDexSource(api).seriesCover('abc'),
          'https://uploads.mangadex.org/covers/abc/f.jpg.512.jpg');
    });
  });
}
