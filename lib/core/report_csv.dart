// CSV for every report export (drive report, region report), written exactly the way the website writes its report
// CSVs (meshcore-insights src/components/region/report-tables.ts, `csvCell` / `toCsv`), so a file from the app and one
// from the site open the same in a spreadsheet:
//   - null is an empty cell; numbers print like JavaScript's String(n) (12, not 12.0); booleans print true/false;
//   - a STRING cell starting with = + - @ tab or CR gets a leading ' (names come from radios; a spreadsheet would run
//     "=cmd" as a formula). Numbers are never altered, so -97.1 stays -97.1;
//   - a cell with a comma, quote, CR or LF is quoted, inner quotes doubled;
//   - rows end with CRLF, the last one too; UTF-8, no BOM.
// Pure Dart: no Flutter imports.

final _formula = RegExp(r'^[=+\-@\t\r]');
final _needsQuote = RegExp(r'[",\r\n]');

/// A number as JavaScript's `String(n)` prints it for the values reports carry: integral doubles without ".0".
/// Non-finite numbers (never real data) become an empty cell.
String jsNumber(num v) {
  if (v is int) return '$v';
  if (!v.isFinite) return '';
  if (v == v.truncateToDouble() && v.abs() < 1e21) return '${v.toInt()}';
  return '$v';
}

/// One CSV cell (see the header for the rules).
String csvCell(Object? v) {
  if (v == null) return '';
  String s;
  if (v is num) {
    s = jsNumber(v);
  } else if (v is bool) {
    s = v ? 'true' : 'false';
  } else {
    s = '$v';
    if (_formula.hasMatch(s)) s = "'$s";
  }
  return _needsQuote.hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// A whole CSV file: [head] then [rows], CRLF line ends.
String toCsv(List<String> head, List<List<Object?>> rows) {
  final b = StringBuffer();
  for (final r in [head, ...rows]) {
    b
      ..write(r.map(csvCell).join(','))
      ..write('\r\n');
  }
  return b.toString();
}

/// One exportable table: a stable [id] (also the file-name suffix), a human [label], column names and raw cells
/// (String, num, bool or null; SI units, UTC ISO times).
class ReportTable {
  final String id;
  final String label;
  final List<String> head;
  final List<List<Object?>> rows;
  const ReportTable({required this.id, required this.label, required this.head, required this.rows});

  bool get isEmpty => rows.isEmpty;
  String toCsv() => toCsvFile(this);
}

String toCsvFile(ReportTable t) => toCsv(t.head, t.rows);

/// Several tables in ONE file: the first column `table` names the table a row belongs to, then the union of every
/// table's columns in first-seen order (a column two tables share, such as `key`, is one column). Cells a table does
/// not have are empty. Filter on `table` in a spreadsheet to get one table back. Empty tables add no rows.
String combinedCsv(List<ReportTable> tables) {
  final cols = <String>[];
  for (final t in tables) {
    for (final h in t.head) {
      if (!cols.contains(h)) cols.add(h);
    }
  }
  final rows = <List<Object?>>[];
  for (final t in tables) {
    final at = [for (final h in t.head) cols.indexOf(h)];
    for (final r in t.rows) {
      final out = List<Object?>.filled(cols.length + 1, null);
      out[0] = t.id;
      for (var i = 0; i < at.length && i < r.length; i++) {
        out[at[i] + 1] = r[i];
      }
      rows.add(out);
    }
  }
  return toCsv(['table', ...cols], rows);
}

/// A file-name-safe slug ("Drive to Columbus!" -> "drive-to-columbus"); [fallback] when nothing is left.
String fileSlug(String s, {String fallback = 'report'}) {
  final x = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (x.isEmpty) return fallback;
  return x.length > 48 ? x.substring(0, 48).replaceAll(RegExp(r'-+$'), '') : x;
}
