import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/interop.dart';
import 'package:meshsonar/core/meshtrack/track_group.dart';

final _t0 = DateTime.utc(2026, 11, 16, 12);

MtAccept _add(TrackGroup g, String name, double lat, double lon, DateTime at, {DateTime? now, double acc = 2}) =>
    g.addPosition(name: name, lat: lat, lon: lon, accuracyM: acc, at: at, now: now ?? at);

void main() {
  group('staleness bands', () {
    test('fresh < 5 min, faded 5-15, grey 15 min-2 h, list only 2-24 h', () {
      MtStaleness at(Duration age) => mtStaleness(_t0, _t0.add(age));
      expect(at(Duration.zero), MtStaleness.fresh);
      expect(at(const Duration(minutes: 4, seconds: 59)), MtStaleness.fresh);
      expect(at(const Duration(minutes: 5)), MtStaleness.faded);
      expect(at(const Duration(minutes: 14)), MtStaleness.faded);
      expect(at(const Duration(minutes: 15)), MtStaleness.grey);
      expect(at(const Duration(minutes: 119)), MtStaleness.grey);
      expect(at(const Duration(hours: 2)), MtStaleness.listOnly);
      expect(mtStaleness(_t0, _t0, stopped: true), MtStaleness.grey);
    });

    test('friends: off the map after 2 h, off the list after 24 h', () {
      final g = TrackGroup(1);
      _add(g, 'Sam', 40, -83, _t0);
      expect(g.friends(_t0.add(const Duration(minutes: 30))).single.onMap, isTrue);
      expect(g.friends(_t0.add(const Duration(hours: 3))).single.onMap, isFalse);
      expect(g.friends(_t0.add(const Duration(hours: 25))), isEmpty);
      expect(g.prune(_t0.add(const Duration(hours: 25))), isTrue);
      expect(g.nameCount, 0);
    });

    test('a position older than 2 h on arrival is list only', () {
      final g = TrackGroup(1);
      final now = _t0.add(const Duration(hours: 3));
      expect(_add(g, 'Sam', 40, -83, _t0, now: now), MtAccept.accepted);
      expect(g.friends(now).single.staleness, MtStaleness.listOnly);
      expect(_add(g, 'Old', 40, -83, _t0, now: _t0.add(const Duration(hours: 25))), MtAccept.tooOld);
    });

    test('MT1 x greys the friend at once', () {
      final g = TrackGroup(1);
      _add(g, 'Sam', 40, -83, _t0);
      g.markStopped('Sam', _t0.add(const Duration(seconds: 10)));
      final f = g.friends(_t0.add(const Duration(seconds: 20))).single;
      expect(f.stopped, isTrue);
      expect(f.staleness, MtStaleness.grey);
    });
  });

  group('jump rule', () {
    test('a move faster than 300 km/h is shown but draws no trail segment', () {
      final g = TrackGroup(1);
      _add(g, 'Sam', 40, -83, _t0);
      _add(g, 'Sam', 40.001, -83, _t0.add(const Duration(seconds: 60))); // ~111 m in 60 s
      _add(g, 'Sam', 41, -83, _t0.add(const Duration(seconds: 120))); // 111 km in 60 s
      final f = g.friends(_t0.add(const Duration(seconds: 120))).single;
      expect(f.lat, 41);
      expect(f.jumped, isTrue);
      expect(f.trail.length, 3);
      expect(f.trail[1].breakBefore, isFalse);
      expect(f.trail[2].breakBefore, isTrue);
      _add(g, 'Sam', 41.001, -83, _t0.add(const Duration(seconds: 180)));
      expect(g.friends(_t0.add(const Duration(seconds: 180))).single.jumped, isFalse);
    });

    test('an approximate code (275 m) moving one cell is not a jump', () {
      final g = TrackGroup(1);
      _add(g, 'Sam', 40, -83, _t0, acc: 139);
      _add(g, 'Sam', 40.0025, -83, _t0.add(const Duration(seconds: 6)), acc: 139);
      expect(g.friends(_t0.add(const Duration(seconds: 6))).single.jumped, isFalse);
    });
  });

  test('per-name rate limit: more than one position per 5 s is dropped', () {
    final g = TrackGroup(1);
    expect(_add(g, 'Sam', 40, -83, _t0), MtAccept.accepted);
    expect(_add(g, 'Sam', 40.0001, -83, _t0.add(const Duration(seconds: 4))), MtAccept.rateLimited);
    expect(_add(g, 'Ann', 40.0001, -83, _t0.add(const Duration(seconds: 4))), MtAccept.accepted);
    expect(_add(g, 'Sam', 40.0002, -83, _t0.add(const Duration(seconds: 5))), MtAccept.accepted);
    expect(_add(g, 'Sam', 40.0002, -83, _t0.add(const Duration(seconds: 1))), MtAccept.older);
  });

  test('256-entry LRU for duplicate receipt', () {
    final g = TrackGroup(1);
    expect(g.isDuplicate('Sam', _t0, 'MT1 x'), isFalse);
    expect(g.isDuplicate('Sam', _t0, 'MT1 x'), isTrue);
    expect(g.isDuplicate('Ann', _t0, 'MT1 x'), isFalse);
    expect(g.isDuplicate('Sam', _t0.add(const Duration(seconds: 1)), 'MT1 x'), isFalse);
    // Fill past 256: the oldest is forgotten, a recently used one is kept.
    for (var i = 0; i < 255; i++) {
      g.isDuplicate('N$i', _t0, 'b');
      if (i == 100) expect(g.isDuplicate('Sam', _t0, 'MT1 x'), isTrue); // refreshes it
    }
    expect(g.isDuplicate('Ann', _t0, 'MT1 x'), isFalse); // was evicted
    expect(g.isDuplicate('Sam', _t0, 'MT1 x'), isTrue);
  });

  test('32-name cap drops the oldest heard', () {
    final g = TrackGroup(1);
    for (var i = 0; i < 32; i++) {
      _add(g, 'N$i', 40, -83, _t0.add(Duration(seconds: i)));
    }
    expect(g.nameCount, kMtMaxNames);
    _add(g, 'N0', 40.00001, -83, _t0.add(const Duration(seconds: 40))); // N0 heard again: N1 is now the oldest
    _add(g, 'New', 40, -83, _t0.add(const Duration(seconds: 50)));
    final names = g.friends(_t0.add(const Duration(seconds: 50))).map((f) => f.name).toSet();
    expect(names.length, 32);
    expect(names.contains('New'), isTrue);
    expect(names.contains('N0'), isTrue);
    expect(names.contains('N1'), isFalse);
  });

  group('backlog timestamps', () {
    final rx = _t0;
    test('plausible sender time is used', () {
      expect(mtEffectiveTime(rx.subtract(const Duration(hours: 3)), rx), rx.subtract(const Duration(hours: 3)));
      expect(mtEffectiveTime(null, rx), rx);
    });
    test('future or more than 24 h old: receive time', () {
      expect(mtEffectiveTime(rx.add(const Duration(minutes: 5)), rx), rx);
      expect(mtEffectiveTime(rx.subtract(const Duration(hours: 25)), rx), rx);
      expect(mtEffectiveTime(rx.add(const Duration(seconds: 10)), rx), rx); // small skew clamps to receipt
    });
  });

  test('trail: last 30 min, at most 20 points', () {
    final g = TrackGroup(1);
    for (var i = 0; i < 60; i++) {
      _add(g, 'Sam', 40 + i * 0.0005, -83, _t0.add(Duration(seconds: 60 * i)));
    }
    final f = g.friends(_t0.add(const Duration(minutes: 59))).single;
    expect(f.trail.length, kMtTrailPoints);
    expect(f.trail.every((p) => _t0.add(const Duration(minutes: 59)).difference(p.at) <= kMtTrailAge), isTrue);
  });

  test('last-known round trip, typed source kept, 24 h TTL on restore', () {
    final g = TrackGroup(1);
    _add(g, 'Sam', 40, -83, _t0);
    g.addPosition(name: 'Bob', lat: 39, lon: -84, accuracyM: 3, at: _t0, now: _t0, source: MtSource.typed, speedKmh: 40);
    g.meet = MtMeetPin(lat: 39.5, lon: -83.5, at: _t0, label: 'Gate 3', setBy: 'Sam');
    final j = g.toJson();
    expect((j['friends'] as List).first, isNot(contains('trail')));
    final r = TrackGroup(1)..restore(j, _t0.add(const Duration(hours: 1)));
    final fs = r.friends(_t0.add(const Duration(hours: 1)));
    expect(fs.map((f) => f.name).toSet(), {'Sam', 'Bob'});
    expect(fs.firstWhere((f) => f.name == 'Bob').typed, isTrue);
    expect(fs.firstWhere((f) => f.name == 'Bob').speedKmh, 40);
    expect(r.meet!.label, 'Gate 3');
    final late = TrackGroup(1)..restore(j, _t0.add(const Duration(hours: 25)));
    expect(late.nameCount, 0);
    expect(late.meet, isNull);
    TrackGroup(1).restore('garbage', _t0); // never throws
  });
}
