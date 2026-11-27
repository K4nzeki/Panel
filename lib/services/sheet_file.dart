import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import '../utils/sheet_import.dart';
import '../utils/xlsx_reader.dart';

/// A spreadsheet the user picked, already turned into plain text rows.
class PickedSheet {
  const PickedSheet(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

/// Opens the file picker for an Excel (.xlsx) or CSV file and reads the
/// first sheet. Returns null if the user cancels.
Future<PickedSheet?> pickSheetFile() async {
  // file_picker 12+: pickFiles is static and returns a list (empty when
  // cancelled). 13 removed withData: the bytes are read from the file.
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx', 'csv'],
  );
  if (files.isEmpty) return null;
  final file = files.first;
  final List<int> bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    throw const FormatException("Couldn't read that file.");
  }
  if (bytes.isEmpty) {
    throw const FormatException("Couldn't read that file.");
  }
  final name = file.name;
  final lower = name.toLowerCase();
  if (lower.endsWith('.csv')) {
    return PickedSheet(name, parseCsv(utf8.decode(bytes, allowMalformed: true)));
  }
  if (lower.endsWith('.xls')) {
    throw const FormatException(
        'Old .xls files aren\'t supported. In Excel use Save As → .xlsx or .csv.');
  }
  return PickedSheet(name, readXlsxRows(bytes));
}
