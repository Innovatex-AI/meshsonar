// Reads the text back out of an UNCOMPRESSED PDF made by the pdf package with embedded TTF fonts (report_pdf.dart with
// compress: false). Text there is drawn as hex glyph-index strings (`[<0001000200>]TJ`) under `/F6 9.5 Tf`; each Type0
// font names its /ToUnicode CMap object, whose `<XXXX> <YYYY>` lines map those indices back to Unicode. Good enough
// for these tests (the pdf package's own output), not a general PDF parser.
import 'dart:convert';
import 'dart:typed_data';

/// Every text run in drawing order, decoded, joined with single spaces.
String pdfText(Uint8List bytes) {
  final s = latin1.decode(bytes);
  final cmaps = <String, Map<int, int>>{};
  final fontRe = RegExp(r'/Subtype/Type0/Name/(F\d+).*?/ToUnicode (\d+) 0 R', dotAll: true);
  for (final m in fontRe.allMatches(s)) {
    final obj = RegExp('(?:^|\\n)${m.group(2)} 0 obj(.*?)endobj', dotAll: true).firstMatch(s);
    if (obj == null) continue;
    final map = <int, int>{};
    for (final p in RegExp(r'<([0-9A-Fa-f]{4})> <([0-9A-Fa-f]{4,})>').allMatches(obj.group(1)!)) {
      map[int.parse(p.group(1)!, radix: 16)] = int.parse(p.group(2)!, radix: 16);
    }
    cmaps[m.group(1)!] = map;
  }
  final out = <String>[];
  Map<int, int>? font;
  for (final m in RegExp(r'/(F\d+) [\d.]+ Tf|\[<([0-9A-Fa-f]*)>\]TJ').allMatches(s)) {
    if (m.group(1) != null) {
      font = cmaps[m.group(1)!];
      continue;
    }
    final hex = m.group(2)!;
    final b = StringBuffer();
    for (var i = 0; i + 4 <= hex.length; i += 4) {
      final cid = int.parse(hex.substring(i, i + 4), radix: 16);
      final u = font?[cid];
      if (u != null) b.writeCharCode(u);
    }
    out.add(b.toString());
  }
  return out.join(' ');
}

/// Pages in the file (`/Type/Page` objects, not `/Type/Pages`).
int pdfPageCount(Uint8List bytes) => RegExp(r'/Type/Page[^s]').allMatches(latin1.decode(bytes)).length;
