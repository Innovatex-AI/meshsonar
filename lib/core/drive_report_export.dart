// Drive report CSV: the drive's tables with SI units in the column names (distance_m, speed_mps, gps_accuracy_m) and
// UTC ISO times, like the drive format and the website's report CSVs. One file (combinedCsv, first column `table`), so
// the share sheet gets a single attachment. The pings table carries the driver's own exact positions: the export UI
// says so.
// Pure Dart: no Flutter imports.
import 'drive_report.dart';
import 'model.dart';
import 'report_csv.dart';

double? _round(double? v, int dp) {
  if (v == null || !v.isFinite) return null;
  final s = v.toStringAsFixed(dp);
  return double.parse(s);
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

extension DriveReportTables on DriveReport {
  /// Every ping: time, position, radio readings, what answered.
  ReportTable pingsTable() {
    final rows = <List<Object?>>[];
    for (final p in sortedPings) {
      double? snr, rssi;
      final ids = <String>{};
      for (final e in p.echoes) {
        ids.add(e.repeater.toLowerCase());
        if (e.snrDb != null && (snr == null || e.snrDb! > snr)) snr = e.snrDb;
        if (e.rssiDbm != null && (rssi == null || e.rssiDbm! > rssi)) rssi = e.rssiDbm;
      }
      final n = p.neighbor;
      if (n != null) {
        ids.add(n.repeater.toLowerCase());
        if (n.localSnrDb != null && (snr == null || n.localSnrDb! > snr)) snr = n.localSnrDb;
        if (n.localRssiDbm != null && (rssi == null || n.localRssiDbm! > rssi)) rssi = n.localRssiDbm;
      }
      rows.add([
        p.id,
        _iso(p.ts),
        p.kind.name,
        p.lat,
        p.lon,
        _round(p.gpsAccuracyM, 1),
        _round(p.speedMps, 2),
        p.noiseFloorDbm,
        p.txDbm,
        p.kind == PingKind.tx ? !p.heardNothing : null,
        p.echoes.length,
        snr,
        rssi,
        ids.join(';'),
      ]);
    }
    return ReportTable(
      id: 'pings',
      label: 'Pings',
      head: const [
        'ping_id', 'ts_utc', 'kind', 'lat', 'lon', 'gps_accuracy_m', 'speed_mps', 'noise_floor_dbm', 'tx_dbm', 'heard', //
        'echoes', 'best_snr_db', 'best_rssi_dbm', 'repeaters',
      ],
      rows: rows,
    );
  }

  /// Grid cells (the website's 0.002 x 0.0025 degree grid) with tx pings.
  ReportTable cellsTable() => ReportTable(
        id: 'cells',
        label: 'Grid cells',
        head: const ['cell_i', 'cell_j', 'south', 'west', 'north', 'east', 'pings', 'heard', 'heard_pct', 'best_snr_db', 'new'],
        rows: [
          for (final c in cells)
            [
              c.i, c.j, _round(c.south, 6), _round(c.west, 6), _round(c.north, 6), _round(c.east, 6), //
              c.pings, c.heard, c.heardPercent, c.bestSnr, c.isNew,
            ],
        ],
      );

  /// Repeaters heard. [nameOf] gives a display name when the app knows one beyond the lookup's.
  ReportTable repeatersTable({String? Function(String id)? nameOf}) => ReportTable(
        id: 'repeaters',
        label: 'Repeaters heard',
        head: const ['repeater_id', 'name', 'times_heard', 'best_snr_db', 'farthest_m', 'first_heard_at', 'new', 'on_meshsonar_list'],
        rows: [
          for (final r in repeaters)
            [
              r.id,
              nameOf?.call(r.id) ?? (r.match.ref?.name.isNotEmpty == true ? r.match.ref!.name : null),
              r.timesHeard,
              r.bestSnr,
              _round(r.farthestM, 0),
              r.firstHeardAt == null ? null : _iso(r.firstHeardAt!),
              r.isNew,
              cmatChecked ? !r.unknownToCmat : null,
            ],
        ],
      );

  /// Direct-link SNR by distance band (repeater-reach bands).
  ReportTable snrByDistanceTable() => ReportTable(
        id: 'snr-by-distance',
        label: 'Direct-link SNR by distance',
        head: const ['from_m', 'to_m', 'measurements', 'mean_snr_db', 'best_snr_db', 'repeaters'],
        rows: [
          for (final b in rf.snrByDistance) [b.fromM, b.toM, b.n, _round(b.meanSnr, 2), b.bestSnr, b.repeaters],
        ],
      );

  /// Heard % by speed band.
  ReportTable heardBySpeedTable() => ReportTable(
        id: 'heard-by-speed',
        label: 'Heard by speed',
        head: const ['from_mps', 'to_mps', 'pings', 'heard', 'heard_pct'],
        rows: [
          for (final b in rf.heardBySpeed) [b.fromMps, b.toMps, b.pings, b.heard, b.heardPercent],
        ],
      );

  List<ReportTable> csvTables({String? Function(String id)? nameOf}) =>
      [pingsTable(), cellsTable(), repeatersTable(nameOf: nameOf), snrByDistanceTable(), heardBySpeedTable()];

  /// The whole drive as one CSV file.
  String toCsv({String? Function(String id)? nameOf}) => combinedCsv(csvTables(nameOf: nameOf));
}
