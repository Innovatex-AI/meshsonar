// driver-summary (capability driverSummary): the tolerant parser, the HTTP client contract and the stored copy.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/driver_summary.dart';

Map<String, dynamic> body({bool extra = true}) => {
      'v': 1,
      'asOf': '2026-10-25T06:00:00.000Z',
      'stats': {
        'drives': 3, 'pings': 410, 'heardPings': 300, 'km': 87.4, 'cells': 120, 'repeatersHeard': 14,
        'firstDriveAt': '2026-09-01T12:00:00.000Z', 'lastDriveAt': '2026-10-20T12:00:00.000Z', 'settledPings': 200, 'confirmedPings': 150,
      },
      'weeks': [
        {'week': '2026-10-12', 'drives': 1, 'pings': 100, 'heardPings': 60, 'km': 20.5, 'newCells': 4},
        {'week': '2026-09-28', 'drives': 2, 'pings': 310, 'heardPings': 240, 'km': 66.9, 'newCells': 90},
        if (extra) ...[
          {'week': '2026-10-13', 'drives': 1}, // a Tuesday: not a week start
          {'week': 'garbage'},
          'nope',
        ],
      ],
      'drives': [
        {'id': 'd-old', 'callsign': 'KD8XYZ', 'label': null, 'startedAt': '2026-09-29T10:00:00Z', 'endedAt': '2026-09-29T11:00:00Z', 'pings': 200, 'heardPings': 150, 'echoes': 5, 'km': 40.0, 'bestSnr': 8.5, 'repeaters': 9, 'review': 'ok', 'flags': [], 'settledPings': 200, 'confirmedPings': 150},
        {'id': 'd-new', 'callsign': 'KD8XYZ', 'label': 'Long run', 'startedAt': '2026-10-14T10:00:00Z', 'endedAt': null, 'pings': 100, 'heardPings': 60, 'km': -3, 'bestSnr': null, 'repeaters': 'x', 'review': 'hidden', 'flags': ['gps-jump', 5, ''], 'settledPings': 0, 'confirmedPings': 0},
        if (extra) ...[
          {'id': 'no-start', 'pings': 3},
          {'startedAt': '2026-10-01T00:00:00Z'},
          {'id': 'd-new', 'startedAt': '2026-10-14T10:00:00Z'}, // duplicate id
          7,
        ],
      ],
    };

http.Response _json(Object b, [int status = 200]) => http.Response(jsonEncode(b), status, headers: {'content-type': 'application/json'});

void main() {
  group('parser', () {
    test('reads the live shape; bad rows are skipped and counted; unknown numbers are null, never 0', () {
      final d = DriverSummary.parse(body());
      expect(d.asOf, DateTime.utc(2026, 10, 25, 6));
      expect(d.stats.drives, 3);
      expect(d.stats.km, 87.4);
      expect(d.stats.heardPercent, 73);
      expect(d.stats.confirmedPercent, 75);
      expect(d.weeks.map((w) => w.monday), [DateTime.utc(2026, 9, 28), DateTime.utc(2026, 10, 12)], reason: 'oldest first');
      expect(d.drives.map((x) => x.id), ['d-new', 'd-old'], reason: 'newest first');
      final n = d.drives.first;
      expect(n.km, isNull, reason: 'negative = unreadable');
      expect(n.repeaters, isNull);
      expect(n.bestSnr, isNull);
      expect(n.endedAt, isNull);
      expect(n.flags, ['gps-jump']);
      expect(n.reviewWords, 'Hidden from the public maps');
      expect(d.drives.last.reviewWords, isNull);
      expect(d.skipped, 7);
      expect(d.isEmpty, isFalse);
    });

    test('a missing stats block is all-null; heard / confirmed percents need both numbers and a non-zero base', () {
      final d = DriverSummary.parse({'v': 1, 'weeks': [], 'drives': []});
      expect(d.stats.drives, isNull);
      expect(d.stats.heardPercent, isNull);
      expect(const ServerStats(settledPings: 0, confirmedPings: 0).confirmedPercent, isNull);
      expect(d.asOf, isNull);
    });

    test('an account with nothing is empty; another version is refused', () {
      expect(DriverSummary.parse({'v': 1, 'stats': {'drives': 0}, 'weeks': [], 'drives': []}).isEmpty, isTrue);
      expect(() => DriverSummary.parse({'v': 2}), throwsFormatException);
    });

    test('weeksFilled: holes become empty weeks (marked), extended to the current week; empty list stays empty', () {
      final d = DriverSummary.parse(body(extra: false));
      final w = d.weeksFilled(DateTime.utc(2026, 10, 26, 3)); // a Monday
      expect(w.map((x) => x.monday.day), [28, 5, 12, 19, 26]);
      expect(w.map((x) => x.filled), [false, true, false, true, true]);
      expect(w[1].drives, 0);
      expect(DriverSummary.parse({'v': 1}).weeksFilled(DateTime.utc(2026, 10, 26)), isEmpty);
    });
  });

  group('client', () {
    test('GET driver-summary with the key header; parsed', () async {
      late http.Request seen;
      final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((r) async {
        seen = r;
        return _json(body());
      }));
      final d = await c.driverSummary('KEY-1');
      expect(seen.method, 'GET');
      expect(seen.url.path, '/api/cmh/driver-summary');
      expect(seen.headers['x-driver-key'], 'KEY-1');
      expect(d.drives, hasLength(2));
    });

    test('401, 403 (with the status word), 429, a foreign body and no connection', () async {
      Future<CmatException> fail(http.Response r) async {
        final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => r));
        try {
          await c.driverSummary('k');
        } on CmatException catch (e) {
          return e;
        }
        fail2();
        throw StateError('unreachable');
      }

      final e401 = await fail(_json({'error': 'x-driver-key required'}, 401));
      expect(e401.status, 401);
      final e403 = await fail(_json({'error': 'revoked', 'status': 'revoked'}, 403));
      expect((e403.status, e403.serverStatus), (403, 'revoked'));
      expect((await fail(_json({'error': 'slow down'}, 429))).status, 429);
      final odd = await fail(_json({'v': 9}));
      expect(odd.message, contains('unreadable'));
      final net = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => throw const SocketException('down')));
      await expectLater(net.driverSummary('k'), throwsA(isA<CmatException>().having((e) => e.status, 'status', isNull)));
    });
  });

  group('cache', () {
    late Directory dir;
    var now = DateTime.utc(2026, 10, 25, 12);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ds_cache');
      now = DateTime.utc(2026, 10, 25, 12);
    });
    tearDown(() => dir.deleteSync(recursive: true));
    DriverSummaryCache cache([Directory? d]) => DriverSummaryCache(dir: d ?? dir, clock: () => now);
    final tag = DriverSummaryCache.tagOf('x.org', 'KEY-1');

    test('fresh for 5 minutes, then asked again; a forced refresh is floored at 10 s', () async {
      final c = cache();
      var asks = 0;
      Future<DriverSummary> ask() async {
        asks++;
        return DriverSummary.parse(body());
      }

      await c.get(tag, ask);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      await c.get(tag, ask);
      expect(asks, 1);
      await c.get(tag, ask, force: true);
      expect(asks, 2, reason: 'a forced refresh older than the 10 s floor asks');
      now = now.add(const Duration(minutes: 5, seconds: 1));
      await c.get(tag, ask);
      expect(asks, 3);
    });

    test('force inside 10 s is served from the copy; after 10 s it asks', () async {
      final c = cache();
      var asks = 0;
      Future<DriverSummary> ask() async {
        asks++;
        return DriverSummary.parse(body());
      }

      await c.get(tag, ask);
      now = now.add(const Duration(seconds: 9));
      await c.get(tag, ask, force: true);
      expect(asks, 1);
      now = now.add(const Duration(seconds: 2));
      await c.get(tag, ask, force: true);
      expect(asks, 2);
      now = now.add(const Duration(minutes: 5, seconds: 1));
      await c.get(tag, ask);
      expect(asks, 3);
    });

    test('offline: the stored copy with its own time, flagged offline; paused for a 429; nothing stored throws', () async {
      final c = cache();
      await c.get(tag, () async => DriverSummary.parse(body()));
      final at = now;
      now = now.add(const Duration(hours: 3));
      final off = await c.get(tag, () async => throw const CmatException('network error'));
      expect((off.offline, off.paused, off.fetchedAt), (true, false, at));
      now = now.add(const Duration(minutes: 6));
      final paused = await c.get(tag, () async => throw const CmatException('slow', status: 429));
      expect((paused.offline, paused.paused), (false, true));
      await expectLater(cache(Directory('${dir.path}/empty')).get(tag, () async => throw const CmatException('network error')), throwsA(isA<CmatException>()));
    });

    test('survives a restart; 401 / 403 delete the copy; the file holds no key', () async {
      await cache().get(tag, () async => DriverSummary.parse(body()));
      final file = dir.listSync().whereType<File>().single;
      final text = file.readAsStringSync();
      expect(text, isNot(contains('KEY-1')));
      expect(file.path, contains(tag));
      var asks = 0;
      final again = await cache().get(tag, () async {
        asks++;
        return DriverSummary.parse(body());
      });
      expect(asks, 0);
      expect(again.summary.drives, hasLength(2));
      now = now.add(const Duration(hours: 1));
      await expectLater(cache().get(tag, () async => throw const CmatException('no', status: 403, serverStatus: 'revoked')), throwsA(isA<CmatException>()));
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')), isEmpty);
    });

    test('another key or server is another copy; clear() removes them all; memory-only works', () async {
      final c = cache();
      await c.get(tag, () async => DriverSummary.parse(body()));
      await c.get(DriverSummaryCache.tagOf('x.org', 'KEY-2'), () async => DriverSummary.parse(body()));
      expect(tag, isNot(DriverSummaryCache.tagOf('x.org', 'KEY-2')));
      expect(tag, isNot(DriverSummaryCache.tagOf('y.org', 'KEY-1')));
      expect(await c.clear(), 2);
      final m = DriverSummaryCache(clock: () => now);
      expect((await m.get(tag, () async => DriverSummary.parse(body()))).stale, isFalse);
    });
  });
}

void fail2() => fail('expected a CmatException');
