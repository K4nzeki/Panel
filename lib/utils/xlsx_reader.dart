import 'dart:convert';

import 'package:archive/archive.dart';

/// Reads the first worksheet of an .xlsx file into rows of plain text.
///
/// An .xlsx is a zip of XML files; this only needs the cell values, so it
/// reads them directly instead of pulling in a full spreadsheet library.
/// Row positions are kept (blank rows become empty lists) so error messages
/// can point at the right row number in Excel.
List<List<String>> readXlsxRows(List<int> bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException(
        "Couldn't open that file. Save it as .xlsx (not .xls) or .csv and try again.");
  }

  String? text(String path) {
    final f = zip.findFile(path);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  final sheetPath = _firstSheetPath(zip, text);
  final sheetXml = sheetPath == null ? null : text(sheetPath);
  if (sheetXml == null) {
    throw const FormatException('That file has no worksheet in it.');
  }
  final shared = _sharedStrings(text('xl/sharedStrings.xml'));

  final rows = <List<String>>[];
  final rowRe = RegExp(
      r'<(?:\w+:)?row\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?row>)', dotAll: true);
  final cellRe = RegExp(
      r'<(?:\w+:)?c\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?c>)', dotAll: true);

  for (final rm in rowRe.allMatches(sheetXml)) {
    final rowNo = int.tryParse(_attr(rm.group(1)!, 'r') ?? '');
    final rowIndex = rowNo != null ? rowNo - 1 : rows.length;
    while (rows.length < rowIndex) {
      rows.add(<String>[]);
    }
    final cells = <String>[];
    for (final cm in cellRe.allMatches(rm.group(2) ?? '')) {
      final attrs = cm.group(1)!;
      final body = cm.group(2) ?? '';
      final ref = _attr(attrs, 'r');
      final col = ref != null ? _columnIndex(ref) : cells.length;
      while (cells.length < col) {
        cells.add('');
      }
      final value = _cellValue(_attr(attrs, 't'), body, shared);
      if (cells.length == col) {
        cells.add(value);
      } else {
        cells[col] = value;
      }
    }
    if (rows.length == rowIndex) {
      rows.add(cells);
    } else if (rowIndex >= 0 && rowIndex < rows.length) {
      rows[rowIndex] = cells;
    }
  }
  return rows;
}

String? _firstSheetPath(Archive zip, String? Function(String) text) {
  // workbook.xml lists sheets in tab order; its .rels maps them to files.
  final wb = text('xl/workbook.xml');
  final rels = text('xl/_rels/workbook.xml.rels');
  if (wb != null && rels != null) {
    final sheet = RegExp(r'<(?:\w+:)?sheet\b([^>]*)/?>').firstMatch(wb);
    final rid = sheet == null ? null : _attr(sheet.group(1)!, 'r:id');
    if (rid != null) {
      for (final m in RegExp(r'<Relationship\b([^>]*)/?>').allMatches(rels)) {
        if (_attr(m.group(1)!, 'Id') == rid) {
          var target = _attr(m.group(1)!, 'Target') ?? '';
          target = target.startsWith('/')
              ? target.substring(1)
              : 'xl/$target';
          if (zip.findFile(target) != null) return target;
        }
      }
    }
  }
  // Fallback: the lowest-numbered sheetN.xml.
  final sheets = zip.files
      .map((f) => f.name)
      .where((n) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(n))
      .toList()
    ..sort((a, b) => _num(a).compareTo(_num(b)));
  return sheets.isEmpty ? null : sheets.first;
}

int _num(String s) => int.parse(RegExp(r'(\d+)\.xml$').firstMatch(s)!.group(1)!);

List<String> _sharedStrings(String? xml) {
  if (xml == null) return const [];
  final out = <String>[];
  final siRe = RegExp(r'<(?:\w+:)?si\b[^>]*?(?:/>|>(.*?)</(?:\w+:)?si>)',
      dotAll: true);
  for (final m in siRe.allMatches(xml)) {
    out.add(_joinText(m.group(1) ?? ''));
  }
  return out;
}

/// All the `<t>` pieces of a string (rich text is split into runs), minus
/// phonetic hints (`<rPh>`) that Excel stores for Japanese text.
String _joinText(String xml) {
  final clean = xml.replaceAll(
      RegExp(r'<(?:\w+:)?rPh\b.*?</(?:\w+:)?rPh>', dotAll: true), '');
  final buf = StringBuffer();
  for (final t in RegExp(r'<(?:\w+:)?t\b[^>]*?(?:/>|>(.*?)</(?:\w+:)?t>)',
          dotAll: true)
      .allMatches(clean)) {
    buf.write(_unescape(t.group(1) ?? ''));
  }
  return buf.toString();
}

String _cellValue(String? type, String body, List<String> shared) {
  final v = RegExp(r'<(?:\w+:)?v\b[^>]*>(.*?)</(?:\w+:)?v>', dotAll: true)
      .firstMatch(body)
      ?.group(1);
  switch (type) {
    case 's':
      final i = int.tryParse(v ?? '');
      return (i != null && i >= 0 && i < shared.length) ? shared[i] : '';
    case 'inlineStr':
      return _joinText(body);
    case 'str':
      return _unescape(v ?? '');
    case 'b':
      return v == '1' ? 'TRUE' : 'FALSE';
    case 'e':
      return '';
    default:
      if (v == null) return '';
      final d = double.tryParse(v);
      if (d != null && d == d.truncateToDouble() && d.abs() < 1e15) {
        return d.toInt().toString(); // 120.0 → "120"
      }
      return _unescape(v);
  }
}

String? _attr(String attrs, String name) {
  final m = RegExp('(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*("([^"]*)"|\'([^\']*)\')')
      .firstMatch(attrs);
  if (m == null) return null;
  return _unescape(m.group(2) ?? m.group(3) ?? '');
}

/// "A1" → 0, "B7" → 1, "AA3" → 26.
int _columnIndex(String ref) {
  var n = 0;
  for (final ch in ref.toUpperCase().codeUnits) {
    if (ch < 65 || ch > 90) break;
    n = n * 26 + (ch - 64);
  }
  return n == 0 ? 0 : n - 1;
}

String _unescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'),
      (m) {
    final e = m.group(1)!;
    switch (e) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = e.startsWith('#x')
        ? int.tryParse(e.substring(2), radix: 16)
        : int.tryParse(e.substring(1));
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
}
