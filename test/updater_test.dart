import 'package:flutter_test/flutter_test.dart';
import 'package:panel/services/updater.dart';

void main() {
  test('isNewer compares versions number by number', () {
    expect(isNewer('1.7.0', '1.6.0'), isTrue);
    expect(isNewer('v1.10.0', '1.9.9'), isTrue);
    expect(isNewer('1.6.0', '1.6.0+5'), isFalse);
    expect(isNewer('1.6', '1.6.1'), isFalse);
    expect(isNewer('2.0.0', '1.99.99'), isTrue);
  });

  test('release picks the universal APK', () {
    final r = AppRelease.fromJson({
      'tag_name': 'v1.7.0',
      'name': '',
      'body': 'Bulk import',
      'assets': [
        {'name': 'app-arm64-v8a-release.apk', 'browser_download_url': 'a', 'size': 1},
        {'name': 'MyReadList.apk', 'browser_download_url': 'u', 'size': 2},
        {'name': 'notes.txt', 'browser_download_url': 'n', 'size': 3},
      ],
    });
    expect(r.version, '1.7.0');
    expect(r.name, 'v1.7.0');
    expect(r.apkUrl, 'u');
  });
}
