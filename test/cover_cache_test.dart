import 'package:flutter_test/flutter_test.dart';
import 'package:panel/services/cover_cache.dart';

void main() {
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
}
