// Weather in the drive report exports (text, CSV, PDF). The server's hourly snapshots (`GET drive-env`, Open-Meteo,
// about a 5 km cell, one row per UTC hour) are written as the model values they are, never as a measurement at the
// driver, with the licence line (CC BY 4.0) wherever values appear. No coordinate exists in a snapshot, so nothing
// position-like enters the export. CSV is SI with UTC ISO hours like the other tables; text and PDF follow Units.
// Pure Dart: no Flutter imports.
import 'api.dart';
import 'drive_env_summary.dart';
import 'report_csv.dart';
import 'report_pdf.dart';
import 'units.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// The CSV table `weather`: one row per UTC hour, SI units in the column names, empty cell = the source gave none.
ReportTable weatherTable(List<WeatherSnapshot> s) => ReportTable(
      id: 'weather',
      label: 'Weather (server model values, about 5 km cell)',
      head: const [
        'hour_utc', 'temperature_c', 'humidity_pct', 'dew_point_c', 'pressure_hpa', 'precip_mm', 'cloud_pct', 'wind_ms', 'wind_dir_deg', //
        'source',
      ],
      rows: [
        for (final w in s)
          [_iso(w.at), w.temperatureC, w.humidityPct, w.dewPointC, w.pressureHpa, w.precipMm, w.cloudPct, w.windMs, w.windDirDeg, openMeteoCredit],
      ],
    );

/// The facts shared by the text and PDF forms, in the person's units. Empty with no snapshots.
List<(String, String)> weatherFacts(List<WeatherSnapshot> s, Units u) {
  final w = summarizeWeather(s);
  if (w == null) return const [];
  String range(double? a, double? b, String Function(double) f) {
    if (a == null || b == null) return '';
    return f(a) == f(b) ? f(a) : '${f(a)} to ${f(b)}';
  }

  final temp = range(w.tempMinC, w.tempMaxC, u.temperature);
  final dew = range(w.dewPointMinC, w.dewPointMaxC, u.temperature);
  final hum = range(w.humidityMinPct, w.humidityMaxPct, (v) => '${v.round()}%');
  final press = range(w.pressureMinHpa, w.pressureMaxHpa, u.pressure);
  return [
    ('Hours covered', '${w.hours}'),
    if (temp.isNotEmpty) ('Temperature', temp),
    if (dew.isNotEmpty) ('Dew point', dew),
    if (hum.isNotEmpty) ('Humidity', hum),
    if (w.windMeanMs != null)
      (
        'Wind',
        'mean ${u.speed(w.windMeanMs!)}${w.windMaxMs == null ? '' : ', up to ${u.speed(w.windMaxMs!)}'}'
            '${w.windMeanDirDeg == null ? '' : ', from the ${compassPoint(w.windMeanDirDeg!)}'}'
      ),
    if (w.precipTotalMm != null) ('Precipitation', u.precipitation(w.precipTotalMm!)),
    if (w.cloudMeanPct != null) ('Cloud cover', 'mean ${w.cloudMeanPct!.round()}%'),
    if (press.isNotEmpty) ('Station pressure', press),
  ];
}

/// Plain-text lines for the text summary (empty with no snapshots).
List<String> weatherTextLines(List<WeatherSnapshot> s, Units u) {
  final f = weatherFacts(s, u);
  if (f.isEmpty) return const [];
  return [
    'Weather (model values for a cell of about 5 km, not measured at your car):',
    for (final (k, v) in f) '  $k: $v',
    openMeteoCredit,
  ];
}

/// PDF blocks: facts, the hourly table (local hour via [wall], unit-converted) and the licence line. Empty with no snapshots.
List<PdfBlock> weatherPdfBlocks(List<WeatherSnapshot> s, Units u, {required String Function(DateTime utc) hour, required String zone}) {
  final f = weatherFacts(s, u);
  if (f.isEmpty) return const [];
  return [
    const PdfHeading('Weather'),
    const PdfText('Model values for a cell of about 5 km from Open-Meteo, looked up by the server for the hours of your drive. '
        'They are not measured at your car.', muted: true),
    PdfFacts(f),
    PdfTable(
      title: 'Hourly values',
      head: ['Hour ($zone)', 'Temp', 'Humidity', 'Wind', 'From', 'Rain', 'Cloud', 'Pressure'],
      numeric: const {1, 2, 3, 5, 6, 7},
      rows: [
        for (final w in s)
          [
            hour(w.at),
            w.temperatureC == null ? '—' : u.temperature(w.temperatureC!),
            w.humidityPct == null ? '—' : '${w.humidityPct!.round()}%',
            w.windMs == null ? '—' : u.speed(w.windMs!),
            w.windDirDeg == null ? '—' : compassPoint(w.windDirDeg!),
            w.precipMm == null ? '—' : u.precipitation(w.precipMm!),
            w.cloudPct == null ? '—' : '${w.cloudPct!.round()}%',
            w.pressureHpa == null ? '—' : u.pressure(w.pressureHpa!),
          ],
      ],
      note: openMeteoCredit,
    ),
  ];
}
