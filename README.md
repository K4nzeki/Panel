# MyReadList (Flutter)

Track and read the manga, manhwa, manhua and comics you follow. Started as a
Flutter rebuild of the MyReadList web app; since 2.0 it works fully on the
phone with no account, and can read chapters in the app.

## Test

```bash
# 1. Generate the Android / iOS / web platform folders (keeps lib/ and test/)
flutter clean
flutter pub get
flutter analyze
flutter test
```

Needs Flutter 3.29 or newer (`flutter --version`).

## No account needed (2.0)

Panel 2.0 has **no accounts, passwords or app lock**. It opens straight into
your library and keeps everything on the phone: the list, progress, Stats,
the Updates tab, reading sources and downloads. Supabase, `env.json` and the
`--dart-define-from-file` flag are no longer needed (you can delete
`env.json`; `supabase_*.sql` are only kept for reference).

**Upgrading from 1.x:** on first launch Panel copies the list it had saved on
the phone for your account (including changes that hadn't synced) into local
storage, plus your Updates tab. Stats history that only existed on the server
isn't copied; new reading is counted from now on. If you used a different
phone, export from the web app and use Settings → Import titles.

## Offline mode

Everything works with no connection: browsing and editing the library,
Resume, chapter lists you've opened before (saved on the phone), the
scanlator filter, the extension store (last copy of each repo is saved) and
**reading downloaded chapters**. Online extras catch up automatically when
the connection is back: new-chapter checks, missing covers, fresh chapter
lists, repo updates and queued downloads. **Covers** are saved on the phone
the first time they load (every cover in your list is saved in the
background), so cover art shows offline too. When the connection drops a
short toast says so, and a small cloud icon sits in the library header
until it's back (tap it to try again).

## Reading modes (2.1)

The reader has three layouts, picked in reader settings (the button at the
top right of the reader): **Paged (Right to Left)**, **Paged (Left to
Right)** and **Long Strip**. In the paged modes, swipe, tap the left or
right side, or use the arrow keys to turn pages. Each title opens in the
default for its type (manga right to left; manhwa, manhua and webtoons as a
long strip; everything else left to right) until you pick a mode for it,
which is then remembered for that title.

## Reading in the app (2.0)

- **Resume** replaces the old +1 button on every card, grid card and the
  title sheet. It opens the reader at the chapter and page where you stopped.
  If you finished that chapter it opens the next one; if you never used the
  reader it opens the first chapter after the one your library says you're
  on (or chapter 1). Reaching the end of a chapter moves your library
  progress forward (and counts in Stats). The −/+ stepper in the title sheet
  is still there for fixing progress by hand.
- **Sources:** the first time, pick where to read a title. Panel searches
  MangaDex and the sites of your installed extensions side by side; "More
  sources" adds any other site from your repos. Change it any time from the
  title's Chapters screen. Your chapter number is kept when you switch.
- **Scanlator filter:** on the Chapters screen, tap groups to hide/show them
  (long-press = only that group). Resume and "next chapter" follow it, and
  when several groups did the same chapter the one you were reading wins.
- **How sources work:** Panel can't run Mihon/Tachiyomi extension APKs. It
  reads MangaDex through its public API, and reads extension *sites* directly
  when they use the common Madara or MangaThemesia themes (a large share of
  the Keiyoushi list). Sites behind Cloudflare checks or with app-only APIs
  show an error — pick another source for those titles.

## Downloads (2.0)

Download single chapters (the icon on each chapter, or in the reader) or
"Download unread / all" from the Chapters screen menu. Chapters go only to
the phone, in Panel's own folder:

```
Android/data/com.readlist.panel/files/Panel Downloads/<Title>/<Chapter (Group)>/001.jpg …
```

That folder belongs to the app, so **no storage permission is needed on any
Android version** (scoped-storage safe; nothing was added to the manifest).
A `.nomedia` file keeps pages out of the gallery. Android deletes this folder
if Panel is uninstalled. Downloads run one at a time with a quiet progress
notification, survive app restarts, and pause/resume with the connection.
Settings → Downloads shows space used and can delete everything.

## What changed from the web app (UI/UX)

| Before (web) | Now (Flutter) |
| --- | --- |
| Tabs + header buttons for stats/profile dialogs | Bottom navigation: Library · To Read · Discover · Stats · Profile |
| "New title" placeholder rows you rename inline | **Add title** sheet: search AniList (cover, author, chapters filled in) or add manually |
| Small +/- buttons in a table | **Resume** button on every card (opens the in-app reader where you stopped), full chapter stepper (+1 / +5 / type exact) in the detail sheet |
| Delete via menu | **Swipe left to delete, with Undo** |
| Status/type dropdowns | Colored status chips with counts, type filter chip, sort menu, list/grid toggle |
| Drag rows on desktop only | "My order" sort enables drag-to-reorder on phones |
| Stats in a dialog | Stats tab: headline numbers, 14-day chapters chart with streak, finished-per-month chart, status and type breakdowns |
| Discover grid | Trending / Popular / Top with Manga / Manhwa / Manhua filters, infinite scroll, rank and score badges, preview sheet with synopsis |
| — | Light / dark / system theme, offline cache for instant start, sync-error banner with retry, skeleton loading, empty states |

Small behavior niceties: reading a To Read title moves it to Reading;
marking a title Finished jumps the chapter to the total if it's known.

Stats follow the same rules as before (a move into Finished or an extra
reread counts as a finish; chapters going up count as read that day), now
saved on the phone.

## Project layout

```
lib/
  main.dart, app.dart        entry point, theme (opens straight to the library)
  config.dart                app settings (support email, downloads folder)
  theme.dart                 colors, typography, status colors
  models/entry.dart          Entry, EntryType, EntryStatus, SearchResult
  models/reader.dart         ChapterInfo, ReadingLink, reading order helpers
  services/local_store.dart  the list + stats, saved on the phone
  services/sources/          MangaDex + Madara/MangaThemesia site readers
  services/downloads.dart    downloads folder layout
  services/chapter_cache.dart  saved chapter lists (offline)
  state/providers.dart       Riverpod state (list, filters, stats)
  state/reader.dart          sources, per-title links, chapter lists, Resume
  state/downloads.dart       download queue
  screens/                   list (library + to read), discover, stats,
                             updates, settings, chapters, source picker, reader
  widgets/                   cards, sheets, charts, shared bits
test/                        parser, model and widget tests
```

## New chapters (1.8)

Titles you're **Reading** are linked to MangaDex (exact title match, or pick
the series yourself in a title's sheet → *New chapters*). Linking also gives
the accurate cover. Every 5 hours, only when the phone is online, Panel checks
the newest English chapter and:

- shows a **+N** badge on the card when you're behind
- sends a notification when a new chapter comes out

Runs in the background on Android (WorkManager — Android may delay it a little
to save battery) and also when the app is opened if 5 hours have passed.


## Updates tab and extension store (1.9)

- **Less clutter:** checking for new chapters, finding covers and slow syncs
  no longer show banners in the list. They show as a quiet notification with
  a progress bar (no sound) and disappear when done. Only "You're offline"
  still shows in the list.
- **Updates tab:** every new-chapter alert is saved here (one per series,
  newest first). Tap one — or the notification itself — to open that series.
  Swipe to remove, *Mark all as read*, pull down to check now. The tab shows
  a badge with the unread count.
- **Extension store** (Profile → Extensions): paste a repo link such as
  `https://github.com/keiyoushi/extensions/raw/repo/index.pb`, then browse,
  install, update or uninstall Mihon / Tachiyomi extensions (Android installs
  them as separate apps, like Mihon does).
- **Covers from extensions:** when AniList and MangaDex have no cover, Panel
  searches the sites of your installed extensions and uses the cover next to
  an exact title match. Panel can't run extension code itself, so this works
  on sites with a normal search page (most WordPress-style manga sites) and
  skips sites behind Cloudflare checks.

No database changes. Run `flutter pub get` once (adds the `html` package).
