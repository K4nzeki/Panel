import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The version lives in pubspec.yaml (Android and iOS read it from there);
/// README's "Current" line must name the same one. See tool/bump_version.dart.
void main() {
  test('pubspec and README agree on the version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version: (\d+\.\d+\.\d+\+\d+)$', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);
    expect(v, isNotNull, reason: 'pubspec.yaml needs "version: X.Y.Z+N"');
    expect(File('README.md').readAsStringSync(), contains('Current: **$v**'));
  });

  test('Android and iOS take the version from pubspec.yaml', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('versionCode = flutter.versionCode'));
    expect(gradle, contains('versionName = flutter.versionName'));
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains(r'$(FLUTTER_BUILD_NAME)'));
    expect(plist, contains(r'$(FLUTTER_BUILD_NUMBER)'));
  });
}
