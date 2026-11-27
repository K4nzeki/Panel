#!/usr/bin/env bash
# Builds Panel for release. Stops at the first step that fails.
# Output: build/app/outputs/flutter-apk/Panel-<version>.apk
set -e
cd "$(dirname "$0")"

flutter clean
flutter pub get
flutter upgrade
flutter upgrade --major-versions
flutter analyze
flutter test
flutter build apk --release

echo
echo "Done. Upload this file to the GitHub release:"
ls build/app/outputs/flutter-apk/Panel-*.apk
