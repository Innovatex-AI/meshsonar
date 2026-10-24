import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/repeater_points.dart';

final now = DateTime.utc(2026, 10, 24, 12);
String k(String c) => c * 64;

MapRepeaterRow row(String key, {double lat = 40, double lon = -83, String? name, bool room = false, DateTime? seen, int? band}) =>
    MapRepeaterRow(key: key, lat: lat, lon: lon, name: name, isRoom: room, lastSeen: seen, band: band);

void main() {
  test('age bands match the website edges (24 h / 7 d / 30 d, inclusive), null = older', () {
    expect(advertAgeBand(now, now), 0);
    expect(advertAgeBand(now.subtract(const Duration(hours: 24)), now), 0);
    expect(advertAgeBand(now.subtract(const Duration(hours: 24, seconds: 1)), now), 1);
    expect(advertAgeBand(now.subtract(const Duration(days: 7)), now), 1);
    expect(advertAgeBand(now.subtract(const Duration(days: 7, seconds: 1)), now), 2);
    expect(advertAgeBand(now.subtract(const Duration(days: 30)), now), 2);
    expect(advertAgeBand(now.subtract(const Duration(days: 30, seconds: 1)), now), 3);
    expect(advertAgeBand(null, now), 3);
    expect(advertAgeBand(now.add(const Duration(hours: 1)), now), 0, reason: 'a clock a little ahead is "fresh"');
    expect(kAdvertAgeBandLabels, hasLength(4));
  });

  test('advertText (website wording)', () {
    expect(advertText(null, now), 'No advert time reported');
    expect(advertText(now.subtract(const Duration(seconds: 10)), now), 'Last advert 1 min ago (2026-10-24)');
    expect(advertText(now.subtract(const Duration(minutes: 42)), now), 'Last advert 42 min ago (2026-10-24)');
    expect(advertText(now.subtract(const Duration(hours: 3)), now), 'Last advert 3 h ago (2026-10-24)');
    expect(advertText(now.subtract(const Duration(days: 3)), now), 'Last advert 3 days ago (2026-10-21)');
    expect(advertText(now.subtract(const Duration(hours: 3)), now, verb: 'Last heard'), 'Last heard 3 h ago (2026-10-24)');
  });

  test('placeable: the website validRow position rules', () {
    expect(isPlaceable(row(k('a'))), isTrue);
    expect(isPlaceable(row(k('a'), lat: 0, lon: 0)), isFalse, reason: '0/0 is "no position"');
    expect(isPlaceable(row(k('a'), lat: 0, lon: 1)), isTrue);
    expect(isPlaceable(row(k('a'), lat: 91)), isFalse);
    expect(isPlaceable(row(k('a'), lon: -180.5)), isFalse);
    expect(isPlaceable(row(k('a'), lat: double.nan)), isFalse);
    expect(isPlaceable(row(k('a'), lon: double.infinity)), isFalse);
    expect(isPlaceable(row('not-hex')), isFalse);
    expect(isPlaceable(row('')), isFalse);
  });

  test('fromRows: drops bad rows, dedupes by key (newest wins), names fall back to key[0:8], keeps input order', () {
    final pts = RepeaterPoints.fromRows([
      row(k('b'), name: '  Tower B ', seen: now.subtract(const Duration(days: 2))),
      row(k('a'), name: null, room: true, seen: now.subtract(const Duration(hours: 1))),
      row(k('c'), lat: 0, lon: 0),
      row(k('b'), name: 'Tower B new', lat: 41, seen: now.subtract(const Duration(hours: 2))),
      row(k('b'), name: 'Tower B old', lat: 42, seen: now.subtract(const Duration(days: 40))),
      row(k('D'), name: '', seen: null),
    ], now: now);
    expect(pts.length, 3);
    expect(pts.key, [k('b'), k('a'), k('d')]);
    expect(pts.name, ['Tower B new', 'aaaaaaaa', 'dddddddd']);
    expect(pts.lat[0], 41);
    expect(pts.band.toList(), [0, 0, 3]);
    expect(pts.kind.toList(), [2, 3, 2]);
    expect(pts.isRoom(1), isTrue);
    expect(pts.dropped, 3, reason: 'one 0/0 row and two duplicate keys');
    expect(pts.lastSeen(2), isNull);
    expect(pts.lastSeen(1), now.subtract(const Duration(hours: 1)));
    expect(pts.indexOf(k('A')), 1);
    expect(pts.indexOf(k('e')), -1);
  });

  test('fromRows: an explicit band wins over the age band (roster status)', () {
    final pts = RepeaterPoints.fromRows([row(k('a'), band: 2, seen: now)], now: now);
    expect(pts.band[0], 2);
  });

  test('fromRows: skipKeys leaves out keys another layer draws, and counts them', () {
    final pts = RepeaterPoints.fromRows([row(k('a')), row(k('b'))], now: now, skipKeys: {k('a')});
    expect(pts.key, [k('b')]);
    expect(pts.skipped, 1);
    expect(pts.dropped, 0);
  });

  test('empty', () {
    final pts = RepeaterPoints.fromRows(const [], now: now);
    expect(pts.isEmpty, isTrue);
    expect(RepeaterPoints.empty.length, 0);
  });
}
