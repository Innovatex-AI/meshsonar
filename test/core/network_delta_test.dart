// Delta refresh of the global repeater list (`GET network-repeaters?updated_since=<epochS>`, capability
// `networkRepeatersDelta`): apply rules (removed first, then upsert by key), cursor math, idempotent repeats, every
// fallback to the full list (410, refusals, bad bodies, stale store, capability off, nothing stored), persistence
// (round trip, damaged file, files from before deltas), the 304 path without the capability, and the bytes saved.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/network_repeaters.dart';
import 'package:meshsonar/core/repeater_sync.dart';

String key(int i) => i.toRadixString(16).padLeft(4, '0') * 16; // 64 hex characters

List<Object?> row(int i, {String? name, double lat = 40.0, double lon = -83.0, int type = 2, int? adv = 1792800000}) =>
    [key(i), name ?? 'R$i', lat, lon, type, adv];

int epochS(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

class _Clock {
  DateTime t = DateTime.utc(2026, 10, 24, 12);
  DateTime call() => t;
  void advance(Duration d) => t = t.add(d);
}

/// A fake server for network-repeaters: a full body, a programmable delta answer, and a record of what was asked.
class DeltaServer {
  final List<http.Request> seen = [];
  Map<String, dynamic> full;
  String etag = '"n1"';
  int fullStatus = 200;

  /// Called with the requested `updated_since`; returns the response.
  http.Response Function(int since)? delta;
  bool offline = false;

  DeltaServer(this.full);

  Iterable<http.Request> get deltaCalls => seen.where((r) => r.url.queryParameters.containsKey('updated_since'));
  Iterable<http.Request> get fullCalls => seen.where((r) => !r.url.queryParameters.containsKey('updated_since'));

  late final client = MockClient((req) async {
    seen.add(req);
    if (offline) throw const SocketException('offline');
    final q = req.url.queryParameters['updated_since'];
    if (q != null) {
      final d = delta;
      if (d == null) return http.Response('{"error":"nope"}', 404);
      return d(int.parse(q));
    }
    if (fullStatus != 200) return http.Response('{"error":"x"}', fullStatus);
    if (req.headers['if-none-match'] == etag) return http.Response('', 304, headers: {'etag': etag});
    return http.Response(jsonEncode(full), 200, headers: {'etag': etag});
  });
}

Map<String, dynamic> fullBody(List<List<Object?>> rows, {String asOf = '2026-10-24T11:00:00.987Z', int hidden = 3}) =>
    {'v': 1, 'asOf': asOf, 'generatedAt': '2026-10-24T11:05:00Z', 'count': rows.length, 'hidden': hidden, 'rows': rows};

http.Response deltaResponse({
  List<List<Object?>> rows = const [],
  List<String> removed = const [],
  required int asOfS,
  int? since,
  Map<String, Object?> extra = const {},
}) {
  final body = <String, Object?>{
    'v': 1,
    'asOf': DateTime.fromMillisecondsSinceEpoch(asOfS * 1000, isUtc: true).toIso8601String(),
    'asOfS': asOfS,
    'since': since ?? asOfS - 600,
    'generatedAt': '2026-10-24T12:00:00Z',
    'count': rows.length,
    'removedCount': removed.length,
    'rows': rows,
    'removed': removed,
    ...extra,
  };
  return http.Response(jsonEncode(body), 200, headers: {'etag': '"d${body['asOfS']}"'});
}

void main() {
  late Directory dir;
  late _Clock clock;
  late List<String> logs;
  final hub = Uri.parse('https://meshsonar.com');
  final made = <RepeaterSync>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ms_delta_');
    clock = _Clock();
    logs = [];
  });
  tearDown(() async {
    for (final m in made) {
      await m.writesDone;
    }
    made.clear();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  RepeaterSync make(DeltaServer s, {bool capable = true, bool isolate = false, bool store = true}) {
    final sync = RepeaterSync(
      store: store ? RepeaterSyncStore(dir, parseInIsolate: isolate) : null,
      networkClient: () => s.client,
      rosterClient: () => s.client,
      clock: clock.call,
      parseInIsolate: isolate,
      deltaCapable: () => capable,
    )..log = logs.add;
    made.add(sync);
    return sync;
  }

  /// A stored full list of keys [1..n] at the fake clock, then 7 h later (past the 6 h gate).
  Future<RepeaterSync> primed(DeltaServer s, {bool capable = true, bool isolate = false}) async {
    final sync = make(s, capable: capable, isolate: isolate);
    expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.launch), isTrue);
    clock.advance(const Duration(hours: 7));
    return sync;
  }

  List<String> keys(RepeaterSync s) => [for (final r in s.network!.data.rows) r.key];

  group('NetworkDelta.parse / applyTo', () {
    test('removed first, then upserts; stored order kept, new keys appended; hidden kept', () {
      final base = NetworkRepeaters.parse(fullBody([row(1), row(2), row(3)]));
      final d = NetworkDelta.parse(
        jsonDecode(deltaResponse(rows: [row(2, name: 'Two!'), row(4)], removed: [key(3)], asOfS: 1792843000).body),
      );
      final out = d.applyTo(base);
      expect(out.rows.map((r) => r.key), [key(1), key(2), key(4)]);
      expect(out.rows[1].name, 'Two!');
      expect(out.hidden, 3);
      expect(out.asOf, DateTime.utc(2026, 10, 24, 11, 56, 40));
    });

    test('removed then re-added in one delta: present with the new data; added then removed across two deltas: gone', () {
      final base = NetworkRepeaters.parse(fullBody([row(1), row(2)]));
      final both = NetworkDelta.parse(jsonDecode(deltaResponse(rows: [row(1, name: 'Back')], removed: [key(1)], asOfS: 1792843000).body));
      expect(both.applyTo(base).rows.firstWhere((r) => r.key == key(1)).name, 'Back');
      final add = NetworkDelta.parse(jsonDecode(deltaResponse(rows: [row(5)], asOfS: 1792843000).body)).applyTo(base);
      expect(add.rows.map((r) => r.key), contains(key(5)));
      final gone = NetworkDelta.parse(jsonDecode(deltaResponse(removed: [key(5)], asOfS: 1792843100).body)).applyTo(add);
      expect(gone.rows.map((r) => r.key), [key(1), key(2)]);
    });

    test('applying the same delta twice gives the same list (the last two minutes repeat on purpose)', () {
      final base = NetworkRepeaters.parse(fullBody([row(1), row(2), row(3)]));
      final d = NetworkDelta.parse(jsonDecode(deltaResponse(rows: [row(2, name: 'X'), row(9)], removed: [key(3)], asOfS: 1792843000).body));
      final once = d.applyTo(base), twice = d.applyTo(once);
      expect([for (final r in twice.rows) r.toRow()], [for (final r in once.rows) r.toRow()]);
    });

    test('an empty delta keeps the very same rows list (a map layer comparing identity does not rebuild)', () {
      final base = NetworkRepeaters.parse(fullBody([row(1)]));
      final d = NetworkDelta.parse(jsonDecode(deltaResponse(asOfS: 1792843000).body));
      expect(d.isEmpty, isTrue);
      expect(identical(d.applyTo(base).rows, base.rows), isTrue);
    });

    test('a row the app cannot use deletes its key (the full list would not hold it either); unreadable rows are only counted', () {
      final base = NetworkRepeaters.parse(fullBody([row(1), row(2)]));
      final bad = [key(1), 'Moved to nowhere', 0.0, 0.0, 2, null]; // 0/0 is not a position
      final d = NetworkDelta.parse(jsonDecode(deltaResponse(rows: [bad, ['nope']], asOfS: 1792843000).body));
      expect(d.dropped, 2);
      expect(d.invalidKeys, [key(1)]);
      expect(d.applyTo(base).rows.map((r) => r.key), [key(2)]);
    });

    test('envelope errors throw: not an object, v, missing lists, no or fractional cursor, count mismatches', () {
      Map<String, Object?> ok() => jsonDecode(deltaResponse(rows: [row(1)], removed: [key(2)], asOfS: 1792843000).body) as Map<String, Object?>;
      expect(() => NetworkDelta.parse(ok()), returnsNormally);
      for (final bad in <Object?>[
        '<html>',
        [1],
        {...ok(), 'v': 2},
        {...ok()..remove('v')},
        {...ok()..remove('rows')},
        {...ok()..remove('removed')},
        {...ok(), 'removed': 'x'},
        {...ok()..remove('asOfS')},
        {...ok(), 'asOfS': 12.5},
        {...ok(), 'asOfS': 0},
        {...ok(), 'count': 9},
        {...ok(), 'removedCount': 0},
      ]) {
        expect(() => NetworkDelta.parse(bad), throwsA(isA<NetworkRepeatersFormatException>()), reason: '$bad');
      }
    });

    test('a result that would lose half of a big list, or pass the cap, is refused', () {
      final base = NetworkRepeaters.parse(fullBody([for (var i = 1; i <= 1200; i++) row(i)]));
      final d = NetworkDelta.parse(jsonDecode(deltaResponse(removed: [for (var i = 1; i <= 700; i++) key(i)], asOfS: 1792843000).body));
      expect(() => d.applyTo(base), throwsA(isA<NetworkRepeatersFormatException>()));
      final small = NetworkRepeaters.parse(fullBody([row(1), row(2)]));
      final grow = NetworkDelta.parse(jsonDecode(deltaResponse(rows: [row(3), row(4)], asOfS: 1792843000).body));
      expect(() => grow.applyTo(small, maxRows: 3), throwsA(isA<NetworkRepeatersFormatException>()));
    });

    test('the live contract shape (trimmed capture, Oct 25 2026) parses and applies', () {
      final delta = NetworkDelta.parse(jsonDecode(File('test/fixtures/network_repeaters_delta_live_trimmed.json').readAsStringSync()));
      expect(delta.rows, hasLength(4));
      expect(delta.removed, hasLength(3));
      expect(delta.asOfS, 1792905224);
      expect(delta.since, 1792903920);
      expect(delta.asOf, DateTime.utc(2026, 10, 25, 5, 13, 44));
      final full = NetworkRepeaters.parse(jsonDecode(File('test/fixtures/network_repeaters_full_live_trimmed.json').readAsStringSync()));
      expect(deltaCursorOf(full), epochS(DateTime.utc(2026, 10, 25, 4, 52, 7)), reason: 'floor of asOf 04:52:07.427');
      final merged = delta.applyTo(full);
      for (final r in delta.rows) {
        expect(merged.rows.where((x) => x.key == r.key), hasLength(1));
      }
    });
  });

  group('RepeaterSync: delta refresh', () {
    test('cursor after a full download = floor(asOf / 1000); the first refresh asks updated_since=<cursor>, no ETag', () async {
      final s = DeltaServer(fullBody([row(1), row(2), row(3)]));
      final sync = await primed(s);
      expect(sync.network!.cursorS, epochS(DateTime.utc(2026, 10, 24, 11)), reason: 'asOf ...11:00:00.987Z floors to the second');
      final cursor = sync.network!.cursorS!;
      final asOfS = epochS(clock.t) - 120;
      s.delta = (since) => deltaResponse(rows: [row(2, name: 'Two!'), row(4)], removed: [key(3)], asOfS: asOfS, since: since);
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isTrue);
      final req = s.deltaCalls.single;
      expect(req.url.queryParameters, {'updated_since': '$cursor'});
      expect(req.url.path, '/api/cmh/network-repeaters');
      expect(req.headers.keys.map((k) => k.toLowerCase()).toSet(), {'accept'});
      expect(keys(sync), [key(1), key(2), key(4)]);
      expect(sync.network!.data.rows[1].name, 'Two!');
      expect(sync.network!.cursorS, asOfS, reason: 'the cursor moves to the answer\'s asOfS');
      expect(sync.network!.etag, isNull, reason: 'the full body\'s ETag no longer describes the list');
      expect(sync.network!.data.hidden, 3);
      expect(sync.globalSet.state, SyncState.ready);
      expect(sync.networkLabel, 'Updated just now');
      expect(logs.last, contains('delta +2 changed, -1 removed'));
      expect(s.fullCalls, hasLength(1), reason: 'only the first download was a full one');
    });

    test('repeats are idempotent and the cursor keeps following asOfS; an empty delta keeps the rows list identity', () async {
      final s = DeltaServer(fullBody([row(1), row(2)]));
      final sync = await primed(s);
      final asked = <int>[];
      s.delta = (since) {
        asked.add(since);
        // The same rows every time (the server's two-minute lag repeats them).
        return deltaResponse(rows: [row(2, name: 'Two!')], asOfS: epochS(clock.t) - 120, since: since);
      };
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      final first = [for (final r in sync.network!.data.rows) r.toRow()];
      clock.advance(const Duration(hours: 7));
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect([for (final r in sync.network!.data.rows) r.toRow()], first);
      expect(asked[1], epochS(clock.t) - const Duration(hours: 7).inSeconds - 120);
      final rowsBefore = sync.network!.data.rows;
      s.delta = (since) => deltaResponse(asOfS: epochS(clock.t) - 120, since: since);
      clock.advance(const Duration(hours: 7));
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(identical(sync.network!.data.rows, rowsBefore), isTrue);
      expect(identical(sync.globalSet.rows, rowsBefore), isTrue);
      expect(sync.network!.cursorS, epochS(clock.t) - 120);
    });

    test('persists atomically and survives a restart: the next run continues from the stored cursor', () async {
      final s = DeltaServer(fullBody([row(1), row(2)]));
      final sync = await primed(s);
      final asOfS = epochS(clock.t) - 120;
      s.delta = (since) => deltaResponse(rows: [row(7)], removed: [key(1)], asOfS: asOfS, since: since);
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      await sync.writesDone;
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
      final file = jsonDecode(File('${dir.path}/network.json').readAsStringSync()) as Map;
      expect(file['v'], 1);
      expect(file['cursorS'], asOfS);
      expect(file['etag'], isNull);

      final s2 = make(s);
      await s2.load();
      expect(keys(s2), [key(2), key(7)]);
      expect(s2.network!.cursorS, asOfS);
      clock.advance(const Duration(hours: 7));
      final asOf2 = epochS(clock.t) - 120;
      s.delta = (since) => deltaResponse(rows: [row(8)], asOfS: asOf2, since: since);
      await s2.syncNetwork(server: hub, trigger: SyncTrigger.launch);
      expect(s.deltaCalls.last.url.queryParameters['updated_since'], '$asOfS');
      expect(keys(s2), [key(2), key(7), key(8)]);
    });

    test('a damaged network.json costs one full download; a file from before deltas gets its cursor from asOf', () async {
      final s = DeltaServer(fullBody([row(1)]));
      final sync = await primed(s);
      await sync.writesDone;
      await File('${dir.path}/network.json').writeAsString('{"v":1,"rows":[[');
      final s2 = make(s);
      await s2.load();
      expect(s2.network, isNull);
      expect(await s2.syncNetwork(server: hub, trigger: SyncTrigger.launch), isTrue);
      expect(s.deltaCalls, isEmpty, reason: 'nothing stored = nothing to delta from');
      expect(s.fullCalls, hasLength(2));

      await s2.writesDone;
      final j = jsonDecode(File('${dir.path}/network.json').readAsStringSync()) as Map<String, dynamic>;
      j
        ..remove('cursorS')
        ..remove('fullAt');
      await File('${dir.path}/network.json').writeAsString(jsonEncode(j));
      final s3 = make(s);
      await s3.load();
      expect(s3.network!.cursorS, epochS(DateTime.utc(2026, 10, 24, 11)));
      expect(s3.network!.fullAt, s3.network!.fetchedAt);
    });

    test('bytes and requests saved: a delta of 20 changes out of 3,000 rows costs a small fraction of the full list', () async {
      final rows = [for (var i = 1; i <= 3000; i++) row(i, name: 'Repeater number $i', lat: 40 + i / 10000, lon: -83 - i / 10000)];
      final s = DeltaServer(fullBody(rows));
      final sync = make(s);
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.launch);
      final fullBytes = sync.networkBytesIn;
      expect(fullBytes, greaterThan(200000));
      expect(sync.networkRequests, 1);
      for (var round = 1; round <= 4; round++) {
        clock.advance(const Duration(hours: 7));
        s.delta = (since) => deltaResponse(
          rows: [for (var i = 1; i <= 20; i++) row(i, name: 'Renamed $round-$i')],
          removed: [key(3000 - round)],
          asOfS: epochS(clock.t) - 120,
          since: since,
        );
        await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      }
      expect(sync.networkRequests, 5);
      final deltaBytes = sync.networkBytesIn - fullBytes;
      expect(deltaBytes, lessThan(fullBytes * 4 * 0.02), reason: '4 deltas cost under 2% of 4 full downloads');
      expect(s.fullCalls, hasLength(1));
      expect(sync.network!.data.rows, hasLength(3000 - 4));
      expect(sync.network!.data.rows.first.name, 'Renamed 4-1');
    });

    test('a large delta body is decoded in the background isolate (nothing unsendable is captured)', () async {
      final s = DeltaServer(fullBody([for (var i = 1; i <= 50; i++) row(i)]));
      final sync = await primed(s, isolate: true);
      s.delta = (since) => deltaResponse(
        rows: [for (var i = 1; i <= 1500; i++) row(i, name: 'Changed repeater with a long enough name $i')],
        asOfS: epochS(clock.t) - 120,
        since: since,
      );
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isTrue);
      expect(s.deltaCalls.single.url.queryParameters.keys, ['updated_since']);
      expect(sync.network!.data.rows, hasLength(1500));
      expect(sync.networkError, isNull);
    });
  });

  group('RepeaterSync: fallbacks to the full list (once, quietly)', () {
    test('410 since_too_old: one delta request, then the full list in the same sync; the next window does not loop', () async {
      final s = DeltaServer(fullBody([row(1), row(2)]));
      final sync = await primed(s);
      s.delta = (_) => http.Response('{"error":"too old","code":"since_too_old"}', 410);
      s.full = fullBody([row(1), row(2), row(3)], asOf: '2026-10-24T18:30:00Z');
      s.etag = '"n2"';
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isTrue);
      expect(s.deltaCalls, hasLength(1));
      expect(s.fullCalls, hasLength(2));
      expect(keys(sync), [key(1), key(2), key(3)]);
      expect(sync.network!.cursorS, epochS(DateTime.utc(2026, 10, 24, 18, 30)));
      expect(sync.networkError, isNull, reason: 'never an error for the person');
      expect(logs.where((l) => l.contains('delta refused (HTTP 410)')), hasLength(1));
      expect(sync.networkCapability, NetworkCapability.available, reason: 'a delta 410 does not mean the list is absent');
    });

    test('410 and the full list is the very list we hold (collector idle): no delta again until the list moves', () async {
      final s = DeltaServer(fullBody([row(1)], asOf: '2026-10-24T11:00:00Z'));
      final sync = await primed(s);
      s.delta = (_) => http.Response('{"code":"since_too_old"}', 410);
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(s.deltaCalls, hasLength(1));
      expect(s.fullCalls.last.headers['if-none-match'], '"n1"', reason: 'the fallback revalidates with the stored ETag');
      expect(sync.network!.data.rows, hasLength(1));
      for (var i = 0; i < 3; i++) {
        clock.advance(const Duration(hours: 7));
        await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      }
      expect(s.deltaCalls, hasLength(1), reason: 'not retried while the held list does not change');
      expect(s.fullCalls, hasLength(5), reason: '1 first download + 1 fallback + 3 cheap 304 revalidations');
      // The collector writes again: a new full list is held, the delta is allowed again.
      s.full = fullBody([row(1), row(2)], asOf: '2026-10-25T03:00:00Z');
      s.etag = '"n2"';
      clock.advance(const Duration(hours: 7));
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      clock.advance(const Duration(hours: 7));
      s.delta = (since) => deltaResponse(asOfS: epochS(clock.t) - 120, since: since);
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(s.deltaCalls, hasLength(2));
    });

    test('400/404/304 from the delta and bodies that are not a consistent delta all fall back to the full list', () async {
      final bodies = <String, http.Response Function(int)>{
        '400': (_) => http.Response('{"error":"bad"}', 400),
        '404': (_) => http.Response('{"error":"nope"}', 404),
        '304': (_) => http.Response('', 304),
        'html': (_) => http.Response('<html>maintenance</html>', 200),
        'version 2': (since) => http.Response(jsonEncode({'v': 2, 'rows': [], 'removed': [], 'asOfS': since + 10}), 200),
        'no removed list': (since) => http.Response(jsonEncode({'v': 1, 'rows': [], 'asOfS': since + 10}), 200),
        'count mismatch': (since) => deltaResponse(rows: [row(9)], asOfS: since + 10, extra: {'count': 5}),
        'removedCount mismatch': (since) => deltaResponse(removed: [key(1)], asOfS: since + 10, extra: {'removedCount': 4}),
        'no cursor': (since) => http.Response(jsonEncode({'v': 1, 'rows': [], 'removed': []}), 200),
        'cursor in the future': (_) => deltaResponse(asOfS: epochS(clock.t) + 86400),
        'cursor goes backwards': (_) => deltaResponse(asOfS: 1000),
      };
      for (final e in bodies.entries) {
        final s = DeltaServer(fullBody([row(1), row(2)]));
        final sync = await primed(s);
        s.delta = e.value;
        s.full = fullBody([row(1), row(2), row(3)], asOf: '2026-10-24T18:59:00Z');
        s.etag = '"n2"';
        expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isTrue, reason: e.key);
        expect(s.deltaCalls, hasLength(1), reason: e.key);
        expect(s.fullCalls, hasLength(2), reason: e.key);
        expect(keys(sync), [key(1), key(2), key(3)], reason: e.key);
        expect(sync.networkError, isNull, reason: e.key);
        expect(logs.where((l) => l.contains('delta') && l.contains('full list')), hasLength(1), reason: '${e.key}: one quiet log line');
        logs.clear();
        await sync.writesDone;
        for (final f in dir.listSync()) {
          f.deleteSync();
        }
      }
    });

    test('an inconsistent result (half of a big list removed) is not applied: the full list replaces it', () async {
      final s = DeltaServer(fullBody([for (var i = 1; i <= 1200; i++) row(i)]));
      final sync = await primed(s);
      s.delta = (since) => deltaResponse(removed: [for (var i = 1; i <= 700; i++) key(i)], asOfS: epochS(clock.t) - 120, since: since);
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(sync.network!.data.rows, hasLength(1200), reason: 'the server\'s full list wins');
      expect(s.fullCalls, hasLength(2));
      expect(logs.any((l) => l.contains('would shrink')), isTrue);
    });

    test('capability off or unknown: the full list with ETag, exactly as before (304 keeps the rows and the cursor)', () async {
      final s = DeltaServer(fullBody([row(1), row(2)]));
      final sync = await primed(s, capable: false);
      s.delta = (since) => deltaResponse(rows: [row(9)], asOfS: epochS(clock.t), since: since);
      final cursor = sync.network!.cursorS;
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isTrue);
      expect(s.deltaCalls, isEmpty);
      expect(s.fullCalls.last.headers['if-none-match'], '"n1"');
      expect(keys(sync), [key(1), key(2)], reason: '304: stored rows stay');
      expect(sync.network!.cursorS, cursor);
      expect(sync.network!.checkedAt, clock.t);
      expect(logs.where((l) => l.contains('delta')), isEmpty, reason: 'nothing to say when the capability is off');
    });

    test('nothing stored: a full download even with the capability on', () async {
      final s = DeltaServer(fullBody([row(1)]));
      final sync = make(s);
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.launch);
      expect(s.deltaCalls, isEmpty);
      expect(s.fullCalls, hasLength(1));
    });

    test('a stored list more than 13 days behind is downloaded in full without asking for a delta', () async {
      final s = DeltaServer(fullBody([row(1)]));
      final sync = await primed(s);
      clock.advance(const Duration(days: 14));
      s.delta = (since) => deltaResponse(asOfS: epochS(clock.t) - 120, since: since);
      s.etag = '"n2"';
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(s.deltaCalls, isEmpty, reason: 'the server would answer 410 beyond 14 days: not even asked');
      expect(s.fullCalls, hasLength(2));
      expect(logs.where((l) => l.contains('days behind')), hasLength(1));

    });

    test('the drift guard: a delta-maintained list is downloaded in full again 30 days after its last full download', () async {
      final s = DeltaServer(fullBody([row(1)]));
      final sync = await primed(s);
      for (var step = 1; step <= 2; step++) {
        clock.advance(const Duration(days: 10));
        s.delta = (since) => deltaResponse(asOfS: epochS(clock.t) - 120, since: since);
        await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      }
      expect(s.deltaCalls, hasLength(2));
      expect(s.fullCalls, hasLength(1));
      clock.advance(const Duration(days: 10));
      s.etag = '"n2"';
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(s.deltaCalls, hasLength(2), reason: 'no delta this time');
      expect(s.fullCalls, hasLength(2));
      expect(sync.network!.fullAt, clock.t);
      expect(logs.any((l) => l.contains('last full download was 30 days ago')), isTrue);
    });

    test('a failing delta (offline, 5xx, 429) is a normal network failure: stored list kept, no full download', () async {
      final s = DeltaServer(fullBody([row(1), row(2)]));
      final sync = await primed(s);
      s.delta = (_) => http.Response('{"error":"busy"}', 503);
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isFalse);
      expect(sync.networkError, 'HTTP 503');
      expect(s.fullCalls, hasLength(1), reason: 'no full download behind a 503');
      expect(keys(sync), [key(1), key(2)]);
      expect(sync.globalSet.state, SyncState.stale);
      clock.advance(const Duration(hours: 7));
      s.delta = (_) => http.Response('', 429);
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isFalse);
      s.offline = true;
      clock.advance(const Duration(hours: 7));
      expect(await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume), isFalse);
      expect(s.fullCalls, hasLength(1));
      expect(keys(sync), [key(1), key(2)]);
      expect(sync.networkLabel, startsWith('Offline - as of'));
    });

    test('the 6 h gate, force floor and one-request-at-a-time still apply to delta refreshes', () async {
      final s = DeltaServer(fullBody([row(1)]));
      final sync = await primed(s);
      s.delta = (since) => deltaResponse(asOfS: epochS(clock.t) - 120, since: since);
      await Future.wait([for (var i = 0; i < 4; i++) sync.syncNetwork(server: hub, trigger: SyncTrigger.resume)]);
      expect(s.deltaCalls, hasLength(1));
      clock.advance(const Duration(hours: 1));
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.resume);
      expect(s.deltaCalls, hasLength(1), reason: 'inside the 6 h gate');
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.force);
      expect(s.deltaCalls, hasLength(2));
      await sync.syncNetwork(server: hub, trigger: SyncTrigger.force);
      expect(s.deltaCalls, hasLength(2), reason: 'inside the force floor');
    });
  });
}
