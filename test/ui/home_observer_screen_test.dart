// Home observer screen (phone observer O3): place the observer on the map, choose exact / ~1 km for the public map, turn
// it on (PUT) and off (DELETE), status from GET /observer/me. Also the observer location choice in Settings > Privacy.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/home_observer.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/home_observer_screen.dart';
import 'package:meshsonar/ui/settings/privacy_section.dart' show TelemetryLocationTile;

import 'fakes.dart';

class _HomeClient extends FakeCmatClient implements HomeObserverTransport {
  _HomeClient(super.baseUrl);
  final calls = <String>[];
  @override
  Future<HomeObserverHttpResult> putHome(String driverKey, Map<String, dynamic> body) async {
    calls.add('PUT ${jsonEncode(body)}');
    return const HomeObserverHttpResult(200);
  }

  @override
  Future<HomeObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body) async {
    calls.add('HB');
    return const HomeObserverHttpResult(200);
  }

  @override
  Future<HomeObserverHttpResult> deleteHome(String driverKey, String observerId) async {
    calls.add('DELETE');
    return const HomeObserverHttpResult(200);
  }

  @override
  Future<HomeObserverHttpResult> me(String driverKey) async {
    calls.add('ME');
    return const HomeObserverHttpResult(200, body: {
      'observers': [
        {'kind': 'fixed', 'packets_24h': 812, 'last_packet_at': '2026-10-16T17:58:00Z'}
      ]
    });
  }
}

class _H extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => _HomeClient(u);
  _HomeClient get hc => client as _HomeClient;
}

Future<_H> _pump(WidgetTester tester, Widget child, {bool key = true}) async {
  // Tall enough that the whole screen is built (dragging the list in the middle would pan the map instead).
  tester.view.physicalSize = const Size(1200, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final h = _H();
  if (key) h.approveKey();
  await h.state.init();
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: child)),
  ));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _show(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('place on the map, choose exact, turn on (PUT), see the status, turn off (DELETE)', (tester) async {
    final h = await _pump(tester, const HomeObserverScreen(showTiles: false));
    expect(find.text(homeObserverLead), findsOneWidget);
    expect(find.byKey(const Key('mini-map-credit')), findsOneWidget);
    expect(find.text('Packets heard in the last 24 h: 812'), findsOneWidget, reason: 'status from GET /observer/me');
    // Nothing placed yet: the button waits.
    await _show(tester, 'home-observer-on');
    expect(tester.widget<FilledButton>(find.byKey(const Key('home-observer-on'))).onPressed, isNull);
    await tester.ensureVisible(find.byKey(const Key('home-observer-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-observer-map')));
    await tester.pump(const Duration(milliseconds: 400)); // the map waits out a double tap
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-observer-pin')), findsOneWidget);
    await tester.ensureVisible(find.text(HomeLocationPublic.exact.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(HomeLocationPublic.exact.label));
    await tester.pumpAndSettle();
    await _show(tester, 'home-observer-on');
    await tester.tap(find.byKey(const Key('home-observer-on')));
    await tester.pumpAndSettle();
    final put = h.hc.calls.firstWhere((c) => c.startsWith('PUT '));
    final body = jsonDecode(put.substring(4)) as Map;
    expect(body['location_public'], 'exact');
    expect(body['id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(h.state.homeObserverActive, isTrue);
    expect(h.state.settings.homeObserver!.locationPublic, HomeLocationPublic.exact);
    await _show(tester, 'home-observer-result');
    expect(find.byKey(const Key('home-observer-result')), findsOneWidget);
    await _show(tester, 'home-observer-off');
    await tester.tap(find.byKey(const Key('home-observer-off')));
    await tester.pumpAndSettle();
    expect(h.hc.calls.last, 'DELETE');
    expect(h.state.homeObserverActive, isFalse);
    expect(h.state.settings.homeObserver, isNotNull, reason: 'the position stays saved for next time');
  });

  testWidgets('without a driver key the screen says so and cannot turn on', (tester) async {
    final h = await _pump(tester, const HomeObserverScreen(showTiles: false), key: false);
    expect(h.state.keyApproved, isFalse);
    await tester.tap(find.byKey(const Key('home-observer-map')));
    await tester.pump(const Duration(milliseconds: 400)); // the map waits out a double tap
    await tester.pumpAndSettle();
    await _show(tester, 'home-observer-needs-key');
    expect(find.byKey(const Key('home-observer-needs-key')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('home-observer-on'))).onPressed, isNull);
  });

  testWidgets('observer location: Approximate is the default; Region only is saved', (tester) async {
    final h = await _pump(tester, const TelemetryLocationTile());
    final sel = tester.widget<SegmentedButton<bool>>(find.byKey(const Key('telemetry-location-selector')));
    expect(sel.selected, {false});
    await tester.tap(find.text('Region only'));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryRegionOnly, isTrue);
    expect(find.text('Only your region code (for example CMH) goes with the packets.'), findsOneWidget);
    await h.state.updateSettings(h.state.settings.copyWith(telemetryEnabled: false));
    await tester.pumpAndSettle();
    expect(find.text('Sharing is off, so nothing is sent.'), findsOneWidget);
    expect(const Settings().telemetryRegionOnly, isFalse);
  });
}
