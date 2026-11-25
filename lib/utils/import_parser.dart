import '../models/entry.dart';

/// A title parsed from pasted text, not yet saved.
class ParsedEntry {
  const ParsedEntry({
    required this.title,
    required this.type,
    required this.status,
    required this.chapter,
    required this.reread,
  });

  final String title;
  final EntryType type;
  final EntryStatus status;
  final int chapter;
  final int reread;
}

class ParseResult {
  const ParseResult(this.entries, this.errors);
  final List<ParsedEntry> entries;
  final List<String> errors;
}

/// Parses `Title | Chapter | Status | Type | Reread`.
ParsedEntry? parsePipeLine(String line) {
  final parts = line.split('|').map((p) => p.trim()).toList();
  if (parts.length < 5) return null;
  final title = parts[0];
  final c = int.tryParse(parts[1]);
  final s = EntryStatus.tryParse(parts[2]);
  final t = EntryType.tryParse(parts[3]);
  final r = int.tryParse(parts[4]);
  if (title.isEmpty || c == null || s == null || t == null || r == null) {
    return null;
  }
  return ParsedEntry(title: title, type: t, status: s, chapter: c, reread: r);
}

/// Parses `Title words… Chapter Status Type Reread` (space separated, the
/// title may contain spaces). Returns an error message instead on failure.
({ParsedEntry? entry, String? error}) parseSpaceLine(String line) {
  final tokens = line.trim().split(RegExp(r'\s+'));
  if (tokens.length < 5) {
    return (entry: null, error: 'needs Title + Chapter Status Type Reread');
  }
  final reread = tokens.removeLast();
  final type = tokens.removeLast();
  var status = tokens.removeLast();
  // "To Read" is two words — glue it back together.
  if (status.toLowerCase() == 'read' &&
      tokens.isNotEmpty &&
      tokens.last.toLowerCase() == 'to') {
    tokens.removeLast();
    status = 'To Read';
  }
  if (tokens.length < 2) {
    return (entry: null, error: 'needs Title + Chapter Status Type Reread');
  }
  final chapter = tokens.removeLast();
  final title = tokens.join(' ').trim();

  final t = EntryType.tryParse(type);
  final s = EntryStatus.tryParse(status);
  final c = int.tryParse(chapter);
  final r = int.tryParse(reread);
  if (title.isEmpty) return (entry: null, error: 'missing title');
  if (t == null) return (entry: null, error: 'unknown type "$type"');
  if (s == null) return (entry: null, error: 'unknown status "$status"');
  if (c == null) return (entry: null, error: 'chapter "$chapter" not a number');
  if (r == null) return (entry: null, error: 'reread "$reread" not a number');
  return (
    entry: ParsedEntry(title: title, type: t, status: s, chapter: c, reread: r),
    error: null,
  );
}

/// Parses a whole pasted block, one title per line.
ParseResult parseImportText(String text) {
  final entries = <ParsedEntry>[];
  final errors = <String>[];
  final lines = text.split(RegExp(r'\r?\n'));
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.contains('|')) {
      final p = parsePipeLine(line);
      if (p != null) {
        entries.add(p);
      } else {
        errors.add('Line ${i + 1}: expected Title | Chapter | Status | Type | Reread');
      }
    } else {
      final r = parseSpaceLine(line);
      if (r.entry != null) {
        entries.add(r.entry!);
      } else {
        errors.add('Line ${i + 1}: ${r.error}');
      }
    }
  }
  return ParseResult(entries, errors);
}

/// Inverse of [parsePipeLine] — used for "Export list".
String exportPipeLines(Iterable<Entry> entries) => entries
    .map((e) =>
        '${e.title} | ${e.chapter} | ${e.status.label} | ${e.type.label} | ${e.reread}')
    .join('\n');
