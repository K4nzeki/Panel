import '../models/entry.dart';
import 'import_parser.dart';

/// Turns a title into a key for duplicate checks, so "Solo Leveling",
/// "solo  leveling" and "Solo Leveling!" all count as the same title.
String titleKey(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// An existing title that the import will move forward (more chapters).
class ImportUpdate {
  const ImportUpdate(this.existing, this.incoming);
  final Entry existing;
  final ParsedEntry incoming;
}

/// What an import will do, worked out before anything is saved.
class ImportPlan {
  const ImportPlan({
    required this.toAdd,
    required this.toUpdate,
    required this.skipped,
    required this.mergedInFile,
  });

  /// Titles that aren't in the list yet.
  final List<ParsedEntry> toAdd;

  /// Titles already in the list where the import has more chapters.
  final List<ImportUpdate> toUpdate;

  /// Titles already in the list with the same or more chapters (ignored).
  final int skipped;

  /// Rows that were repeats of another row in the same file.
  final int mergedInFile;

  bool get isEmpty => toAdd.isEmpty && toUpdate.isEmpty;
}

/// Compares [incoming] rows against the [existing] list:
///  * the same title twice in the file → keep the row with more chapters
///  * title not in the list → add it
///  * title in the list, import has more chapters → update that title
///  * title in the list, import has the same or fewer → skip it
ImportPlan planImport(List<Entry> existing, List<ParsedEntry> incoming) {
  // 1. Collapse repeats inside the file itself.
  final byKey = <String, ParsedEntry>{};
  var mergedInFile = 0;
  for (final p in incoming) {
    final key = titleKey(p.title);
    if (key.isEmpty) continue;
    final prev = byKey[key];
    if (prev == null) {
      byKey[key] = p;
      continue;
    }
    mergedInFile++;
    final best = p.chapter > prev.chapter ? p : prev;
    byKey[key] = ParsedEntry(
      title: best.title,
      type: best.type,
      status: best.status,
      chapter: best.chapter,
      reread: p.reread > prev.reread ? p.reread : prev.reread,
    );
  }

  // 2. Index the current list (if it already has repeats, use the one
  //    furthest along).
  final current = <String, Entry>{};
  for (final e in existing) {
    final key = titleKey(e.title);
    final prev = current[key];
    if (prev == null || e.chapter > prev.chapter) current[key] = e;
  }

  // 3. Decide per title.
  final toAdd = <ParsedEntry>[];
  final toUpdate = <ImportUpdate>[];
  var skipped = 0;
  byKey.forEach((key, p) {
    final have = current[key];
    if (have == null) {
      toAdd.add(p);
    } else if (p.chapter > have.chapter) {
      toUpdate.add(ImportUpdate(have, p));
    } else {
      skipped++;
    }
  });

  return ImportPlan(
    toAdd: toAdd,
    toUpdate: toUpdate,
    skipped: skipped,
    mergedInFile: mergedInFile,
  );
}
