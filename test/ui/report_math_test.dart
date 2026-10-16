import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/report/drive_report.dart';

final t0 = DateTime.utc(2026, 10, 16, 18);
DrivePing p(String id, int sec, double lat, double lon,
        {List<Echo> echoes = const [], double? speed, PingKind kind = PingKind.tx, Neighbor? neighbor}) =>
    DrivePing(id: id, ts: t0.add(Duration(seconds: sec)), lat: lat, lon: lon, echoes: echoes, speedMps: speed, kind: kind, neighbor: neighbor);

DriveSession ses(String id, {int minutes = 10}) =>
    DriveSession(id: id, startedAt: t0, endedAt: t0.add(Duration(minutes: minutes)));

void main() {
  group('cells', () {
    test('cell index matches CMAT (floor of lat/0.002, lon/0.0025), negatives included', () {
      expect(cellIndexOf(40.1261, -82.9301), (20063, -33173));
      expect(cellIndexOf(40.0, -82.0), (20000, -32800));
      expect(cellIndexOf(40.0019, -82.0001), (20000, -32801));
      expect(cellIndexOf(40.002, -82.0), (20001, -32800));
    });

    test('grids mapped are distinct tx cells; coverage counts heard cells; rx pings ignored', () {
      final r = DriveReport.compute(session: ses('s'), pings: [
        p('a', 0, 40.1001, -82.9001, echoes: const [Echo(repeater: 'aa', snrDb: 5)]),
        p('b', 10, 40.1002, -82.9002), // same cell, silent
        p('c', 20, 40.1031, -82.9001), // next cell north, silent
        p('d', 30, 40.1101, -82.9101, kind: PingKind.rx, echoes: const [Echo(repeater: 'bb')]),
      ]);
      expect(r.gridsMapped, 2);
      expect(r.gridsWithCoverage, 1);
      final first = r.cells.firstWhere((c) => c.pings == 2);
      expect(first.heard, 1);
      expect(first.heardPercent, 50);
      expect(r.txPings, 3);
      expect(r.heardPings, 1);
      expect(r.heardPercent, 33);
      expect(r.pings, 4);
    });

    test('new grids are cells no earlier drive pinged in', () {
      final old = [p('o1', 0, 40.1001, -82.9001), p('o2', 0, 40.5, -82.5, kind: PingKind.rx)];
      final r = DriveReport.compute(
        session: ses('s'),
        pings: [p('a', 0, 40.1001, -82.9001), p('b', 10, 40.1031, -82.9001), p('c', 20, 40.5001, -82.5001)],
        earlier: [old],
      );
      expect(r.gridsMapped, 3);
      // o2 was rx only, so its cell doesn't count as mapped before.
      expect(r.newGrids, 2);
      expect(r.cells.where((c) => !c.isNew).single.pings, 1);
      expect(r.earlierDrives, 1);
    });
  });

  group('distance and speed', () {
    test('distance is the sum of ping-to-ping haversine, in time order', () {
      final pts = [p('b', 60, 40.001, -82.0), p('a', 0, 40.0, -82.0), p('c', 120, 40.002, -82.0)];
      final r = DriveReport.compute(session: ses('s'), pings: pts);
      final want = haversineM(40.0, -82.0, 40.001, -82.0) + haversineM(40.001, -82.0, 40.002, -82.0);
      expect(r.distanceM, closeTo(want, 0.01));
      expect(r.distanceM, closeTo(222.4, 0.5));
      expect(r.duration, const Duration(minutes: 10));
      expect(r.avgSpeedMps, closeTo(want / 120, 0.001));
      // No GPS speed recorded: max comes from segments (≈1.85 m/s).
      expect(r.maxSpeedMps, closeTo(111.2 / 60, 0.01));
    });

    test('max speed prefers recorded GPS speed; GPS jumps are not speeds', () {
      final r = DriveReport.compute(session: ses('s'), pings: [
        p('a', 0, 40.0, -82.0, speed: 12),
        p('b', 10, 40.0, -82.0, speed: 19.5),
      ]);
      expect(r.maxSpeedMps, 19.5);
      final jump = DriveReport.compute(session: ses('s'), pings: [p('a', 0, 40.0, -82.0), p('b', 10, 40.1, -82.0)]);
      expect(jump.maxSpeedMps, isNull); // 11 km in 10 s
    });

    test('empty drive', () {
      final r = DriveReport.compute(session: ses('s'), pings: const []);
      expect(r.distanceM, 0);
      expect(r.gridsMapped, 0);
      expect(r.heardPercent, isNull);
      expect(r.bestCell, isNull);
      expect(r.worstCell, isNull);
      expect(r.toText(), contains('0 pings'));
    });
  });

  group('repeaters', () {
    const cmatRep = RepeaterRef(key: 'aa11223344', name: 'Westerville North', lat: 40.13, lon: -82.93);
    const publicRep = RepeaterRef(key: 'cc99887766', name: 'Public Node', lat: 40.12, lon: -82.95);
    final lookup = RepeaterLookup([
      (RepeaterSource.cmat, [cmatRep]),
      (RepeaterSource.publicMap, [publicRep]),
    ]);
    final pings = [
      p('1', 0, 40.126, -82.93, echoes: const [Echo(repeater: 'aa11', snrDb: 4, hops: 1), Echo(repeater: 'BB', snrDb: -3, hops: 2)]),
      p('2', 30, 40.110, -82.93, echoes: const [Echo(repeater: 'aa11', snrDb: 7.5, hops: 1), Echo(repeater: 'aa11', snrDb: 1, hops: 3)]),
      p('3', 60, 40.100, -82.93, neighbor: const Neighbor(repeater: 'cc99', localSnrDb: 2)),
      p('4', 90, 40.090, -82.93, echoes: const [Echo(repeater: 'dd')]),
    ];

    test('leaderboard: times heard (once per ping), best SNR, farthest when position known', () {
      final r = DriveReport.compute(session: ses('s'), pings: pings, lookup: lookup, cmatListLoaded: true);
      final top = r.repeaters.first;
      expect(top.id, 'aa11');
      expect(top.timesHeard, 2);
      expect(top.bestSnr, 7.5);
      expect(top.farthestM, closeTo(haversineM(40.110, -82.93, 40.13, -82.93), 0.01));
      expect(top.label, 'Westerville North');
      final bb = r.repeaters.firstWhere((x) => x.id == 'bb');
      expect(bb.farthestM, isNull);
      expect(r.farthest!.id, 'cc99'); // 40.100 → 40.12/-82.95 is farther than 40.110 → 40.13
      expect(r.hops, {1: 2, 2: 1, 3: 1, 0: 1});
    });

    test('unknown to CMAT: anything not resolved from CMAT\'s list, only when the list was loaded', () {
      final r = DriveReport.compute(session: ses('s'), pings: pings, lookup: lookup, cmatListLoaded: true);
      expect(r.unknownToCmat.map((x) => x.id).toSet(), {'bb', 'cc99', 'dd'});
      expect(r.cmatChecked, isTrue);
      final noList = DriveReport.compute(session: ses('s'), pings: pings, lookup: lookup);
      expect(noList.unknownToCmat, isEmpty);
    });

    test('new repeaters: never heard on an earlier drive (prefixes of different lengths match)', () {
      final earlier = [
        [p('o1', 0, 40.0, -82.0, echoes: const [Echo(repeater: 'aa112233')])], // longer prefix of aa11
        [p('o2', 0, 40.0, -82.0, neighbor: const Neighbor(repeater: 'c'))], // a shorter prefix of cc99
        [p('o3', 0, 40.0, -82.0, echoes: const [Echo(repeater: 'dd')])],
      ];
      final r = DriveReport.compute(session: ses('s'), pings: pings, earlier: earlier, lookup: lookup);
      final fresh = r.newRepeaters.map((x) => x.id).toSet();
      expect(fresh.contains('aa11'), isFalse);
      expect(fresh.contains('dd'), isFalse);
      expect(fresh.contains('bb'), isTrue);
      // 'c' is a prefix of 'cc99', so cc99 counts as possibly seen before.
      expect(fresh.contains('cc99'), isFalse);
      final first = DriveReport.compute(session: ses('s'), pings: pings, lookup: lookup);
      expect(first.newRepeaters.length, 4);
    });

    test('best and worst spots', () {
      final r = DriveReport.compute(session: ses('s'), pings: [
        p('a', 0, 40.1001, -82.9001, echoes: const [Echo(repeater: 'aa', snrDb: 9)]),
        p('b', 10, 40.1031, -82.9001, echoes: const [Echo(repeater: 'aa', snrDb: 2)]),
        p('c', 20, 40.1031, -82.9001),
        p('d', 30, 40.1061, -82.9001),
        p('e', 40, 40.1061, -82.9001),
      ]);
      expect(r.bestCell!.bestSnr, 9);
      expect(r.worstCell!.heard, 0);
      expect(r.worstCell!.pings, 2);
      expect(r.snrSeries.length, 5);
      expect(r.snrSeries.where((x) => x.heard).length, 2);
      expect(r.bestSnr, 9);
    });

    test('text summary', () {
      final r = DriveReport.compute(session: ses('s'), pings: pings, lookup: lookup, cmatListLoaded: true);
      final txt = r.toText(title: 'Evening loop');
      expect(txt, startsWith('Evening loop'));
      expect(txt, contains('4 pings, 100% heard'));
      expect(txt, contains('Westerville North: 2×, best 7.5 dB'));
      expect(txt, contains('Farthest: Public Node'));
    });
  });

  test('2,500-ping drive with 20 earlier drives computes quickly', () {
    List<DrivePing> drive(String tag, int n, double dLat) => [
          for (var i = 0; i < n; i++)
            p('$tag$i', i * 20, 40.0 + dLat + i * 0.0003, -82.9 + (i % 50) * 0.0004,
                echoes: i % 3 == 0 ? const [] : [Echo(repeater: (i % 40).toRadixString(16).padLeft(2, '0'), snrDb: (i % 20) - 10.0, hops: 1)]),
        ];
    final earlier = [for (var d = 0; d < 20; d++) drive('e$d-', 2000, d * 0.01)];
    final sw = Stopwatch()..start();
    final r = DriveReport.compute(session: ses('s'), pings: drive('n', 2500, 0.005), earlier: earlier);
    sw.stop();
    expect(r.txPings, 2500);
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });
}
