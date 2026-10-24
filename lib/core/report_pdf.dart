// PDF reports (stream 5 WP5): a small document model (headings, text, facts, tables, bar and line charts) and its
// renderer on the `pdf` package (Apache-2.0, pure Dart, no network; NOT `printing`, which is a native plugin whose font
// helpers download from Google's font CDN, a host this app does not contact). Charts are vector drawings made with the
// pdf package's own graphics, each followed by its numbers in words (the PDF is not tagged, so the sentence is what a
// screen reader gets; the CSV and text exports stay the accessible formats).
//
// Fonts: Barlow from the app's assets (SIL OFL 1.1, which allows embedding in documents) when [ReportFonts] is given,
// subset by the pdf package; without it the built-in Helvetica (Latin-1 only; tests). Characters the font lacks are
// replaced by "?" and the footer says so, so a repeater name with an emoji never breaks the file.
// Builders: drive_report_pdf.dart, region_report_pdf.dart. Pure Dart: no Flutter imports.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Regular and bold TTF bytes (Barlow-Regular.ttf, Barlow-SemiBold.ttf from assets/fonts).
class ReportFonts {
  final ByteData regular;
  final ByteData bold;
  const ReportFonts({required this.regular, required this.bold});
}

sealed class PdfBlock {
  const PdfBlock();

  /// Every human-readable string in the block.
  Iterable<String> get texts;
}

class PdfHeading extends PdfBlock {
  final String text;
  const PdfHeading(this.text);
  @override
  Iterable<String> get texts => [text];
}

class PdfText extends PdfBlock {
  final String text;
  final bool muted;
  const PdfText(this.text, {this.muted = false});
  @override
  Iterable<String> get texts => [text];
}

/// Label / value pairs in two columns.
class PdfFacts extends PdfBlock {
  final List<(String, String)> rows;
  const PdfFacts(this.rows);
  @override
  Iterable<String> get texts => [for (final (k, v) in rows) ...[k, v]];
}

class PdfTable extends PdfBlock {
  final String title;
  final List<String> head;
  final List<List<String>> rows;

  /// Columns aligned right (numbers).
  final Set<int> numeric;
  final String? note;
  const PdfTable({required this.title, required this.head, required this.rows, this.numeric = const {}, this.note});
  @override
  Iterable<String> get texts => [title, ...head, for (final r in rows) ...r, ?note];
}

/// Vertical bars standing on [base]; null = no bar (unknown is not zero).
class PdfBars extends PdfBlock {
  final String title;
  final String summary;
  final List<String> labels;
  final List<double?> values;
  final double base;
  final double? refLine;
  final String yLabel;
  final int labelEvery;
  final String? caption;
  const PdfBars({
    required this.title,
    required this.summary,
    required this.labels,
    required this.values,
    this.base = 0,
    this.refLine,
    required this.yLabel,
    this.labelEvery = 1,
    this.caption,
  });
  @override
  Iterable<String> get texts => [title, summary, yLabel, ?caption];
}

/// A line over time; the line breaks where points are more than [breakGap] apart. [marks]: short ticks on the x axis
/// (e.g. pings that heard nothing).
class PdfLine extends PdfBlock {
  final String title;
  final String summary;
  final List<(DateTime, double)> points;
  final List<DateTime> marks;
  final String yLabel;
  final double? refLine;
  final Duration? breakGap;
  final String startLabel, endLabel;
  final String? caption;
  const PdfLine({
    required this.title,
    required this.summary,
    required this.points,
    this.marks = const [],
    required this.yLabel,
    this.refLine,
    this.breakGap,
    required this.startLabel,
    required this.endLabel,
    this.caption,
  });
  @override
  Iterable<String> get texts => [title, summary, yLabel, startLabel, endLabel, ?caption];
}

class ReportDoc {
  final String title;
  final List<String> subtitle;
  final List<PdfBlock> blocks;
  final String footer;
  const ReportDoc({required this.title, this.subtitle = const [], required this.blocks, required this.footer});

  Iterable<String> get texts => [title, ...subtitle, for (final b in blocks) ...b.texts, footer];
}

// Colours fixed for print (white paper), close to the app's light theme.
final _ink = PdfColor.fromHex('#10222C');
final _muted = PdfColor.fromHex('#4A6270');
final _grid = PdfColor.fromHex('#C9D6DD');
final _bar = PdfColor.fromHex('#0B7A8C');
final _line = PdfColor.fromHex('#0B7A8C');
final _ref = PdfColor.fromHex('#C0392B');
final _headBg = PdfColor.fromHex('#E6EEF2');

/// Replaces characters [has] says the font lacks with "?". Returns the text and whether anything was replaced.
(String, bool) _clean(String s, bool Function(int rune) has) {
  var changed = false;
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x0A || has(r)) {
      b.writeCharCode(r);
    } else {
      b.write('?');
      changed = true;
    }
  }
  return (b.toString(), changed);
}

/// Renders [doc]. [compress] false writes plain streams (tests read the text back).
Future<Uint8List> renderReportPdf(ReportDoc doc, {ReportFonts? fonts, bool compress = true}) async {
  final bool Function(int) has;
  pw.ThemeData? theme;
  if (fonts != null) {
    final map = TtfParser(fonts.regular).charToGlyphIndexMap;
    has = (r) => r == 0x20 || map.containsKey(r);
    theme = pw.ThemeData.withFont(base: pw.Font.ttf(fonts.regular), bold: pw.Font.ttf(fonts.bold));
  } else {
    has = (r) => r >= 0x20 && r <= 0x7E || r >= 0xA0 && r <= 0xFF;
  }
  var replaced = false;
  String c(String s) {
    final (out, changed) = _clean(s, has);
    if (changed) replaced = true;
    return out;
  }

  // Build every widget first so `replaced` is known before the footer is laid out.
  final body = <pw.Widget>[
    pw.Text(c(doc.title), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
    pw.SizedBox(height: 4),
    for (final s in doc.subtitle) pw.Text(c(s), style: pw.TextStyle(fontSize: 9, color: _muted)),
    pw.SizedBox(height: 10),
    for (final b in doc.blocks) ..._block(b, c),
  ];
  final footer = c(doc.footer);
  final note = replaced ? ' Characters the embedded font lacks are shown as "?".' : '';

  final pdf = pw.Document(compress: compress, title: c(doc.title), author: 'MeshSonar', creator: 'MeshSonar', producer: 'MeshSonar');
  pdf.addPage(pw.MultiPage(
    theme: theme,
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
    footer: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Row(children: [
        pw.Expanded(child: pw.Text('$footer$note', style: pw.TextStyle(fontSize: 7, color: _muted))),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: _muted)),
      ]),
    ),
    build: (_) => body,
  ));
  return pdf.save();
}

List<pw.Widget> _block(PdfBlock b, String Function(String) c) {
  final small = pw.TextStyle(fontSize: 8, color: _muted);
  switch (b) {
    case PdfHeading(:final text):
      return [
        pw.SizedBox(height: 10),
        pw.Text(c(text), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 4),
      ];
    case PdfText(:final text, :final muted):
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Text(c(text), style: muted ? small : pw.TextStyle(fontSize: 9.5, color: _ink)),
        ),
      ];
    case PdfFacts(:final rows):
      return [
        pw.Table(columnWidths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(3)}, children: [
          for (final (k, v) in rows)
            pw.TableRow(children: [
              pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 1.5), child: pw.Text(c(k), style: small)),
              pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 1.5), child: pw.Text(c(v), style: pw.TextStyle(fontSize: 9.5, color: _ink))),
            ]),
        ]),
        pw.SizedBox(height: 6),
      ];
    case PdfTable(:final title, :final head, :final rows, :final numeric, :final note):
      return [
        pw.SizedBox(height: 6),
        pw.Text(c(title), style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 3),
        if (rows.isEmpty)
          pw.Text('No rows.', style: small)
        else
          pw.TableHelper.fromTextArray(
            headers: [for (final h in head) c(h)],
            data: [for (final r in rows) [for (var i = 0; i < head.length; i++) c(i < r.length ? r[i] : '')]],
            headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _ink),
            cellStyle: pw.TextStyle(fontSize: 7.5, color: _ink),
            headerDecoration: pw.BoxDecoration(color: _headBg),
            headerAlignment: pw.Alignment.centerLeft,
            cellAlignment: pw.Alignment.centerLeft,
            cellAlignments: {for (final i in numeric) i: pw.Alignment.centerRight},
            headerAlignments: {for (final i in numeric) i: pw.Alignment.centerRight},
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _grid, width: 0.5), bottom: pw.BorderSide(color: _grid, width: 0.5)),
          ),
        if (note != null) pw.Padding(padding: const pw.EdgeInsets.only(top: 3), child: pw.Text(c(note), style: small)),
        pw.SizedBox(height: 6),
      ];
    case PdfBars():
      return _chart(b.title, b.summary, b.caption, b.yLabel, c, _barsWidget(b, c));
    case PdfLine():
      return _chart(b.title, b.summary, b.caption, b.yLabel, c, _lineWidget(b, c));
  }
}

List<pw.Widget> _chart(String title, String summary, String? caption, String yLabel, String Function(String) c, pw.Widget chart) {
  final small = pw.TextStyle(fontSize: 8, color: _muted);
  // One unbreakable column, so a chart never starts at the foot of a page and ends on the next.
  return [
    pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(height: 8),
      pw.Text(c(title), style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: _ink)),
      pw.SizedBox(height: 2),
      pw.Text(c(yLabel), style: small),
      pw.SizedBox(height: 2),
      chart,
      pw.SizedBox(height: 3),
      pw.Text(c(summary), style: pw.TextStyle(fontSize: 8.5, color: _ink)),
      if (caption != null) pw.Text(c(caption), style: small),
      pw.SizedBox(height: 6),
    ]),
  ];
}

/// Round top of the scale: 1, 2, 2.5 or 5 times a power of ten at or above [v].
double _niceUp(double v) {
  if (v <= 0) return 1;
  final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  for (final f in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (f * mag >= v - 1e-9) return f * mag;
  }
  return 10 * mag;
}

String _tick(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

const double _chartH = 110;
const double _axisW = 30;

pw.Widget _yAxis(double lo, double hi) {
  final s = pw.TextStyle(fontSize: 6.5, color: _muted);
  return pw.SizedBox(
    width: _axisW,
    height: _chartH,
    child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
      pw.Text(_tick(hi), style: s),
      pw.Text(_tick((lo + hi) / 2), style: s),
      pw.Text(_tick(lo), style: s),
    ]),
  );
}

void _gridLines(PdfGraphics g, PdfPoint size) {
  g
    ..setStrokeColor(_grid)
    ..setLineWidth(0.5);
  for (final f in const [0.0, 0.5, 1.0]) {
    g
      ..moveTo(0, size.y * f)
      ..lineTo(size.x, size.y * f);
  }
  g.strokePath();
}

void _refLine(PdfGraphics g, PdfPoint size, double y) {
  g
    ..setStrokeColor(_ref)
    ..setLineWidth(0.8)
    ..setLineDashPattern([3, 2])
    ..moveTo(0, y)
    ..lineTo(size.x, y)
    ..strokePath()
    ..setLineDashPattern();
}

pw.Widget _barsWidget(PdfBars b, String Function(String) c) {
  var hi = b.base;
  for (final v in b.values) {
    if (v != null && v.isFinite) hi = math.max(hi, v);
  }
  if (b.refLine != null) hi = math.max(hi, b.refLine!);
  final lo = b.base;
  final top = lo + _niceUp(hi - lo == 0 ? 1 : hi - lo);
  final n = math.max(1, b.values.length);
  final every = math.max(1, b.labelEvery);
  final s = pw.TextStyle(fontSize: 6, color: _muted);
  return pw.Column(children: [
    pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _yAxis(lo, top),
      pw.SizedBox(width: 4),
      pw.Expanded(
        child: pw.CustomPaint(
          size: const PdfPoint(double.infinity, _chartH),
          painter: (g, size) {
            _gridLines(g, size);
            double y(double v) => size.y * ((v - lo) / (top - lo)).clamp(0.0, 1.0);
            final slot = size.x / n;
            g.setFillColor(_bar);
            for (var i = 0; i < b.values.length; i++) {
              final v = b.values[i];
              if (v == null || !v.isFinite) continue;
              final h = y(math.max(v, lo));
              if (h <= 0) continue;
              g.drawRect(i * slot + slot * 0.12, 0, slot * 0.76, h);
            }
            g.fillPath();
            if (b.refLine != null) _refLine(g, size, y(b.refLine!));
          },
        ),
      ),
    ]),
    pw.Row(children: [
      pw.SizedBox(width: _axisW + 4),
      pw.Expanded(
        child: pw.Row(children: [
          for (var i = 0; i < b.labels.length; i++)
            pw.Expanded(
              child: i % every == 0 ? pw.Text(c(b.labels[i]), style: s, textAlign: pw.TextAlign.center, maxLines: 1) : pw.SizedBox(),
            ),
        ]),
      ),
    ]),
  ]);
}

pw.Widget _lineWidget(PdfLine l, String Function(String) c) {
  final pts = List.of(l.points)..sort((a, b) => a.$1.compareTo(b.$1));
  final times = [for (final p in pts) p.$1, ...l.marks];
  var lo = double.infinity, hi = -double.infinity;
  for (final p in pts) {
    lo = math.min(lo, p.$2);
    hi = math.max(hi, p.$2);
  }
  if (l.refLine != null) {
    lo = math.min(lo, l.refLine!);
    hi = math.max(hi, l.refLine!);
  }
  if (!lo.isFinite) {
    lo = 0;
    hi = 1;
  }
  lo = lo.floorToDouble();
  hi = hi.ceilToDouble();
  if (hi - lo < 1) hi = lo + 1;
  final s = pw.TextStyle(fontSize: 6.5, color: _muted);
  final t0 = times.isEmpty ? 0 : times.map((t) => t.millisecondsSinceEpoch).reduce(math.min);
  final t1 = times.isEmpty ? 1 : times.map((t) => t.millisecondsSinceEpoch).reduce(math.max);
  final span = math.max(1, t1 - t0);
  return pw.Column(children: [
    pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _yAxis(lo, hi),
      pw.SizedBox(width: 4),
      pw.Expanded(
        child: pw.CustomPaint(
          size: const PdfPoint(double.infinity, _chartH),
          painter: (g, size) {
            _gridLines(g, size);
            double x(DateTime t) => size.x * (t.millisecondsSinceEpoch - t0) / span;
            double y(double v) => size.y * ((v - lo) / (hi - lo));
            if (l.refLine != null) _refLine(g, size, y(l.refLine!));
            g
              ..setStrokeColor(_line)
              ..setLineWidth(1.1)
              ..setLineJoin(PdfLineJoin.round);
            for (var i = 0; i < pts.length; i++) {
              final p = pts[i];
              final gap = i == 0 || (l.breakGap != null && p.$1.difference(pts[i - 1].$1) > l.breakGap!);
              if (gap) {
                g.moveTo(x(p.$1), y(p.$2));
              } else {
                g.lineTo(x(p.$1), y(p.$2));
              }
            }
            g.strokePath();
            g.setFillColor(_line);
            for (final p in pts) {
              g.drawEllipse(x(p.$1), y(p.$2), 1.2, 1.2);
            }
            g.fillPath();
            if (l.marks.isNotEmpty) {
              g
                ..setStrokeColor(_ref)
                ..setLineWidth(0.8);
              for (final m in l.marks) {
                g
                  ..moveTo(x(m), 0)
                  ..lineTo(x(m), 5);
              }
              g.strokePath();
            }
          },
        ),
      ),
    ]),
    pw.Row(children: [
      pw.SizedBox(width: _axisW + 4),
      pw.Text(c(l.startLabel), style: s),
      pw.Spacer(),
      pw.Text(c(l.endLabel), style: s),
    ]),
  ]);
}
