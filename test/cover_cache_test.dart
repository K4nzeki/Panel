import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:panel/services/cover_cache.dart';
import 'package:panel/services/mangadex.dart';
import 'package:panel/services/sources/reader_source.dart';

/// A tiny real PNG header is enough: CoverCache only stores bytes.
final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

http.Response image() =>
    http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});

class _Fetcher implements ImageFetcher {
  final asked = <String>[];
  @override
  String get id => 'apk:1';
  @override
  Future<FetchedImage> fetchImage(String url) async {
    asked.add(url);
    return FetchedImage(_png, contentType: 'image/png');
  }
}

void main() {
  setUp(CoverCache.resetForTest);
  tearDown(CoverCache.resetForTest);

  test('cover file names are short, stable and file-safe', () {
    const url = 'https://uploads.mangadex.org/covers/abc/def.jpg?x=1&y=2';
    final name = CoverCache.fileName(url);
    expect(name, CoverCache.fileName(url));
    expect(name, CoverCache.fileName('  $url '));
    expect(name, matches(RegExp(r'^[0-9a-f]{16}\.img$')));
    expect(CoverCache.fileName('https://a/b.png'),
        isNot(CoverCache.fileName('https://a/c.png')));
  });

  test('nothing counts as saved before the folder is open', () {
    expect(CoverCache.savedSync('https://a/b.png'), isNull);
  });

  test('the same cover loads through one image cache entry', () {
    expect(const CachedCoverProvider('https://a/b.png'),
        const CachedCoverProvider('https://a/b.png'));
    expect(const CachedCoverProvider('https://a/b.png'),
        isNot(const CachedCoverProvider('https://a/c.png')));
  });

  group('headers', () {
    test('MangaDex covers name the app and send MangaDex as the Referer', () {
      final h = CoverCache.headersFor(
          'https://uploads.mangadex.org/covers/abc/f.jpg.512.jpg');
      expect(h['User-Agent'], MangaDexService.userAgent);
      expect(h['User-Agent'], isNot(contains('Mozilla')));
      expect(h['Referer'], 'https://mangadex.org/');
      expect(h['Accept'], contains('image/'));
    });

    test("a source's headers are used for covers on its host", () {
      CoverCache.useSource('https://cdn.site.test/covers/a.jpg', headers: {
        'Referer': 'https://site.test/',
        'user-agent': 'SiteUA',
      });
      final h = CoverCache.headersFor('https://cdn.site.test/other/b.webp');
      expect(h['Referer'], 'https://site.test/');
      // Same header in another spelling: the source's one replaces ours.
      expect(h['user-agent'], 'SiteUA');
      expect(h.containsKey('User-Agent'), isFalse);
      // Other hosts don't get them.
      expect(CoverCache.headersFor('https://elsewhere.test/a.jpg')['Referer'],
          isNull);
    });

    test("MangaDex's and AniList's rules can't be overridden by a site", () {
      const bogus = {'Referer': 'https://site.test/'};
      CoverCache.useSource('https://uploads.mangadex.org/covers/a/b.jpg',
          headers: bogus);
      CoverCache.useSource('https://s4.anilist.co/file/x.jpg', headers: bogus);
      expect(
          CoverCache.headersFor('https://uploads.mangadex.org/covers/a/b.jpg')[
              'Referer'],
          'https://mangadex.org/');
      expect(CoverCache.headersFor('https://s4.anilist.co/file/x.jpg')['Referer'],
          isNull);
    });
  });

  group('downloading', () {
    test('sends the headers for the cover and returns its bytes', () async {
      final seen = <http.BaseRequest>[];
      CoverCache.client = MockClient((req) async {
        seen.add(req);
        return image();
      });
      const url = 'https://uploads.mangadex.org/covers/abc/f.jpg.512.jpg';
      expect(await CoverCache.bytes(url), _png);
      expect(seen.single.headers['User-Agent'], MangaDexService.userAgent);
      expect(seen.single.headers['Referer'], 'https://mangadex.org/');
      expect(CoverCache.isBroken(url), isFalse);
    });

    test('a cover the server refuses is reported broken', () async {
      final broken = <String>[];
      CoverCache.onBroken = broken.add;
      CoverCache.client = MockClient((req) async => req.url.path.contains('html')
          ? http.Response('<html>blocked</html>', 200,
              headers: {'content-type': 'text/html'})
          : http.Response('', 404));
      for (final url in ['https://a.test/gone.jpg', 'https://a.test/html.jpg']) {
        await expectLater(CoverCache.bytes(url), throwsA(anything));
        expect(CoverCache.isBroken(url), isTrue, reason: url);
      }
      expect(broken, ['https://a.test/gone.jpg', 'https://a.test/html.jpg']);
    });

    test('a busy server or no connection is not "broken"', () async {
      CoverCache.client = MockClient((req) async => req.url.path == '/busy.jpg'
          ? http.Response('', 503)
          : throw http.ClientException('offline'));
      for (final url in ['https://a.test/busy.jpg', 'https://a.test/off.jpg']) {
        await expectLater(CoverCache.bytes(url), throwsA(anything));
        expect(CoverCache.isBroken(url), isFalse, reason: url);
      }
    });

    test("falls back to the extension's own client", () async {
      final fetcher = _Fetcher();
      CoverCache.useSource('https://ext.test/a.jpg', fetcher: fetcher);
      CoverCache.client = MockClient((_) async => http.Response('', 403));
      expect(await CoverCache.bytes('https://ext.test/a.jpg'), _png);
      expect(fetcher.asked, ['https://ext.test/a.jpg']);
      expect(CoverCache.isBroken('https://ext.test/a.jpg'), isFalse);
    });

    test('a cover found while saving others is saved too', () async {
      final gate = Completer<void>();
      final asked = <String>[];
      CoverCache.client = MockClient((req) async {
        asked.add(req.url.toString());
        if (req.url.path == '/first.jpg') await gate.future;
        return image();
      });
      final first = CoverCache.prefetch(['https://a.test/first.jpg']);
      await pumpEventQueue();
      // Asked while the first one is still downloading: used to be dropped.
      await CoverCache.prefetch(['https://a.test/second.jpg']);
      gate.complete();
      await first;
      await pumpEventQueue();
      expect(asked, ['https://a.test/first.jpg', 'https://a.test/second.jpg']);
    });
  });
}
