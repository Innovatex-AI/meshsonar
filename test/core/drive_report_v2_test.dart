// Drive report v2 (lib/core/drive_report_rf.dart + drive_report_export.dart): noise floor, reply RSSI, TX power change
// points, direct-link SNR by distance (repeater-reach bands, boundaries), heard by speed, GPS median/p90, the text in
// both unit systems, the one-file CSV, and the old import path still compiling.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_report.dart';
import 'package:meshsonar/core/drive_report_export.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/report/drive_report.dart' as shim;

final t0 = DateTime.utc(2026, 10, 16, 18);
const mPerDegLat = 111195.0802; // haversine with the 6371008.8 m Earth radius

DrivePing p(String id, int sec, {double lat = 40.0, double lon = -82.9, List<Echo> echoes = const [], Neighbor? neighbor,
        double? noise, double? tx, double? speed, double? acc, PingKind kind = PingKind.tx}) =>
    DrivePing(
        id: id,
        ts: t0.add(Duration(seconds: sec)),
        lat: lat,
        lon: lon,
        echoes: echoes,
        neighbor: neighbor,
        noiseFloorDbm: noise,
        txDbm: tx,
        speedMps: speed,
        gpsAccuracyM: acc,
        kind: kind);

final ses = DriveSession(id: 's', startedAt: t0, endedAt: t0.add(const Duration(minutes: 30)));
final lookup = RepeaterLookup([
  (RepeaterSource.cmat, const [RepeaterRef(key: 'aa11', name: 'North', lat: 40.0, lon: -82.9)]),
]);

DriveReport rep(List<DrivePing> pings) => DriveReport.compute(session: ses, pings: pings, lookup: lookup, cmatListLoaded: true);

void main() {
  test('the old lib/ui import path re-exports the same class', () {
    expect(shim.DriveReport, DriveReport);
  });

  test('noise floor series from tx and rx pings, median and range; none when the radio reported none', () {
    final r = rep([
      p('a', 0, noise: -110),
      p('b', 10, noise: -100, kind: PingKind.rx),
      p('c', 20),
      p('d', 30, noise: -98),
    ]);
    expect(r.rf.noiseSeries.map((x) => x.$2), [-110, -100, -98]);
    expect(r.rf.noiseMedian, -100);
    expect(r.rf.noiseMin, -110);
    expect(r.rf.noiseMax, -98);
    expect(rep([p('a', 0)]).rf.noiseSeries, isEmpty);
  });

  test('reply RSSI is the strongest echo or neighbour per tx ping; TX power keeps only change points', () {
    final r = rep([
      p('a', 0, tx: 22, echoes: const [Echo(repeater: 'aa', rssiDbm: -90), Echo(repeater: 'bb', rssiDbm: -70)]),
      p('b', 10, tx: 22, neighbor: const Neighbor(repeater: 'aa', localRssiDbm: -60)),
      p('c', 20, tx: 20),
      p('d', 30, tx: 20, kind: PingKind.rx, echoes: const [Echo(repeater: 'aa', rssiDbm: -10)]),
      p('e', 40, tx: 22),
    ]);
    expect(r.rf.rssiSeries.map((x) => x.$2), [-70, -60]);
    expect(r.rf.rssiBest, -60);
    expect(r.rf.txPowerChanges.map((x) => x.$2), [22, 20, 22]);
    expect(r.rf.txPowerConstant, isFalse);
    expect(rep([p('a', 0, tx: 22), p('b', 1, tx: 22)]).rf.txPowerConstant, isTrue);
  });

  test('SNR by distance: direct links only, band edges belong to the band above (999 m vs 1000 m)', () {
    final r = rep([
      p('a', 0, lat: 40.0 + 999 / mPerDegLat, echoes: const [Echo(repeater: 'aa11', snrDb: 6, hops: 1)]),
      p('b', 10, lat: 40.0 + 1000.5 / mPerDegLat, echoes: const [Echo(repeater: 'aa11', snrDb: 2, hops: 1)]),
      p('c', 20, lat: 40.0 + 1500 / mPerDegLat, echoes: const [Echo(repeater: 'aa11', snrDb: 4, hops: 1)]),
      // Multi-hop: its SNR is another repeater's last hop, so it is not counted.
      p('d', 30, lat: 40.0 + 500 / mPerDegLat, echoes: const [Echo(repeater: 'aa11', snrDb: -9, hops: 2)]),
      // Unknown position: not counted.
      p('e', 40, echoes: const [Echo(repeater: 'ff', snrDb: 9, hops: 1)]),
      // Neighbour reply counts (local SNR), 25 km away -> last band.
      p('f', 50, lat: 40.0 + 25000 / mPerDegLat, neighbor: const Neighbor(repeater: 'aa11', localSnrDb: -12)),
    ]);
    final b = r.rf.snrByDistance;
    expect(b, hasLength(6));
    expect(b[0].n, 1);
    expect(b[0].meanSnr, 6);
    expect(b[1].n, 2);
    expect(b[1].meanSnr, 3);
    expect(b[1].bestSnr, 4);
    expect(b[1].repeaters, 1);
    expect(b[5].n, 1);
    expect(b[5].toM, isNull);
    expect(b[2].n + b[3].n + b[4].n, 0);
  });

  test('heard by speed: tx pings with a speed, bands 0-5, 5-15, 15-25, 25+ m/s', () {
    final r = rep([
      p('a', 0, speed: 4.9, echoes: const [Echo(repeater: 'aa')]),
      p('b', 10, speed: 5),
      p('c', 20, speed: 14, echoes: const [Echo(repeater: 'aa')]),
      p('d', 30, speed: 30),
      p('e', 40), // no speed
      p('f', 50, speed: 30, kind: PingKind.rx),
    ]);
    final s = r.rf.heardBySpeed;
    expect([for (final x in s) x.pings], [1, 2, 0, 1]);
    expect([for (final x in s) x.heard], [1, 1, 0, 0]);
    expect(s[1].heardPercent, 50);
    expect(s[2].heardPercent, isNull);
  });

  test('GPS accuracy: median, nearest-rank p90, fixes worse than 50 m', () {
    final r = rep([for (var i = 1; i <= 10; i++) p('$i', i, acc: i * 10.0)]);
    expect(r.rf.gps!.n, 10);
    expect(r.rf.gps!.medianM, 55);
    expect(r.rf.gps!.p90M, 90);
    expect(r.rf.gps!.poor, 5);
    expect(rep([p('a', 0)]).rf.gps, isNull);
  });

  test('text v2 adds the radio side and follows the units', () {
    final pings = [
      p('a', 0, noise: -105, tx: 22, speed: 10, acc: 4, lat: 40.0 + 1500 / mPerDegLat,
          echoes: const [Echo(repeater: 'aa11', snrDb: 5, rssiDbm: -80, hops: 1)]),
      p('b', 60, noise: -95, tx: 22, speed: 20, acc: 8),
      p('c', 120, noise: -100, tx: 22, speed: 20, acc: 6),
    ];
    final met = rep(pings).toText();
    expect(met, contains('Noise floor median -100.0 dBm (-105.0 to -95.0, 3 readings)'));
    expect(met, contains('TX power 22.0 dBm throughout'));
    expect(met, contains('Reply RSSI median -80.0 dBm'));
    expect(met, contains('1.0 km to 2.0 km: mean 5.0 dB'));
    expect(met, contains('18 km/h to 54 km/h: 100% of 1 pings'));
    expect(met, contains('GPS accuracy median 6 m, 90% within 8 m'));
    expect(met, contains('Units: metric'));
    expect(met, isNot(contains('mph')));
    final imp = rep(pings).toText(units: Units.imperial);
    expect(imp, contains('0.6 mi to 1.2 mi'));
    expect(imp, contains('11 mph to 34 mph'));
    expect(imp, contains('GPS accuracy median 20 ft'));
    expect(imp, contains('Units: imperial'));
    expect(imp, isNot(contains('km')));
  });

  test('CSV: one file, table column first, SI column names, every ping row', () {
    final r = rep([
      p('a', 0, noise: -105, tx: 22, speed: 10.123, acc: 4.25, echoes: const [Echo(repeater: 'AA11', snrDb: 5, rssiDbm: -80, hops: 1)]),
      p('b', 60),
      p('c', 70, kind: PingKind.rx, echoes: const [Echo(repeater: 'bb')]),
    ]);
    final csv = r.toCsv(nameOf: (id) => id == 'aa11' ? 'North, the tall one' : null);
    final lines = csv.split('\r\n');
    expect(lines.first, startsWith('table,ping_id,ts_utc,kind,lat,lon,gps_accuracy_m,speed_mps,noise_floor_dbm,tx_dbm,heard,'));
    expect(lines.where((l) => l.startsWith('pings,')), hasLength(3));
    expect(lines[1], startsWith('pings,a,2026-10-16T18:00:00.000Z,tx,40,-82.9,4.3,10.12,-105,22,true,1,5,-80,aa11'));
    expect(csv, contains('repeaters,'));
    expect(csv, contains('"North, the tall one"'));
    expect(lines.where((l) => l.startsWith('snr-by-distance,')), hasLength(6));
    expect(lines.where((l) => l.startsWith('heard-by-speed,')), hasLength(4));
    expect(csv.endsWith('\r\n'), isTrue);
    final rx = lines.firstWhere((l) => l.startsWith('pings,c,'));
    expect(rx.split(',')[10], ''); // heard is empty for rx pings
  });

  test('10,000-ping drive computes v2 within a second', () {
    final pings = [
      for (var i = 0; i < 10000; i++)
        p('$i', i * 5,
            lat: 40.0 + i * 0.0002,
            noise: -110.0 + i % 15,
            tx: 22,
            speed: (i % 30).toDouble(),
            acc: (i % 20).toDouble(),
            echoes: i % 3 == 0 ? const [] : [Echo(repeater: 'aa11', snrDb: (i % 20) - 10.0, rssiDbm: -90.0 + i % 30, hops: 1)]),
    ];
    final sw = Stopwatch()..start();
    final r = rep(pings);
    r.toCsv();
    sw.stop();
    expect(r.rf.noiseSeries, hasLength(10000));
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });
}
