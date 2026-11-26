import '../models/entry.dart';
import 'import_parser.dart';

/// Turns spreadsheet rows (from Excel or CSV) into titles to import.
///
/// If the first row has headers like "Title", "Chapter", "Status", "Type",
/// "Reread" the columns can be in any order and any of them except Title can
/// be missing. Without headers the columns are read as
/// Title, Chapter, Status, Type, Reread.
///
/// Blank status / type fall back to Reading / Manga; blank chapter and
/// reread fall back to 0.
ParseResult parseSheetRows(List<List<String>> rows) {
  final entries = <ParsedEntry>[];
  final errors = <String>[];

  // Skip leading blank rows.
  var start = 0;
  while (start < rows.length && _isBlank(rows[start])) {
    start++;
  }
  if (start >= rows.length) return ParseResult(entries, errors);

  var cols = _headerColumns(rows[start]);
  if (cols != null) {
    start++;
  } else {
    cols = const _Cols(title: 0, chapter: 1, status: 2, type: 3, reread: 4);
  }

  for (var i = start; i < rows.length; i++) {
    final row = rows[i];
    if (_isBlank(row)) continue;
    final rowNo = i + 1;
    String cell(int? c) =>
        (c == null || c >= row.length) ? '' : row[c].trim();

    final title = cell(cols.title);
    if (title.isEmpty) {
      errors.add('Row $rowNo: missing title');
      continue;
    }

    final chapterRaw = cell(cols.chapter);
    final chapter = chapterRaw.isEmpty ? 0 : _toInt(chapterRaw);
    if (chapter == null) {
      errors.add('Row $rowNo: chapter "$chapterRaw" is not a number');
      continue;
    }

    final rereadRaw = cell(cols.reread);
    final reread = rereadRaw.isEmpty ? 0 : (_toInt(rereadRaw) ?? 0);

    final statusRaw = cell(cols.status);
    final status = statusRaw.isEmpty ? EntryStatus.reading : _status(statusRaw);
    if (status == null) {
      errors.add('Row $rowNo: unknown status "$statusRaw"');
      continue;
    }

    final typeRaw = cell(cols.type);
    final type = typeRaw.isEmpty ? EntryType.manga : EntryType.tryParse(typeRaw);
    if (type == null) {
      errors.add('Row $rowNo: unknown type "$typeRaw"');
      continue;
    }

    entries.add(ParsedEntry(
      title: title,
      type: type,
      status: status,
      chapter: chapter,
      reread: reread,
    ));
  }
  return ParseResult(entries, errors);
}

/// Minimal CSV reader (handles quotes, commas/semicolons/tabs inside
/// quotes, and "" escapes). Picks the delimiter from the first line.
List<List<String>> parseCsv(String text) {
  if (text.startsWith('﻿')) text = text.substring(1); // Excel BOM
  final firstLine = text.split(RegExp(r'\r?\n')).first;
  final delim = [',', ';', '\t'].reduce((a, b) =>
      firstLine.split(a).length >= firstLine.split(b).length ? a : b);

  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == delim) {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

// ---------------------------------------------------------------------------

class _Cols {
  const _Cols({
    required this.title,
    this.chapter,
    this.status,
    this.type,
    this.reread,
  });
  final int title;
  final int? chapter;
  final int? status;
  final int? type;
  final int? reread;
}

const _titleNames = {'title', 'titles', 'name', 'series', 'manga', 'manhwa'};
const _chapterNames = {'chapter', 'chapters', 'ch', 'chap', 'progress', 'last chapter'};
const _statusNames = {'status', 'state'};
const _typeNames = {'type', 'kind', 'format', 'category'};
const _rereadNames = {'reread', 'rereads', 're read', 'reread count', 'times read'};

_Cols? _headerColumns(List<String> row) {
  int? title, chapter, status, type, reread;
  for (var i = 0; i < row.length; i++) {
    final h = row[i].trim().toLowerCase().replaceAll(RegExp(r'[^a-z ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title == null && _titleNames.contains(h)) {
      title = i;
    } else if (chapter == null && _chapterNames.contains(h)) {
      chapter = i;
    } else if (status == null && _statusNames.contains(h)) {
      status = i;
    } else if (type == null && _typeNames.contains(h)) {
      type = i;
    } else if (reread == null && _rereadNames.contains(h)) {
      reread = i;
    }
  }
  // Treat it as a header row only if it names the title column plus at
  // least one other, so a manga called "Status" isn't mistaken for one.
  final others = [chapter, status, type, reread].whereType<int>().length;
  if (title == null || others == 0) return null;
  return _Cols(
      title: title, chapter: chapter, status: status, type: type, reread: reread);
}

/// Accepts the app's labels plus common words from other trackers.
EntryStatus? _status(String raw) {
  final exact = EntryStatus.tryParse(raw);
  if (exact != null) return exact;
  final v = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return switch (v) {
    'completed' || 'complete' || 'done' || 'read' => EntryStatus.finished,
    'toread' || 'plantoread' || 'planning' || 'plan' || 'wishlist' ||
    'later' => EntryStatus.toRead,
    'current' || 'currentlyreading' || 'onhold' || 'paused' =>
      EntryStatus.reading,
    'drop' => EntryStatus.dropped,
    'cancel' || 'canceled' => EntryStatus.cancelled,
    _ => null,
  };
}

/// "120", "120.0", "Ch. 120", "120/300" → 120.
int? _toInt(String raw) {
  final m = RegExp(r'\d+(\.\d+)?').firstMatch(raw);
  if (m == null) return null;
  return double.tryParse(m.group(0)!)?.floor();
}

bool _isBlank(List<String> row) => row.every((c) => c.trim().isEmpty);
