import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:panel/services/extension_covers.dart';
import 'package:panel/services/extension_repo.dart';

// Tiny protobuf writer for building test indexes.
List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  while (true) {
    if (x >= 0 && x < 0x80) {
      out.add(x);
      return out;
    }
    out.add((x & 0x7f) | 0x80);
    x = x >>> 7;
  }
}

List<int> _str(int field, String s) => _bytes(field, utf8.encode(s));
List<int> _bytes(int field, List<int> b) =>
    [..._varint(field << 3 | 2), ..._varint(b.length), ...b];
List<int> _int(int field, int v) => [..._varint(field << 3), ..._varint(v)];

void main() {
  test('reads a Keiyoushi-style index.pb', () {
    final source = [
      ..._int(1, 9124545289113350724),
      ..._str(2, 'AchyManga'),
      ..._str(3, 'en'),
      ..._str(4, 'https://achymanga.online'),
    ];
    final ext = [
      ..._str(1, 'AchyManga'),
      ..._str(2, 'eu.kanade.tachiyomi.extension.all.achymanga'),
      ..._bytes(3, [
        ..._str(1, 'https://example.com/a.apk'),
        ..._str(2, 'https://example.com/a.png'),
      ]),
      ..._str(4, '1.6'),
      ..._int(5, 106001),
      ..._str(6, '1.6.1'),
      ..._int(7, 3),
      ..._bytes(8, source),
    ];
    final index = Uint8List.fromList([
      ..._str(1, 'Keiyoushi'),
      ..._str(2, 'KEI'),
      ..._str(3, 'abc123'),
      ..._bytes(4, _str(1, 'https://keiyoushi.github.io')),
      ..._bytes(101, _bytes(1, ext)),
    ]);

    final repo = ExtensionRepoService.parseProtoIndex(keiyoushiRepoUrl, index);
    expect(repo.name, 'Keiyoushi');
    expect(repo.fingerprint, 'abc123');
    expect(repo.website, 'https://keiyoushi.github.io');
    expect(repo.extensions, hasLength(1));
    final e = repo.extensions.single;
    expect(e.name, 'AchyManga');
    expect(e.lang, 'all');
    expect(e.apkUrl, 'https://example.com/a.apk');
    expect(e.iconUrl, 'https://example.com/a.png');
    expect(e.versionCode, 106001);
    expect(e.versionName, '1.6.1');
    expect(e.isNsfw, isTrue);
    expect(e.sources.single.id, '9124545289113350724');
    expect(e.sources.single.baseUrl, 'https://achymanga.online');
  });

  test('reads the older index.min.json format', () {
    final json = utf8.encode(jsonEncode([
      {
        'name': 'Tachiyomi: Example',
        'pkg': 'eu.kanade.tachiyomi.extension.en.example',
        'apk': 'tachiyomi-en.example-v1.4.2.apk',
        'version': '1.4.2',
        'code': 2,
        'nsfw': 0,
        'sources': [
          {'name': 'Example', 'lang': 'en', 'id': '1', 'baseUrl': 'https://ex.com'}
        ],
      }
    ]));
    final repo = ExtensionRepoService.parseJsonIndex(
        'https://host.com/repo/index.min.json', Uint8List.fromList(json));
    final e = repo.extensions.single;
    expect(e.name, 'Example');
    expect(e.lang, 'en');
    expect(e.apkUrl,
        'https://host.com/repo/apk/tachiyomi-en.example-v1.4.2.apk');
  });

  test('cleans up pasted repo links', () {
    expect(ExtensionRepoService.normalizeUrl('  $keiyoushiRepoUrl '),
        keiyoushiRepoUrl);
    expect(
        ExtensionRepoService.normalizeUrl(
            'github.com/keiyoushi/extensions/blob/repo/index.pb'),
        keiyoushiRepoUrl);
    expect(ExtensionRepoService.normalizeUrl(''), isNull);
  });

  test('finds the cover next to an exact title match', () {
    const page = '''
      <div class="c-tabs-item__content">
        <div class="tab-thumb"><a href="/manga/other/">
          <img data-src="/wp/other-110x150.jpg" src="data:image/gif;base64,x" alt="Other"></a></div>
        <div class="post-title"><h3><a href="/manga/other/">Other Story</a></h3></div>
      </div>
      <div class="c-tabs-item__content">
        <div class="tab-thumb"><a href="/manga/solo/">
          <img data-src="/wp/solo-110x150.jpg" src="data:image/gif;base64,x"></a></div>
        <div class="post-title"><h3><a href="/manga/solo/">Solo Leveling</a></h3></div>
      </div>''';
    final cover = ExtensionCoverFinder.pickCover(
      html_parser.parse(page),
      'sololeveling',
      Uri.parse('https://site.com/?s=Solo+Leveling'),
    );
    expect(cover, 'https://site.com/wp/solo.jpg');
  });
}
