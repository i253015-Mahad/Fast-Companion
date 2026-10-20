// lib/services/csv_reader.dart

/// Minimal RFC-4180 CSV reader: quoted fields, doubled quotes as
/// escapes, and newlines inside quotes.
///
/// Extracted from `TimetableService`, which grew this after finding that
/// Google's CSV exports routinely break naive `split(',')` — a course
/// code can carry a comma inside its name, and the faculty-offices sheet
/// stores names and designations with both commas and line breaks in
/// them. Shared so the directory and the timetable read a sheet the same
/// way rather than drifting into two slightly different readers.
///
/// Lines are separated by `\n`, with `\r` dropped — the exports are
/// CRLF, and a parser that keeps the carriage return leaves every field
/// in the file looking clean while every field from the last column of a
/// row carries a `\r` nobody can see until it is printed.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field = StringBuffer();
    } else if (c == '\n') {
      row.add(field.toString());
      rows.add(row);
      row = <String>[];
      field = StringBuffer();
    } else if (c != '\r') {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
