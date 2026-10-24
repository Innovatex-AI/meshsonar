// The global network list parser: the exact contract of meshcore-insights feat/network-repeaters (0045), a tolerant
// envelope, strict rows.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/network_repeaters.dart';

final k1 = 'a1' * 32, k2 = 'b2' * 32, k3 = 'c3' * 32;

void main() {
  test('the server shape: {v:1, asOf, count, hidden, attribution, rows:[[key,name,lat,lon,type,adv]]}', () {
    final r = NetworkRepeaters.parse({
      'v': 1,
      'asOf': '2026-10-24T10:00:00.000Z',
      'generatedAt': '2026-10-24T10:05:00.000Z',
      'count': 2,
      'hidden': 4,
      'attribution': {'name': 'MeshCore Map', 'url': 'https://map.meshcore.io'},
      'rows': [
        [k1, 'Alpha', 40.1, -83.0, 2, 1792836000],
        [k2, null, 39.9, -84.1, 3, null],
      ],
    });
    expect(r.rows, hasLength(2));
    expect(r.asOf, DateTime.utc(2026, 10, 24, 10));
    expect(r.hidden, 4);
    expect(r.dropped, 0);
    final a = r.rows.firstWhere((x) => x.key == k1);
    expect(a.name, 'Alpha');
    expect(a.type, 2);
    expect(a.lastAdvert, DateTime.fromMillisecondsSinceEpoch(1792836000 * 1000, isUtc: true));
    final b = r.rows.firstWhere((x) => x.key == k2);
    expect(b.isRoom, isTrue);
    expect(b.displayName, k2.substring(0, 8));
    expect(b.lastAdvert, isNull);
  });

  test('tolerant envelope: a bare array, and object rows with named fields', () {
    expect(NetworkRepeaters.parse([
      [k1, 'A', 1.0, 2.0, 2, null]
    ]).rows.single.key, k1);
    final o = NetworkRepeaters.parse({
      'rows': [
        {'key': k1.toUpperCase(), 'name': 'A', 'lat': 1.5, 'lon': 2.5, 'type': 'repeater', 'last_advert': 1792836000000},
      ]
    });
    expect(o.rows.single.key, k1, reason: 'keys are lower-cased');
    expect(o.rows.single.lastAdvert, DateTime.fromMillisecondsSinceEpoch(1792836000000, isUtc: true), reason: 'ms read as ms');
  });

  test('strict rows: anything not a valid key + position + type is dropped, never guessed', () {
    final r = NetworkRepeaters.parse({
      'rows': [
        [k1, 'ok', 40.0, -83.0, 2, null],
        ['abc', 'short key', 40.0, -83.0, 2, null],
        [k2, 'zero', 0, 0, 2, null],
        [k2, 'lat out', 91, 0.5, 2, null],
        [k2, 'chat type', 40.0, -83.0, 1, null],
        [k2, 'string lat', '40', -83.0, 2, null],
        [k2, 42, 40.0, -83.0, 2, null],
        [k2, 'bad adv', 40.0, -83.0, 2, 'yesterday'],
        [k3],
        'not a row',
        null,
      ]
    });
    expect(r.rows.map((x) => x.key), [k1]);
    expect(r.dropped, 10);
  });

  test('duplicate keys keep the newest advert; maxRows keeps the newest', () {
    final r = NetworkRepeaters.parse([
      [k1, 'old', 40.0, -83.0, 2, 100],
      [k1, 'new', 40.0, -83.0, 2, 200],
    ]);
    expect(r.rows.single.name, 'new');
    final capped = NetworkRepeaters.parse([
      [k1, 'a', 40.0, -83.0, 2, 100],
      [k2, 'b', 40.0, -83.0, 2, 300],
      [k3, 'c', 40.0, -83.0, 2, 200],
    ], maxRows: 2);
    expect(capped.rows.map((x) => x.name).toSet(), {'b', 'c'});
    expect(capped.dropped, 1);
  });

  test('not this list at all is an error (a 200 HTML page or another version never wipes the stored list)', () {
    expect(() => NetworkRepeaters.parse('<html>'), throwsA(isA<NetworkRepeatersFormatException>()));
    expect(() => NetworkRepeaters.parse({'error': 'x'}), throwsA(isA<NetworkRepeatersFormatException>()));
    expect(() => NetworkRepeaters.parse({'v': 2, 'rows': []}), throwsA(isA<NetworkRepeatersFormatException>()));
  });

  test('compact row round trip and nearby (radius, advert age, nearest first)', () {
    final now = DateTime.utc(2026, 10, 24);
    final r = NetworkRepeaters.parse([
      [k1, 'near', 40.0, -83.0, 2, now.subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000],
      [k2, 'far', 45.0, -83.0, 2, null],
      [k3, 'old', 40.01, -83.0, 2, now.subtract(const Duration(days: 400)).millisecondsSinceEpoch ~/ 1000],
    ]);
    final back = NetworkRepeaters.parse([for (final x in r.rows) x.toRow()]);
    expect(back.rows.map((x) => x.key).toSet(), {k1, k2, k3});
    final near = r.nearby(40.05, -83.0, now: now);
    expect(near.map((x) => x.name), ['near']);
  });
}
