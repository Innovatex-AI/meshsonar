// The two taps that used to do nothing: a ping dot (lines to the repeaters that heard it, with their SNR, and its details)
// and one of the drive's own repeater markers (lines to every cell it was heard in, and its figures).
import 'dart:io';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/repeater_reach.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';

import '../fakes.dart';

H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

String k(String c) => c * 64;
const _site = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'cellLinks', 'reachDriverKey'});

class _C extends FakeCmatClient {
  _C(super.u);
  final reachCalls = <String>[];
  @override
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon, bool h3 = false}) async {
    reachCalls.add(repeaterKey);
    return RepeaterReach(
      key: repeaterKey,
      cellDeg: 0.0025,
      cells: const [
        ReachCell(lat: 40.0, lon: -83.0, pings: 5, bestSnr: 2.5),
        ReachCell(lat: 40.03, lon: -83.0, pings: 2, bestSnr: -6),
      ],
      totals: const ReachTotals(heardPings: 7, drives: 1, drivers: 1),
      snrByDistance: const [],
    );
  }
}

class _H extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => _C(u)..siteConfigResult = _site;
  _C get c => client as _C;
}

void main() {
  final heard = DrivePing(id: 'p1', ts: DateTime.utc(2026, 10, 31, 14, 5), lat: 40.0, lon: -83.0, echoes: const [Echo(repeater: 'aaaa', snrDb: 4.5)]);
  final silent = DrivePing(id: 'p2', ts: DateTime.utc(2026, 10, 31, 14, 6), lat: 40.0005, lon: -83.0005);
  final rep = RepeaterRef(key: k('a'), name: 'Alpha Tower', lat: 40.01, lon: -83.0);

  Future<_H> pump(WidgetTester tester, {List<DrivePing>? pings}) async {
    useTallScreen(tester);
    CoverageMap.hexEngine = _load();
    addTearDown(() => CoverageMap.hexEngine = null);
    final h = _H()..approveKey();
    await h.pumpApp(tester);
    await tester.runAsync(() => h.state.refreshUploadSiteConfig(force: true));
    await tester.pumpWidget(
      AppScope(
        state: h.state,
        child: MaterialApp(
          home: Scaffold(
            body: CoverageMap(pings: pings ?? [heard], repeaters: [rep], position: const LatLng(40.0, -83.0)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return h;
  }

  testWidgets('tap a ping dot: lines to the repeaters that heard it, its SNR, and the ping details', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('map-ping-tap-p1')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('info-panel-header')), findsOneWidget);
    expect(find.text('Heard 1 repeater  ·  best +4.5 dB'), findsOneWidget);
    expect(find.byKey(const Key('link-lines')), findsOneWidget);
    expect(find.text('+4.5 dB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pumpAndSettle();
    expect(find.text('Position'), findsOneWidget);
  });

  testWidgets('tap a ping that heard nothing: says mapped, no signal, and draws no lines', (tester) async {
    await pump(tester, pings: [silent]);
    await tester.tap(find.byKey(const ValueKey('map-ping-tap-p2')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Heard nothing  ·  mapped, no signal'), findsOneWidget);
    expect(find.byKey(const Key('link-lines')), findsNothing);
  });

  testWidgets('tap one of the drive\'s repeater markers: its panel and lines to every cell it was heard in', (tester) async {
    final h = await pump(tester);
    await tester.tap(find.byKey(ValueKey('map-repeater-${k('a')}')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.c.reachCalls, [k('a')]);
    expect(find.text('Alpha Tower'), findsWidgets);
    expect(find.text('Heard in 2 cells  ·  tap to expand'), findsOneWidget);
    expect(find.byKey(const Key('link-lines')), findsOneWidget);
    expect(find.text('+2.5 dB'), findsOneWidget);
  });
}
