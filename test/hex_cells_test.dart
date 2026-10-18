// Hex coverage roll-up vs h3-js 4.5.0 (the website's library). Reference values were produced with
// h3-js: cellToParent(latLngToCell(lat, lon, 11), 9). The fifth point is one where that differs from
// latLngToCell(lat, lon, 9) (892a956ae8fffff), which is exactly why the roll-up goes through the parent.
//
// Needs libh3 on the machine running the tests (macOS: `brew install h3`, v4). Skipped when it is not there.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:meshsonar/core/hex_cells.dart';
import 'package:meshsonar/core/model.dart';

H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) {
      continue;
    }
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

DrivePing _tx(String id, double lat, double lon, {List<Echo> echoes = const [], PingKind kind = PingKind.tx}) =>
    DrivePing(id: id, ts: DateTime.utc(2026, 10, 18, 12), lat: lat, lon: lon, kind: kind, echoes: echoes);

void main() {
  final h3 = _load();
  final skip = h3 == null ? 'libh3 not found (brew install h3)' : false;

  const ref = <(double, double, String)>[
    (39.9612, -82.9988, '892a956a94bffff'),
    (39.9700, -83.0100, '892a956a86bffff'),
    (40.0001, -82.8800, '892a9560067ffff'),
    (39.8800, -83.1300, '892a91d222bffff'),
    (39.9959, -83.0123, '892a956aebbffff'),
    (39.9433, -82.9412, '892a9561b73ffff'),
    (40.1001, -83.2001, '892a90b40afffff'),
    (39.7112, -82.7321, '892a9183613ffff'),
  ];

  test('cell ids equal h3-js cellToParent(latLngToCell(res 11), 9), including the 6% where direct res 9 differs', () {
    for (final r in ref) {
      expect(hexId(hexCellOf(h3!, r.$1, r.$2)), r.$3, reason: '${r.$1},${r.$2}');
    }
    // the case the rule exists for
    final direct = h3!.geoToCell(GeoCoord(lon: -83.0123, lat: 39.9959), 9);
    expect(hexId(direct), '892a956ae8fffff');
    expect(hexId(hexCellOf(h3, 39.9959, -83.0123)), isNot('892a956ae8fffff'));
  }, skip: skip);

  test('boundary of the first cell matches h3-js cellToBoundary (6 corners)', () {
    final cells = buildHexCells([_tx('a', 39.9612, -82.9988)], h3!);
    expect(cells, hasLength(1));
    expect(cells.single.id, '892a956a94bffff');
    final b = cells.single.boundary;
    expect(b, hasLength(6));
    expect(b.first.lat, closeTo(39.96321833225654, 1e-9));
    expect(b.first.lon, closeTo(-82.99754267395762, 1e-9));
    expect(b.last.lat, closeTo(39.96257660343418, 1e-9));
    expect(b.last.lon, closeTo(-82.99527374223007, 1e-9));
  }, skip: skip);

  test('counts sent and heard per hexagon, best SNR, ignores rx pings and bad positions', () {
    const heardA = Echo(repeater: 'ab', snrDb: -4.0, rssiDbm: -100, hops: 1);
    const heardB = Echo(repeater: 'cd', snrDb: 6.5, rssiDbm: -90, hops: 1);
    final cells = buildHexCells([
      _tx('1', 39.9612, -82.9988),
      _tx('2', 39.9613, -82.9989, echoes: const [heardA, heardB]),
      _tx('3', 39.9614, -82.9987, echoes: const [heardA]),
      _tx('4', 39.9612, -82.9988, kind: PingKind.rx, echoes: const [heardB]),
      _tx('5', double.nan, -82.9988),
      _tx('6', 99, 0),
      _tx('7', 39.9700, -83.0100),
    ], h3!);
    expect(cells.map((c) => c.id), ['892a956a86bffff', '892a956a94bffff']);
    final a = cells.firstWhere((c) => c.id == '892a956a94bffff');
    expect((a.sent, a.heard, a.bestSnrDb), (3, 2, 6.5));
    expect(a.wasHeard, isTrue);
    final b = cells.firstWhere((c) => c.id == '892a956a86bffff');
    expect((b.sent, b.heard, b.bestSnrDb), (1, 0, null));
    expect(b.wasHeard, isFalse);
    expect(hexTotals(cells), (cells: 2, heardCells: 1));
  }, skip: skip);

  test('no pings, no cells', () {
    expect(buildHexCells(const [], h3!), isEmpty);
  }, skip: skip);
}
