@echo off
REM Builds Panel for release. Stops at the first step that fails.
REM Output: build\app\outputs\flutter-apk\Panel-<version>.apk

cd /d "%~dp0"
if not exist env.json (
  echo env.json is missing. Copy env.example.json to env.json and fill it in.
  exit /b 1
)
findstr /c:"your_key_here" env.json >nul && (
  echo env.json still has the placeholder key. Paste your real publishable key ^(Supabase -^> Project Settings -^> API Keys^).
  exit /b 1
)

echo === flutter clean ===
call flutter clean || goto :fail
echo === flutter pub get ===
call flutter pub get || goto :fail
echo === flutter analyze ===
call flutter analyze || goto :fail
echo === flutter test ===
call flutter test || goto :fail
echo === flutter build apk ===
call flutter build apk --release --dart-define-from-file=env.json || goto :fail

echo.
echo Done. Upload this file to the GitHub release:
dir /b build\app\outputs\flutter-apk\Panel-*.apk
exit /b 0

:fail
echo.
echo Build stopped: the step above failed.
exit /b 1