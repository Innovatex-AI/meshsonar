// "Where to drive next": silent cells and unmapped hexagons near the phone, nearest first and spaced apart. The unmapped
// part needs libh3 (macOS: brew install h3) and is skipped without it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_next.dart';

H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

CoverageCell cell(double lat, double lon, {int pings = 5, int heard = 0, String? h3}) => CoverageCell(
    lat: lat, lon: lon, pings: pings, heard: heard, bestSnr: heard > 0 ? 3 : null, medianSnr: null, repeaters: heard > 0 ? 1 : 0, lastAt: '2026-10-30T12:00:00Z', h3: h3);

PublicCoverage squares(List<CoverageCell> cells) =>
    PublicCoverage(cells: cells, asOf: '2026-10-31T00:00:00Z', grid: const CoverageGrid.square(cellDeg: 0.005));

void main() {
  const lat = 39.96, lon = -83.0;

  test('silent cells: only heard == 0 with pings, within range, nearest first, spaced apart', () {
    final cov = squares([
      cell(lat + 0.03, lon, heard: 0), // 3.3 km north
      cell(lat + 0.031, lon, heard: 0), // 100 m from the one above: dropped by spacing
      cell(lat, lon + 0.01, heard: 0), // 850 m east: nearest
      cell(lat + 0.001, lon, heard: 4), // heard: not a gap
      cell(lat + 0.002, lon, pings: 0, heard: 0), // no pings at all: not "mapped silent"
      cell(lat + 0.5, lon, heard: 0), // 55 km: out of range
    ]);
    final r = driveNextTargets(coverage: cov, lat: lat, lon: lon);
    expect(r.map((t) => t.kind).toSet(), {DriveTargetKind.silent});
    expect(r.length, 2);
    expect(r.first.lon, lon + 0.01);
    expect(r.first.distanceM, closeTo(850, 40));
    expect(r.last.lat, lat + 0.03);
  });

  test('no coverage yet gives nothing; square grids never invent unmapped hexagons', () {
    expect(driveNextTargets(coverage: null, lat: lat, lon: lon), isEmpty);
    expect(driveNextTargets(coverage: squares([cell(lat, lon, heard: 2)]), lat: lat, lon: lon), isEmpty);
  });

  test('distance and bearing', () {
    expect(distanceMetres(0, 0, 0, 1), closeTo(111195, 100));
    expect(bearingDegrees(0, 0, 1, 0), closeTo(0, 0.01));
    expect(bearingDegrees(0, 0, 0, 1), closeTo(90, 0.01));
    expect(bearingDegrees(0, 0, -1, 0), closeTo(180, 0.01));
  });

  test('Apple Maps link asks for driving directions to the point', () {
    final u = appleMapsDirections(39.96, -83.0, label: 'x');
    expect(u.host, 'maps.apple.com');
    expect(u.queryParameters['daddr'], '39.960000,-83.000000');
    expect(u.queryParameters['dirflg'], 'd');
  });

  final h3 = _load();
  test('unmapped hexagons: rings around you minus every measured cell, never the ones with data', () {
    final me = h3!.geoToCell(GeoCoord(lon: lon, lat: lat), 8);
    final ring = h3.gridDisk(me, 2);
    // Measure the origin and everything one ring out at res 9 (children roll up to res 8 parents).
    final measured = h3.gridDisk(me, 1);
    final cells = [
      for (final c in measured)
        () {
          final child = h3.cellToCenterChild(c, 9);
          final g = h3.cellToGeo(child);
          return cell(g.lat, g.lon, heard: 1, h3: child.toRadixString(16));
        }()
    ];
    final cov = PublicCoverage(cells: cells, asOf: 'x', grid: const CoverageGrid.h3(res: 9, cellDeg: 0.005));
    final r = driveNextTargets(coverage: cov, lat: lat, lon: lon, h3: h3, radiusM: 6000);
    final un = r.where((t) => t.kind == DriveTargetKind.unmapped).toList();
    expect(un, isNotEmpty);
    final measuredCentres = {for (final c in measured) h3.cellToGeo(c).lat};
    for (final t in un) {
      expect(measuredCentres.contains(t.lat), isFalse, reason: 'a measured cell is not unmapped');
      expect(t.distanceM, lessThanOrEqualTo(6000));
    }
    expect(ring.length, 19);
    // nearest first
    for (var i = 1; i < un.length; i++) {
      expect(un[i].distanceM, greaterThanOrEqualTo(un[i - 1].distanceM));
    }
  }, skip: h3 == null ? 'libh3 not found (brew install h3)' : false);
}
