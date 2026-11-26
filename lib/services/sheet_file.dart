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
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx', 'csv'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.single;
  final bytes = file.bytes;
  if (bytes == null) {
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
