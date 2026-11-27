// Bumps the app version everywhere it's written down, following the
// rules in README.md ("Versioning"):
//
//   dart run tool/bump_version.dart minor   # new feature   2.4.0+15 → 2.5.0+16
//   dart run tool/bump_version.dart patch   # bug fixes     2.4.0+15 → 2.4.1+16
//   dart run tool/bump_version.dart major   # big change    2.4.0+15 → 3.0.0+16
//
// The build number always goes up by 1. Android (versionName/versionCode,
// the APK name) and iOS (FLUTTER_BUILD_NAME/NUMBER) read the version from
// pubspec.yaml, so that and README's "Current" line are the only places to
// change. test/version_test.dart checks they agree.
import 'dart:io';

void main(List<String> args) {
  final kind = args.isEmpty ? '' : args.first;
  if (!const {'major', 'minor', 'patch'}.contains(kind)) {
    stderr.writeln('Usage: dart run tool/bump_version.dart major|minor|patch');
    exit(64);
  }
  final pubspec = File('pubspec.yaml');
  final text = pubspec.readAsStringSync();
  final m = RegExp(r'^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$', multiLine: true)
      .firstMatch(text);
  if (m == null) {
    stderr.writeln('No "version: X.Y.Z+N" line in pubspec.yaml');
    exit(65);
  }
  var major = int.parse(m[1]!), minor = int.parse(m[2]!), patch = int.parse(m[3]!);
  final build = int.parse(m[4]!) + 1;
  final old = '${m[1]}.${m[2]}.${m[3]}+${m[4]}';
  switch (kind) {
    case 'major':
      major++;
      minor = 0;
      patch = 0;
    case 'minor':
      minor++;
      patch = 0;
    default:
      patch++;
  }
  final next = '$major.$minor.$patch+$build';
  pubspec.writeAsStringSync(text.replaceFirst(m[0]!, 'version: $next'));

  final readme = File('README.md');
  if (readme.existsSync()) {
    final r = readme.readAsStringSync();
    readme.writeAsStringSync(r.replaceFirst(
        'Current: **$old**.',
        'Current: **$next**. New: (describe this release)\n\n'
            'Previous: **$old**.'));
  }
  stdout.writeln('$old → $next');
}
