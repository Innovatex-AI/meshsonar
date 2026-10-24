import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';

DrivePing p(int i, List<Echo> e, {double lat = 40.1, double lon = -82.9, PingKind kind = PingKind.tx}) =>
    DrivePing(id: 'p$i', ts: DateTime.utc(2026, 10, 16, 12, 0, i), lat: lat, lon: lon, echoes: e, kind: kind);

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

  test('tracker populates from rx pings too (a discovery/listen-only drive emits only these)', () {
    final t = HeardTracker(holdPings: 2, lookup: RepeaterLookup([(RepeaterSource.cmat, [a])]));
    t.addPing(p(0, [const Echo(repeater: 'df', snrDb: 5, hops: 1)], kind: PingKind.rx));
    expect(t.live.map((h) => h.id), ['df']);
    final df = t.repeaters.single;
    expect(df.timesHeard, 1);
    expect(df.bestSnrDb, 5);
    expect(df.lastDistanceM, greaterThan(1000));
    // A second rx ping for a different repeater stacks normally, same as tx pings do.
    t.addPing(p(1, [const Echo(repeater: 'ee', snrDb: -1)], kind: PingKind.rx));
    expect(t.live.map((h) => h.id), containsAll(['df', 'ee']));
  });

  test('bearing and compass', () {
    expect(compass(bearingDeg(40, -83, 41, -83)), 'N');
    expect(compass(bearingDeg(40, -83, 40, -82)), 'E');
    expect(haversineM(40, -83, 40, -83), 0);
  });


  test('changing holdPings mid-drive re-applies live/stale at once, both ways', () {
    final t = HeardTracker(holdPings: 5);
    t.addPing(p(0, [const Echo(repeater: 'df', snrDb: 3)]));
    t.addPing(p(1, const []));
    t.addPing(p(2, const [])); // 2 pings since heard: live with hold 5
    expect(t.live.map((h) => h.id), ['df']);
    t.holdPings = 2; // now stale without waiting for another ping
    expect(t.live, isEmpty);
    expect(t.repeaters.single.state, HeardState.stale);
    t.holdPings = 3; // back to live
    expect(t.live.map((h) => h.id), ['df']);
    t.holdPings = 0; // floored at 1
    expect(t.holdPings, 1);
    expect(t.live, isEmpty);
  });

  test('ambiguousPrefixes: a prefix a server marks as shared never resolves to one name, from any list', () {
    const roster = RepeaterRef(key: 'ee01aa', name: 'Roster-EE', lat: 40, lon: -83);
    const cmat = RepeaterRef(key: 'ee77bb', name: 'CMAT-EE', lat: 40, lon: -83);
    const other = RepeaterRef(key: 'ff00cc', name: 'Other', lat: 40, lon: -83);
    final l = RepeaterLookup([
      (RepeaterSource.cmat, const [roster, other]),
      (RepeaterSource.cmat, const [cmat]),
    ], ambiguousPrefixes: {'EE'});
    final m = l.resolve('ee');
    expect(m.ref, isNull);
    expect(m.ambiguous, isTrue);
    expect(m.candidates.map((r) => r.name).toSet(), {'Roster-EE', 'CMAT-EE'});
    expect(l.resolve('e').ref, isNull, reason: 'a shorter id is at least as ambiguous');
    expect(l.resolve('ee77').ref?.name, 'CMAT-EE', reason: 'a longer id can still be told apart');
    expect(l.resolve('ff').ref?.name, 'Other');
    // Earlier lists still win for prefixes nobody marked shared.
    final l2 = RepeaterLookup([
      (RepeaterSource.cmat, const [roster]),
      (RepeaterSource.publicMap, const [cmat]),
    ]);
    expect(l2.resolve('ee').ref?.name, 'Roster-EE');
  });
}
