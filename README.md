# MyReadList (Flutter)

A Flutter rebuild of the MyReadList web app: track the manga, manhwa, manhua
and comics you read. It uses the **same Supabase project and database** as the
web version, so existing accounts and lists work right away.

## Build it

```bash
# 1. Generate the Android / iOS / web platform folders (keeps lib/ and test/)
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define-from-file=env.json
```

Needs Flutter 3.29 or newer (`flutter --version`).

## One-time setup after `flutter create`

### 1. Internet permission (Android release builds)

In `android/app/src/main/AndroidManifest.xml`, add this above `<application`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

### 2. Email links (confirm sign-up, reset password)

Auth emails send people back to `com.readlist.panel://login-callback`.

**Supabase dashboard** → Authentication → URL Configuration → *Redirect URLs*:
add `com.readlist.panel://login-callback`.

**Android**: in `AndroidManifest.xml`, inside the main `<activity>`:

```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data android:scheme="com.readlist.panel" android:host="login-callback" />
</intent-filter>
```

**iOS**: in `ios/Runner/Info.plist`, inside the top `<dict>`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>com.readlist.panel</string></array>
  </dict>
</array>
```

## Supabase keys

Keys are kept out of Git. They live in `env.json` (ignored by `.gitignore`).

```bash
cp env.example.json env.json      # then paste your URL + publishable key
flutter run --dart-define-from-file=env.json
flutter build apk --release --dart-define-from-file=env.json
```

Android Studio: Run → Edit Configurations → *Additional run args* →
`--dart-define-from-file=env.json`. VS Code uses `.vscode/launch.json`.

Only ever use the **publishable** key in the app — never the `service_role` /
secret key. Data is protected by Row Level Security (see `supabase_setup.sql`).

## Offline mode

The list is saved on the phone. Adding, editing, +1 chapter, deleting and
reordering all work with no connection: changes go into a local queue and are
sent to Supabase automatically when the app is online again (on launch, when
it returns to the foreground, every 20 s while something is waiting, and on
pull-to-refresh). Titles with unsent changes show a small cloud icon.
Discover, Stats, Community and account settings need a connection.

## App lock (fingerprint / face)

Profile → Security → *Unlock with fingerprint / face*. You stay signed in and
the app asks for your fingerprint, face or phone PIN when it opens (or after
30 s in the background). Android needs `FlutterFragmentActivity`, the
`USE_BIOMETRIC` permission and an AppCompat theme — all already set up.

## What changed from the web app (UI/UX)

| Before (web) | Now (Flutter) |
| --- | --- |
| Tabs + header buttons for stats/profile dialogs | Bottom navigation: Library · To Read · Discover · Stats · Profile |
| "New title" placeholder rows you rename inline | **Add title** sheet: search AniList (cover, author, chapters filled in) or add manually |
| Small +/- buttons in a table | Big **+1** button on every card, **swipe right for +1**, full chapter stepper (+1 / +5 / type exact) in the detail sheet |
| Delete via menu | **Swipe left to delete, with Undo** |
| Status/type dropdowns | Colored status chips with counts, type filter chip, sort menu, list/grid toggle |
| Drag rows on desktop only | "My order" sort enables drag-to-reorder on phones |
| Stats in a dialog | Stats tab: headline numbers, 14-day chapters chart with streak, finished-per-month chart, status and type breakdowns |
| Discover grid | Trending / Popular / Top with Manga / Manhwa / Manhua filters, infinite scroll, rank and score badges, preview sheet with synopsis |
| — | Light / dark / system theme, offline cache for instant start, sync-error banner with retry, skeleton loading, empty states |

Small behavior niceties: tapping +1 on a To Read title moves it to Reading;
marking a title Finished jumps the chapter to the total if it's known.

Everything that feeds the stats works the same as on the web (`chapter_log`
and `completion_log` rows are written with the same rules), so both apps can
be used side by side.

## Project layout

```
lib/
  main.dart, app.dart        entry point, theme + auth gate
  config.dart                Supabase settings
  theme.dart                 colors, typography, status colors
  models/entry.dart          Entry, EntryType, EntryStatus, SearchResult
  services/                  Supabase repository, AniList client
  state/providers.dart       Riverpod state (list, filters, profile, stats)
  screens/                   auth, list (library + to read), discover, stats,
                             profile, community / public profiles
  widgets/                   cards, sheets, charts, shared bits
test/                        parser, model and widget tests
```
