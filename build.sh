#!/usr/bin/env bash
# Builds Panel for release. Stops at the first step that fails.
# Output: build/app/outputs/flutter-apk/Panel-<version>.apk
set -e
cd "$(dirname "$0")"
[ -f env.json ] || { echo "env.json is missing. Copy env.example.json to env.json and fill it in."; exit 1; }

flutter clean
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define-from-file=env.json

echo
echo "Done. Upload this file to the GitHub release:"
ls build/app/outputs/flutter-apk/Panel-*.apk