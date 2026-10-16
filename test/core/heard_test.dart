import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';

DrivePing p(int i, List<Echo> e, {double lat = 40.1, double lon = -82.9}) =>
    DrivePing(id: 'p$i', ts: DateTime.utc(2026, 10, 16, 12, 0, i), lat: lat, lon: lon, echoes: e);

void main() {
  const a = RepeaterRef(key: 'df0136aa', name: 'Smith Park', lat: 40.12, lon: -82.93);
  const b1 = RepeaterRef(key: 'd4038f01', name: 'Polaris A', lat: 40.14, lon: -82.97);
  const b2 = RepeaterRef(key: 'd4038f02', name: 'Polaris B', lat: 40.14, lon: -82.97);
  const pub = RepeaterRef(key: '509f8f11', name: 'Public One', lat: 40.11, lon: -83.01);

  test('lookup: unique, ambiguous, unknown, later source', () {
    final l = RepeaterLookup([(RepeaterSource.cmat, [a, b1, b2]), (RepeaterSource.publicMap, [pub])]);
    expect(l.resolve('DF01').ref?.name, 'Smith Park');
    expect(l.resolve('d4038f').ambiguous, isTrue);
    expect(l.resolve('d4038f').label, contains('2 possible'));
    expect(l.resolve('d4038f01').ref?.name, 'Polaris A');
    expect(l.resolve('50').source, RepeaterSource.publicMap);
    expect(l.resolve('ee').known, isFalse);
    expect(l.resolve('ee').label, 'EE');
  });

  test('tracker: live for holdPings pings, then stale; distance; best SNR', () {
    final t = HeardTracker(holdPings: 2, lookup: RepeaterLookup([(RepeaterSource.cmat, [a])]));
    t.addPing(p(0, [const Echo(repeater: 'df', snrDb: 3)]));
    t.addPing(p(1, [const Echo(repeater: 'df', snrDb: 7, hops: 1), const Echo(repeater: 'ee', snrDb: -4)]));
    expect(t.live.map((h) => h.id), containsAll(['df', 'ee']));
    final df = t.repeaters.firstWhere((h) => h.id == 'df');
    expect(df.timesHeard, 2);
    expect(df.bestSnrDb, 7);
    expect(df.lastDistanceM, greaterThan(1000));
    expect(t.repeaters.firstWhere((h) => h.id == 'ee').lastDistanceM, isNull);
    t.addPing(p(2, const [])); // 1 ping without them: still live (hold 2)
    expect(t.live, hasLength(2));
    t.addPing(p(3, const [])); // 2 pings without: stale, but still listed
    expect(t.live, isEmpty);
    expect(t.repeaters, hasLength(2));
    expect(t.repeaters.every((h) => h.state == HeardState.stale), isTrue);
    t.addPing(p(4, [const Echo(repeater: 'df', snrDb: 1)]));
    expect(t.repeaters.first.id, 'df');
    expect(t.repeaters.first.state, HeardState.live);
  });

  test('bearing and compass', () {
    expect(compass(bearingDeg(40, -83, 41, -83)), 'N');
    expect(compass(bearingDeg(40, -83, 40, -82)), 'E');
    expect(haversineM(40, -83, 40, -83), 0);
  });
}
