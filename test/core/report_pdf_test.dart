// PDF reports (stream 5 WP5): the bytes are a PDF, Barlow is embedded (and subset), the text a reader extracts is the
// report's (decoded from the uncompressed file through the fonts' ToUnicode maps), units are respected, characters
// Barlow lacks become "?" with a footer note, every table row is printed (pages grow), and region sections that are not
// ready say so. No network: the pdf package is pure Dart and nothing here fetches anything.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_report.dart';
import 'package:meshsonar/core/drive_report_pdf.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/region_report_export.dart';
import 'package:meshsonar/core/region_report_pdf.dart';
import 'package:meshsonar/core/report_pdf.dart';
import 'package:meshsonar/core/units.dart';

import 'pdf_text.dart';

ByteData _font(String n) => ByteData.sublistView(File('assets/fonts/$n').readAsBytesSync());
final fonts = ReportFonts(regular: _font('Barlow-Regular.ttf'), bold: _font('Barlow-SemiBold.ttf'));

final t0 = DateTime.utc(2026, 10, 16, 18);
DateTime wall(DateTime t) => t.subtract(const Duration(hours: 4)); // EDT

DriveReport report() {
  const mPerDegLat = 111195.0802;
  DrivePing p(String id, int sec, double north, {List<Echo> echoes = const [], double? noise, double? speed, double? acc}) => DrivePing(
      id: id,
      ts: t0.add(Duration(seconds: sec)),
      lat: 40.1 + north / mPerDegLat,
      lon: -82.93,
      echoes: echoes,
      noiseFloorDbm: noise,
      txDbm: 22,
      speedMps: speed,
      gpsAccuracyM: acc);
  final lookup = RepeaterLookup([
    (RepeaterSource.cmat, const [RepeaterRef(key: 'a1b2c3d4', name: 'Westerville North 📡', lat: 40.1, lon: -82.93)]),
  ]);
  return DriveReport.compute(
    session: DriveSession(id: 'd1', startedAt: t0, endedAt: t0.add(const Duration(minutes: 10))),
    pings: [
      p('1', 0, 1500, noise: -108, speed: 10, acc: 4, echoes: const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]),
      p('2', 60, 2500, noise: -96, speed: 20, acc: 6, echoes: const [Echo(repeater: 'a1b2', snrDb: 9, hops: 1)]),
      p('3', 120, 5000, noise: -104, speed: 20, acc: 60),
      p('4', 180, 8000, noise: -103, speed: 3, acc: 5, echoes: const [Echo(repeater: 'a1b2', snrDb: -2, hops: 1)]),
    ],
    lookup: lookup,
    cmatListLoaded: true,
  );
}

Map<String, dynamic> regionBody() =>
    jsonDecode(File('test/fixtures/region_report_cmh.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('drive report PDF', () {
    test('a real PDF with Barlow embedded and the report text in it', () async {
      final doc = driveReportPdf(report(), title: 'Morning loop', units: Units.metric, wall: wall, zone: 'EDT');
      final bytes = await renderReportPdf(doc, fonts: fonts, compress: false);
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final raw = latin1.decode(bytes);
      expect(raw, contains('/BaseFont/Barlow-Regular'));
      expect(raw, contains('/BaseFont/Barlow-SemiBold'));
      expect(raw, contains('/FontFile2'));
      final text = pdfText(bytes);
      for (final s in [
        'MeshSonar drive report: Morning loop',
        'Started Fri 16 Oct 2026, 14:00 (EDT)',
        'Units: metric',
        'Grid cells',
        'SNR of the strongest reply',
        '4 pings, 3 heard, 1 heard nothing.',
        'Noise floor (dBm), lower is quieter',
        'Median -103.5 dBm',
        'TX power 22.0 dBm throughout.',
        'Signal by distance to the repeater',
        'Heard % by speed',
        'Repeaters heard (1)',
        'Page 1 of',
      ]) {
        expect(text, contains(s), reason: s);
      }
      // Barlow has no emoji: the repeater name keeps its text, the emoji becomes "?", and the footer says why.
      expect(text, contains('Westerville North ?'));
      expect(text, contains('Characters the embedded font lacks are shown as "?".'));
      expect(text, contains('km'));
      expect(text, isNot(contains(' mi ')));
    });

    test('imperial units throughout, no km', () async {
      final doc = driveReportPdf(report(), title: 'Loop', units: Units.imperial, wall: wall, zone: 'EDT');
      final all = doc.texts.join('\n');
      expect(all, contains('Units: imperial'));
      expect(all, contains(' mi'));
      expect(all, contains('mph'));
      expect(all, isNot(contains('km')));
    });

    test('compressed output (what the app shares) is smaller and still a PDF', () async {
      final doc = driveReportPdf(report(), title: 'Loop', units: Units.metric, wall: wall, zone: 'EDT');
      final small = await renderReportPdf(doc, fonts: fonts);
      final big = await renderReportPdf(doc, fonts: fonts, compress: false);
      expect(latin1.decode(small.sublist(0, 5)), '%PDF-');
      expect(small.length, lessThan(big.length));
      // Barlow is subset to the characters used, not the whole 100 KB+ font.
      expect(small.length, lessThan(120 * 1024));
    });

    test('a drive without radio readings says so instead of drawing empty charts', () {
      final r = DriveReport.compute(
        session: DriveSession(id: 'x', startedAt: t0),
        pings: [DrivePing(id: 'a', ts: t0, lat: 40, lon: -83)],
      );
      final doc = driveReportPdf(r, title: 'Quiet', units: Units.metric, wall: wall, zone: 'EDT');
      expect(doc.texts, contains('Your radio did not report a noise floor for this drive.'));
      expect(doc.blocks.whereType<PdfLine>().map((b) => b.title), isNot(contains('Noise floor (dBm), lower is quieter')));
    });
  });

  group('region report PDF', () {
    test('overview, repeaters, observers, RF, paths and coverage from the recorded body', () async {
      final e = RegionReportExport(regionBody());
      final bytes = await renderReportPdf(regionReportPdf(e, units: Units.metric), fonts: fonts, compress: false);
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final text = pdfText(bytes);
      for (final s in [
        'MeshSonar region report: Columbus, US (CMH)',
        'Times are UTC',
        'Overview, last 24 h',
        'INNO-ALBANY-WEST',
        'MeshThor R2',
        '62 active, 152 quiet, 123 new, 1 stale.',
        'Noise floor by hour of day (mean dBm, UTC)',
        'SNR of received packets',
        'Hops per packet',
        'Top carriers',
        'Coverage by MeshSonar drives',
        'Every column is in the CSV export',
      ]) {
        expect(text, contains(s), reason: s);
      }
    });

    test('every repeater row is printed: 350 rows run over several pages', () async {
      final b = regionBody();
      final rows = (b['repeaters'] as Map)['rows'] as List;
      final first = Map<String, dynamic>.from(rows.first as Map);
      (b['repeaters'] as Map)['rows'] = [for (var i = 0; i < 350; i++) {...first, 'name': 'Rep $i'}];
      final bytes = await renderReportPdf(regionReportPdf(RegionReportExport(b), units: Units.metric), fonts: fonts, compress: false);
      final text = pdfText(bytes);
      expect(text, contains('Rep 0'));
      expect(text, contains('Rep 349'));
      expect(pdfPageCount(bytes), greaterThan(5));
    });

    test('a section the server marks partial quotes the reason; null km is a dash; imperial distance', () {
      final b = regionBody();
      (b['observers'] as Map)['status'] = {'state': 'partial', 'reason': 'One observer is offline.'};
      (b['coverage'] as Map)['km'] = 120.5;
      final doc = regionReportPdf(RegionReportExport(b), units: Units.imperial);
      expect(doc.texts, contains('Server status for this section: partial. One observer is offline.'));
      expect(doc.texts.join('\n'), contains('75 mi'));
      (b['coverage'] as Map)['km'] = null;
      final facts = regionReportPdf(RegionReportExport(b), units: Units.metric).blocks.whereType<PdfFacts>().last;
      expect(facts.rows, contains(('Distance', '—')));
    });

    test('an empty body still renders a valid PDF (every section empty, nothing invented)', () async {
      final bytes = await renderReportPdf(regionReportPdf(const RegionReportExport({}), units: Units.metric), fonts: fonts);
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final doc = regionReportPdf(const RegionReportExport({}), units: Units.metric);
      expect(doc.texts, contains('No noise floor readings.'));
      expect(doc.blocks.whereType<PdfBars>(), isEmpty);
    });
  });

  test('without fonts (Helvetica, Latin-1) non-Latin-1 text is replaced, not a crash', () async {
    final bytes = await renderReportPdf(const ReportDoc(title: 'Ünïcode → 📡', blocks: [PdfText('ok')], footer: 'f'), compress: false);
    final raw = latin1.decode(bytes);
    expect(raw, startsWith('%PDF-'));
    expect(raw, contains('(?)')); // the arrow and the emoji
  });
}
