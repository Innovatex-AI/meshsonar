// Contract section 8.7 (Nov 9 2026, fail closed): the drive-end confirmation of exact observer positions. The kept window
// from the start / end trim, the wire body, the durable queue (survives a restart), retry until 2xx, not before the drive's
// last packets, and a drive hidden or deleted before it went keeps nothing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_end.dart';

final _t0 = DateTime.utc(2026, 11, 9, 12);

/// A straight drive north, one point per 10 s, ~111 m apart (0.001 degree of latitude).
List<TrackPoint> _track(int n) => [for (var i = 0; i < n; i++) TrackPoint(_t0.add(Duration(seconds: 10 * i)), 39.9 + 0.001 * i, -83.0)];

class _Tx implements DriveEndTransport {
  final bodies = <Map<String, dynamic>>[];
  final statuses = <Object>[]; // int or exception; empty = 200
  @override
  Future<int> driveEnd(String k, Map<String, dynamic> body) async {
    bodies.add(body);
    if (statuses.isEmpty) return 200;
    final s = statuses.removeAt(0);
    if (s is int) return s;
    throw s;
  }
}

DriveEndRecord _rec({String? ref = 'drive-1', DateTime? notBefore}) {
  final w = driveKeepWindow(_track(30), 500)!;
  return DriveEndRecord(
    observerId: '0123456789abcdef0123456789abcdef',
    driveRef: ref,
    startedAt: _t0,
    endedAt: _t0.add(const Duration(minutes: 5)),
    keepFrom: w.from,
    keepUntil: w.until,
    hidden: false,
    notBefore: notBefore ?? _t0.add(const Duration(minutes: 8)),
  );
}

void main() {
  test('keep window: first point beyond the trim from the start to the last beyond it from the end', () {
    final w = driveKeepWindow(_track(30), 500)!;
    expect(w.from, _t0.add(const Duration(seconds: 50)), reason: 'point 5 is ~555 m from the start');
    expect(w.until, _t0.add(const Duration(seconds: 240)), reason: 'point 24 is ~555 m from the end (point 29)');
    final all = driveKeepWindow(_track(30), 0)!;
    expect(all.from, _t0);
    expect(all.until, _t0.add(const Duration(seconds: 290)));
    expect(driveKeepWindow(_track(8), 500), isNull, reason: 'never left the trim circles: nothing kept');
    expect(driveKeepWindow(const [], 500), isNull);
  });

  test('wire body: the contract keys, ISO times, keep both set or both null', () {
    final r = _rec();
    expect(r.toWire().keys.toList(), ['id', 'drive_ref', 'started_at', 'ended_at', 'keep_from', 'keep_until', 'hidden']);
    expect(r.toWire()['keep_from'], '2026-11-09T12:00:50.000Z');
    expect(r.toWire()['hidden'], isFalse);
    final h = r.asHidden().toWire();
    expect(h['keep_from'], isNull);
    expect(h['keep_until'], isNull);
    expect(h['hidden'], isTrue);
    final half = DriveEndRecord(observerId: 'x', driveRef: null, startedAt: _t0, endedAt: _t0, keepFrom: _t0, keepUntil: null, hidden: false, notBefore: _t0);
    expect(half.toWire()['keep_from'], isNull, reason: 'never one end of a window alone');
  });

  test('durable: survives a restart, sent after notBefore, retried on network / 5xx / 404 / 401 until 2xx', () async {
    final dir = Directory.systemTemp.createTempSync('drive_end');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/q.json');
    var now = _t0.add(const Duration(minutes: 5));
    await DriveEndQueue(file: f, now: () => now).add(_rec());
    // The app was killed; a new run reads the queue.
    final q = DriveEndQueue(file: f, now: () => now);
    final tx = _Tx();
    await q.flush(tx, 'key');
    expect(tx.bodies, isEmpty, reason: 'not before the drive\'s last held packets');
    now = now.add(const Duration(minutes: 4));
    tx.statuses.addAll([const SocketException('down')]);
    await q.flush(tx, 'key');
    expect(q.pending, hasLength(1));
    for (final s in [503, 404, 401, 429]) {
      tx.statuses.add(s);
      await q.flush(tx, 'key');
      expect(q.pending, hasLength(1), reason: '$s is retried');
    }
    await q.flush(tx, 'key');
    expect(q.pending, isEmpty);
    expect(q.sent, 1);
    expect(f.existsSync(), isFalse, reason: 'nothing left on disk');
    expect(tx.bodies.last['drive_ref'], 'drive-1');
  });

  test('no key / no server: nothing is sent and nothing is lost', () async {
    final q = DriveEndQueue(now: () => _t0.add(const Duration(hours: 1)));
    await q.add(_rec());
    await q.flush(null, 'key');
    await q.flush(_Tx(), null);
    expect(q.pending, hasLength(1));
  });

  test('a 400 is dropped (the server will never take it)', () async {
    final q = DriveEndQueue(now: () => _t0.add(const Duration(hours: 1)));
    await q.add(_rec());
    final tx = _Tx()..statuses.add(400);
    await q.flush(tx, 'key');
    expect(q.pending, isEmpty);
    expect(q.sent, 0);
  });

  test('a drive hidden or deleted before its confirmation went keeps nothing', () async {
    final q = DriveEndQueue(now: () => _t0.add(const Duration(hours: 1)));
    await q.add(_rec());
    await q.add(_rec(ref: 'drive-2'));
    await q.hide('drive-1');
    final tx = _Tx();
    await q.flush(tx, 'key');
    final one = tx.bodies.firstWhere((b) => b['drive_ref'] == 'drive-1');
    expect(one['hidden'], isTrue);
    expect(one['keep_from'], isNull);
    expect(tx.bodies.firstWhere((b) => b['drive_ref'] == 'drive-2')['hidden'], isFalse);
  });
}
