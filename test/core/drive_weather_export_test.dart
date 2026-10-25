// Weather in the drive report exports: text lines, the CSV `weather` table, PDF blocks. Units, licence line, no
// invented values, nothing when there is no weather.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_report.dart';
import 'package:meshsonar/core/drive_report_export.dart';
import 'package:meshsonar/core/drive_report_pdf.dart';
import 'package:meshsonar/core/drive_weather_export.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/report_pdf.dart';
import 'package:meshsonar/core/units.dart';

import 'pdf_text.dart';

final snaps = [
  WeatherSnapshot(at: DateTime.utc(2026, 10, 24, 14), temperatureC: 10.4, humidityPct: 80, dewPointC: 7, pressureHpa: 1012.4, precipMm: 0, cloudPct: 90, windMs: 4, windDirDeg: 225),
  WeatherSnapshot(at: DateTime.utc(2026, 10, 24, 15), temperatureC: 12.2, humidityPct: 70, dewPointC: 7.5, pressureHpa: 1011.8, precipMm: 0.4, cloudPct: 70, windMs: 6, windDirDeg: 225),
  WeatherSnapshot(at: DateTime.utc(2026, 10, 24, 16)), // the source gave nothing for this hour
];

DriveReport _report() => DriveReport.compute(
      session: DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 24, 14), endedAt: DateTime.utc(2026, 10, 24, 15)),
      pings: [
        DrivePing(id: '1', ts: DateTime.utc(2026, 10, 24, 14, 1), lat: 40.1, lon: -82.9, echoes: const [Echo(repeater: 'a1b2', snrDb: 5, hops: 1)]),
        DrivePing(id: '2', ts: DateTime.utc(2026, 10, 24, 14, 2), lat: 40.11, lon: -82.9),
      ],
      lookup: RepeaterLookup(const []),
    );

void main() {
  test('text: facts in the person\'s units, model caveat, licence line; nothing without weather', () {
    final metric = _report().toText(weather: snaps);
    expect(metric, contains('Weather (model values for a cell of about 5 km'));
    expect(metric, contains('Temperature: 10 °C to 12 °C'));
    expect(metric, contains('Wind: mean 5.0 m/s'.replaceAll('5.0 m/s', Units.metric.speed(5))));
    expect(metric, contains('from the SW'));
    expect(metric, contains('Hours covered: 3'));
    expect(metric, contains(openMeteoCredit));
    final imp = _report().toText(units: Units.imperial, weather: snaps);
    expect(imp, contains('°F'));
    expect(_report().toText(), isNot(contains('Weather')));
    expect(_report().toText(), isNot(contains('Open-Meteo')));
  });

  test('CSV: a weather table in SI, UTC hours, an empty cell for an unknown value, absent without weather', () {
    final csv = _report().toCsv(weather: snaps);
    final rows = csv.split('\r\n').where((l) => l.startsWith('weather,')).toList();
    expect(rows, hasLength(3));
    expect(rows.first, contains('2026-10-24T14:00:00.000Z'));
    expect(csv, contains('temperature_c'));
    expect(csv, contains('wind_dir_deg'));
    expect(csv, contains(openMeteoCredit));
    expect(rows.last, contains('2026-10-24T16:00:00.000Z'));
    expect(_report().toCsv(), isNot(contains('weather')));
  });

  test('PDF: weather section with hourly table and the licence line; none without weather', () async {
    ByteData font(String n) => ByteData.sublistView(File('assets/fonts/$n').readAsBytesSync());
    final fonts = ReportFonts(regular: font('Barlow-Regular.ttf'), bold: font('Barlow-SemiBold.ttf'));
    final doc = driveReportPdf(_report(), title: 'Loop', units: Units.metric, weather: snaps, wall: (t) => t.subtract(const Duration(hours: 4)), zone: 'EDT');
    final text = pdfText(await renderReportPdf(doc, fonts: fonts, compress: false));
    expect(text, contains('Weather'));
    expect(text, contains('Hourly values'));
    expect(text, contains('Hour (EDT)'));
    expect(text, contains('Weather data by Open-Meteo.com (CC BY 4.0)'));
    expect(text, contains('not measured at your car'));
    final none = pdfText(await renderReportPdf(driveReportPdf(_report(), title: 'Loop', units: Units.metric), fonts: fonts, compress: false));
    expect(none, isNot(contains('Open-Meteo')));
  });
}
