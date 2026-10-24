// Repeater "Your drives" (stream 5 D7): prefix match both ways, ids the lookup gives to ANOTHER repeater are not
// counted, ids several known repeaters share are counted apart, once per ping, cells not the track, best SNR / last /
// farthest, drives newest first, and nothing heard.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/repeater_history.dart';

const key = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
final t0 = DateTime.utc(2026, 10, 20, 15);

DrivePing ping(String id, int min, {double lat = 40.101, List<Echo> echoes = const [], Neighbor? neighbor}) =>
    DrivePing(id: id, ts: t0.add(Duration(minutes: min)), lat: lat, lon: -82.931, echoes: echoes, neighbor: neighbor);

(DriveSession, List<DrivePing>) drive(String id, int startMin, List<DrivePing> pings) =>
    (DriveSession(id: id, startedAt: t0.add(Duration(minutes: startMin))), pings);

void main() {
  test('either is a prefix of the other, case-insensitive', () {
    expect(idMatchesKey('A1B2', key), isTrue);
    expect(idMatchesKey(key, 'a1'), isTrue);
    expect(idMatchesKey('a1b3', key), isFalse);
    expect(idMatchesKey('', key), isFalse);
  });

  test('counts hearings once per ping, cells, best SNR, last heard, farthest, drives newest first', () {
    final h = RepeaterHistory.compute(key, [
      drive('old', 0, [
        ping('1', 0, echoes: const [Echo(repeater: 'a1b2', snrDb: 4, hops: 1), Echo(repeater: 'A1', snrDb: 6, hops: 2)]),
        ping('2', 1, lat: 40.111, neighbor: const Neighbor(repeater: 'a1b2c3', localSnrDb: 9.5)),
        ping('3', 2, echoes: const [Echo(repeater: 'ffee', snrDb: 12)]), // another repeater
      ]),
      drive('new', 60, [ping('4', 61, lat: 40.121, echoes: const [Echo(repeater: 'a1b2', snrDb: -1, hops: 3)])]),
      drive('none', 120, [ping('5', 121)]),
    ], lat: 40.101, lon: -82.931);
    expect(h.hearings, 3);
    expect(h.direct, 2); // 1-hop echo, neighbour reply; not the 3-hop one
    expect(h.bestSnr, 9.5);
    expect(h.bestSnrAt, t0.add(const Duration(minutes: 1)));
    expect(h.firstAt, t0);
    expect(h.lastAt, t0.add(const Duration(minutes: 61)));
    expect(h.cells, hasLength(3));
    expect(h.cells.first.hearings, 1);
    expect(h.farthestM, closeTo(2224, 5)); // 0.02 degree north
    expect(h.drives.map((d) => d.session.id), ['new', 'old']);
    expect(h.drives.last.hearings, 2);
    expect(h.drives.last.bestSnr, 9.5);
    expect(h.drivesSearched, 3);
    expect(h.sharedIdHearings, 0);
  });

  test('a shared short id is counted apart; a non-matching id never counts', () {
    final lookup = RepeaterLookup([
      (RepeaterSource.cmat, const [
        RepeaterRef(key: key, name: 'This one', lat: 40, lon: -83),
        RepeaterRef(key: 'a1ff00', name: 'Other A1', lat: 40, lon: -83),
      ]),
    ]);
    final h = RepeaterHistory.compute(key, [
      drive('d', 0, [
        ping('1', 0, echoes: const [Echo(repeater: 'a1ff', snrDb: 10)]), // not a prefix of our key: never counted
        ping('2', 1, echoes: const [Echo(repeater: 'a1', snrDb: 3)]), // shared by both known repeaters
        ping('3', 2, echoes: const [Echo(repeater: 'a1b2', snrDb: 5)]), // unique: ours
      ]),
    ], lookup: lookup);
    expect(h.hearings, 2);
    expect(h.sharedIdHearings, 1);
    expect(h.bestSnr, 5);
  });

  test('a short key (the id as heard in a drive sheet) still excludes ids the lookup gives to someone else', () {
    final lookup = RepeaterLookup([
      (RepeaterSource.cmat, const [RepeaterRef(key: 'a1ff00', name: 'Other', lat: 40, lon: -83)]),
    ]);
    final h = RepeaterHistory.compute('a1b2', [
      drive('d', 0, [
        ping('1', 0, echoes: const [Echo(repeater: 'a1', snrDb: 1)]), // resolves to a1ff00 (only known a1...): not ours
        ping('2', 1, echoes: const [Echo(repeater: 'a1b2', snrDb: 2)]),
      ]),
    ], lookup: lookup);
    expect(h.hearings, 1);
    expect(h.bestSnr, 2);
  });

  test('never heard: empty, with the number of drives searched', () {
    final h = RepeaterHistory.compute(key, [drive('d', 0, [ping('1', 0)])]);
    expect(h.isEmpty, isTrue);
    expect(h.drivesSearched, 1);
    expect(h.cells, isEmpty);
    expect(h.farthestM, isNull);
    final none = RepeaterHistory.compute(key, const []);
    expect(none.drivesSearched, 0);
  });
}
