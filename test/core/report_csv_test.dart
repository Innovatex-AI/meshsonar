// CSV the website's way (report-tables.ts csvCell/toCsv): quoting, formula neutralising of strings only, JS number
// printing, CRLF, and the one-file "table" column layout.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/report_csv.dart';

void main() {
  test('cells: null, numbers like JavaScript String(n), booleans', () {
    expect(csvCell(null), '');
    expect(csvCell(12), '12');
    expect(csvCell(12.0), '12');
    expect(csvCell(-97.1), '-97.1');
    expect(csvCell(0.5), '0.5');
    expect(csvCell(double.nan), '');
    expect(csvCell(true), 'true');
    expect(csvCell(false), 'false');
  });

  test('quoting: comma, quote, CR, LF; inner quotes doubled', () {
    expect(csvCell('a,b'), '"a,b"');
    expect(csvCell('say "hi"'), '"say ""hi"""');
    expect(csvCell('two\nlines'), '"two\nlines"');
    expect(csvCell('plain'), 'plain');
  });

  test('formula neutralising applies to strings only, never to numbers', () {
    expect(csvCell('=cmd()'), "'=cmd()");
    expect(csvCell('+1'), "'+1");
    expect(csvCell('-x'), "'-x");
    expect(csvCell('@me'), "'@me");
    expect(csvCell(-97.1), '-97.1');
    expect(csvCell('=a,b'), '"\'=a,b"');
  });

  test('toCsv: header first, CRLF after every row including the last; empty table is the header only', () {
    expect(toCsv(['a', 'b'], [[1, 'x'], [null, 2.5]]), 'a,b\r\n1,x\r\n,2.5\r\n');
    expect(toCsv(['a'], const []), 'a\r\n');
  });

  test('combinedCsv: table column first, union of columns, shared column names merge, empty cells elsewhere', () {
    const t1 = ReportTable(id: 'pings', label: 'Pings', head: ['id', 'snr_db'], rows: [['p1', 3.5]]);
    const t2 = ReportTable(id: 'repeaters', label: 'Repeaters', head: ['id', 'name'], rows: [['ab', 'North'], ['cd', null]]);
    const t3 = ReportTable(id: 'empty', label: 'Empty', head: ['x'], rows: []);
    expect(combinedCsv([t1, t2, t3]), 'table,id,snr_db,name,x\r\npings,p1,3.5,,\r\nrepeaters,ab,,North,\r\nrepeaters,cd,,,\r\n');
  });

  test('fileSlug', () {
    expect(fileSlug('Drive to Columbus!'), 'drive-to-columbus');
    expect(fileSlug('***'), 'report');
    expect(fileSlug('x' * 80).length, 48);
  });
}
