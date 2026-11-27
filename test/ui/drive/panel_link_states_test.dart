// Build 76, bug report from iPhone users: "The floating panel when radio is not connected or in auto reconnect on iPhone".
// The Drive panel on a phone in every radio-link state (no radio, the automatic reconnect after launch waiting and trying,
// a manual connect, the reconnect that gave up, a mid-drive reconnect), in the WHOLE app (shell + tab bar + alerts strip), at
// real iPhone sizes, with and without a home indicator, at normal and large text:
//   * the panel is full width and its bottom edge is the top of the tab bar (nothing between them, no map showing under it);
//   * the state is said ONCE at the bottom of the screen (the Dock), with one action;
//   * the panel has the same size in every one of these states (nothing jumps when the state changes);
//   * the map's buttons stay above the panel.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/startup_location.dart' show LocationAccess;
import 'package:meshsonar/radio/radio_api.dart' show RadioDevice;
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/panel/panel_physics.dart';
import 'package:meshsonar/ui/drive_screen.dart';

import '../fakes.dart';

typedef _Phone = ({String name, Size size, double safeBottom});

const List<_Phone> _phones = [
  (name: 'iPhone SE 375x667', size: Size(375, 667), safeBottom: 0),
  (name: 'iPhone SE 375x667 +34', size: Size(375, 667), safeBottom: 34),
  (name: 'iPhone 393x852', size: Size(393, 852), safeBottom: 34),
  (name: 'iPhone 393x852 +0', size: Size(393, 852), safeBottom: 0),
  (name: 'iPhone 430x932', size: Size(430, 932), safeBottom: 34),
  (name: 'iPhone 430x932 +0', size: Size(430, 932), safeBottom: 0),
];

/// Normal, the largest non-accessibility size, and two accessibility sizes (the dock is two rows from 2.0).
const List<double> _scales = [1.0, 1.35, 2.0, 3.1];

enum _Link { none, launchWaiting, launchTrying, connecting, gaveUp }

void _view(WidgetTester tester, _Phone p, double scale) {
  tester.view.physicalSize = p.size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: 47, bottom: p.safeBottom);
  tester.view.viewPadding = FakeViewPadding(top: 47, bottom: p.safeBottom);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Rig {
  final Harness h;
  LaunchReconnect? lr;
  final Completer<void> waitGate = Completer<void>();
  _Rig(this.h);

  /// Before the app is pumped: the automatic reconnect exists from the first frame, as main.dart binds it before runApp.
  void prepare(_Link link) {
    const saved = SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck');
    lr = switch (link) {
      _Link.none || _Link.connecting => null,
      _Link.launchWaiting => LaunchReconnect(
          store: SavedRadiosStore(initial: const [saved]),
          connect: (RadioDevice d) async => false,
          isConnected: () => false,
          mode: () => AutoConnectMode.always,
          wait: (d) => waitGate.future,
        ),
      _Link.launchTrying => LaunchReconnect(
          store: SavedRadiosStore(initial: const [saved]),
          connect: (RadioDevice d) => h.state.connect(h.bt.devices.first, RadioKind.bluetooth),
          isConnected: () => h.state.connected,
          mode: () => AutoConnectMode.always,
          wait: (d) async {},
        ),
      _Link.gaveUp => LaunchReconnect(
          store: SavedRadiosStore(initial: const [saved]),
          connect: (RadioDevice d) async => false,
          isConnected: () => false,
          mode: () => AutoConnectMode.always,
          wait: (d) async {},
          maxAttempts: 2,
        ),
    };
    AlertsHost.runtime.value!.reconnect = lr;
  }

  /// Puts the app in [link]. Returns after the frames that show it.
  Future<void> enter(WidgetTester tester, _Link link) async {
    switch (link) {
      case _Link.none:
        break;
      case _Link.connecting:
        h.bt.connectGate = Completer<void>();
        unawaited(h.state.connect(h.bt.devices.first, RadioKind.bluetooth));
      case _Link.launchWaiting:
        unawaited(lr!.run());
      case _Link.launchTrying:
        h.bt.connectGate = Completer<void>();
        unawaited(lr!.run());
      case _Link.gaveUp:
        await lr!.run();
    }
    await _frames(tester);
    switch (link) {
      case _Link.none:
        expect(h.state.connected || h.state.connecting, isFalse);
      case _Link.connecting:
        expect(h.state.connecting, isTrue);
      case _Link.launchWaiting:
        expect(lr!.state, LaunchReconnectState.waiting);
      case _Link.launchTrying:
        expect(lr!.state, LaunchReconnectState.connecting);
        expect(h.state.connecting, isTrue);
      case _Link.gaveUp:
        expect(lr!.state, LaunchReconnectState.gaveUp);
    }
  }

  /// Ends whatever is running so no timer or future is left behind.
  Future<void> leave(WidgetTester tester) async {
    lr?.cancel();
    h.state.cancelConnect();
    if (!(h.bt.connectGate?.isCompleted ?? true)) h.bt.connectGate!.complete();
    if (!waitGate.isCompleted) waitGate.complete();
    await _frames(tester);
    await h.state.disconnect(quiet: true);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
  }
}

String _title(_Link l) => switch (l) {
      _Link.none || _Link.gaveUp => 'Not connected',
      _Link.connecting => 'Connecting…',
      _Link.launchWaiting || _Link.launchTrying => 'Reconnecting…',
    };

Rect _panel(WidgetTester tester) => tester.getRect(find.byKey(const Key('drive-panel')));

/// Texts in the lower half of the screen that say where the radio link stands.
Iterable<String> _linkWordsAtBottom(WidgetTester tester, Size size) sync* {
  const words = ['Not connected', 'Connecting', 'Reconnecting', 'Could not reach', 'No radio'];
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget as Text;
    final s = w.data ?? w.textSpan?.toPlainText() ?? '';
    if (!words.any(s.contains)) continue;
    final box = e.renderObject as RenderBox;
    if (!box.attached || !box.hasSize) continue;
    if (box.localToGlobal(Offset.zero).dy < size.height / 2) continue;
    yield s;
  }
}

/// The geometry every state must have on a phone.
void _expectDocked(WidgetTester tester, _Phone p, double scale, _Link link, {bool strip = false}) {
  final why = '${p.name} x$scale ${link.name}';
  expect(tester.takeException(), isNull, reason: why);
  final panel = _panel(tester);
  final tabs = tester.getRect(find.byKey(const Key('shell-tabs')));
  expect(tabs.bottom, closeTo(p.size.height, 0.5), reason: '$why: the tab bar is at the bottom of the screen');
  expect(panel.left, 0, reason: '$why: full width');
  expect(panel.right, p.size.width, reason: '$why: full width');
  expect(panel.bottom, closeTo(tabs.top, 0.5), reason: '$why: the panel sits on the tab bar, no gap and no overlap');
  final row = scale >= 2.0 ? kPanelDockRowAx : kPanelDockRowHeight;
  expect(panel.height, closeTo(kPanelHeaderHeight + row + (strip ? kPanelStripHeight : 0), 0.5), reason: '$why: the Dock, nothing more');
  expect(panel.height, lessThan(p.size.height * 0.3), reason: '$why: the map stays the screen');
  // One message, in the Dock; the strip above the tab bar is not shown on the Drive tab.
  expect(find.byKey(const Key('reconnect-strip')), findsNothing, reason: why);
  expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, _title(link), reason: why);
  expect(_linkWordsAtBottom(tester, p.size).toList(), hasLength(link == _Link.gaveUp ? 2 : 1), reason: '$why: said once');
  // One action.
  final working = link == _Link.connecting || link == _Link.launchWaiting || link == _Link.launchTrying;
  expect(find.byKey(const Key('connect-cancel')), working ? findsOneWidget : findsNothing, reason: why);
  expect(find.byKey(const Key('start-stop')), working ? findsNothing : findsOneWidget, reason: why);
  if (!working) expect(find.descendant(of: find.byKey(const Key('start-stop')), matching: find.text('Connect radio')), findsOneWidget, reason: why);
  // Everything in the dock row is inside the panel (nothing clipped out of it, nothing under the tab bar).
  for (final k in [const Key('status-line'), if (working) const Key('connect-cancel') else const Key('start-stop')]) {
    final r = tester.getRect(find.byKey(k));
    expect(r.top, greaterThanOrEqualTo(panel.top - 0.5), reason: '$why: $k inside the panel');
    expect(r.bottom, lessThanOrEqualTo(panel.bottom + 0.5), reason: '$why: $k inside the panel');
    expect(r.left, greaterThanOrEqualTo(0), reason: why);
    expect(r.right, lessThanOrEqualTo(p.size.width), reason: why);
  }
  // The map's buttons are above the panel.
  final controls = find.byKey(const Key('map-control-column'));
  if (controls.evaluate().isNotEmpty) {
    expect(tester.getRect(controls).bottom, lessThanOrEqualTo(panel.top + 0.5), reason: '$why: map buttons clear the panel');
  }
}

/// The whole app on [p] at text [scale], brought to [link].
Future<_Rig> _start(WidgetTester tester, _Phone p, double scale, _Link link, {Harness? harness, Future<void> Function(Harness h)? afterPump}) async {
  _view(tester, p, scale);
  final rig = _Rig(harness ?? Harness())..prepare(link);
  await rig.h.pumpApp(tester);
  await afterPump?.call(rig.h);
  await _frames(tester);
  expect(find.byType(DriveScreen), findsOneWidget);
  await rig.enter(tester, link);
  return rig;
}

Future<void> _stop(WidgetTester tester, _Rig rig) async {
  await rig.leave(tester);
  AlertsHost.runtime.value?.reconnect = null;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  tearDown(() => AlertsHost.runtime.value?.reconnect = null);

  for (final p in _phones) {
    for (final scale in _scales) {
      testWidgets('${p.name}, text x$scale: the panel sits on the tab bar and says the state once, in every link state', (tester) async {
        for (final link in _Link.values) {
          final rig = await _start(tester, p, scale, link);
          _expectDocked(tester, p, scale, link);
          await _stop(tester, rig);
        }
      });
    }
  }

  testWidgets('the panel has the same place and size through connecting, reconnecting, gave up and not connected', (tester) async {
    for (final p in _phones) {
      final rects = <_Link, Rect>{};
      for (final link in _Link.values) {
        final rig = await _start(tester, p, 1.0, link);
        rects[link] = _panel(tester);
        await rig.leave(tester);
        expect(_panel(tester), rects[link], reason: '${p.name} ${link.name}: leaving the state moves nothing');
        await _stop(tester, rig);
      }
      expect(rects.values.toSet(), hasLength(1), reason: '${p.name}: $rects');
    }
  });

  testWidgets('location off: the strip does not come and go with every reconnect try (the panel never jumps)', (tester) async {
    const p = (name: 'iPhone 393x852', size: Size(393, 852), safeBottom: 34.0);
    final rects = <_Link, Rect>{};
    for (final link in _Link.values) {
      final h = Harness()..locationAccess = FakeLocationAccess(LocationAccess.denied, LocationAccess.denied);
      final rig = await _start(tester, p, 1.0, link, harness: h, afterPump: (h) => h.state.refreshLocationAccess());
      expect(h.state.locationNote, isNotNull);
      _expectDocked(tester, p, 1.0, link, strip: true);
      rects[link] = _panel(tester);
      await _stop(tester, rig);
    }
    expect(rects.values.toSet(), hasLength(1), reason: '$rects');
  });

  testWidgets('the waiting-message warning on the Drive tab sits between the panel and the tab bar: the panel rests on it', (tester) async {
    for (final p in _phones) {
      _view(tester, p, 1.0);
      final h = Harness();
      await h.pumpApp(tester);
      await _frames(tester);
      final before = _panel(tester);
      AlertsHost.runtime.value!.queue.onDrained(16);
      await _frames(tester);
      expect(tester.takeException(), isNull);
      final strip = tester.getRect(find.byKey(const Key('queue-strip')));
      final tabs = tester.getRect(find.byKey(const Key('shell-tabs')));
      final panel = _panel(tester);
      expect(strip.bottom, closeTo(tabs.top, 0.5), reason: '${p.name}: the warning is directly above the tab bar');
      expect(panel.bottom, closeTo(strip.top, 0.5), reason: '${p.name}: the panel rests on the warning, no map between them');
      expect(panel.height, before.height, reason: p.name);
      expect(panel.width, p.size.width);
      AlertsHost.runtime.value!.queue.dismiss();
      await _frames(tester);
      expect(_panel(tester), before, reason: '${p.name}: back on the tab bar');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }
  });

  testWidgets('other tabs keep the reconnect strip (with its Reconnect button) above the tab bar', (tester) async {
    const p = (name: 'iPhone 393x852', size: Size(393, 852), safeBottom: 34.0);
    final rig = await _start(tester, p, 1.0, _Link.gaveUp);
    expect(find.byKey(const Key('reconnect-strip')), findsNothing);
    await tapShellTab(tester, 'More');
    await _frames(tester);
    expect(find.byKey(const Key('reconnect-strip')), findsOneWidget);
    expect(find.byKey(const Key('reconnect-now')), findsOneWidget);
    final strip = tester.getRect(find.byKey(const Key('reconnect-strip')));
    expect(strip.bottom, closeTo(tester.getRect(find.byKey(const Key('shell-tabs'))).top, 0.5));
    await rig.leave(tester);
  });

  testWidgets('gave up: the Dock says why in one short line and offers Connect radio', (tester) async {
    const p = (name: 'iPhone SE 375x667', size: Size(375, 667), safeBottom: 0.0);
    final rig = await _start(tester, p, 1.0, _Link.gaveUp);
    expect(tester.widget<Text>(find.byKey(const Key('dock-subtitle'))).data, 'Could not reach MeshCore-Truck');
    await rig.leave(tester);
  });

  testWidgets('working states name the radio under the words, never a GPS hint', (tester) async {
    const p = (name: 'iPhone SE 375x667', size: Size(375, 667), safeBottom: 0.0);
    for (final link in [_Link.connecting, _Link.launchWaiting, _Link.launchTrying]) {
      final rig = await _start(tester, p, 1.0, link);
      expect(tester.widget<Text>(find.byKey(const Key('dock-subtitle'))).data, 'MeshCore-Truck', reason: link.name);
      expect(find.textContaining('GPS'), findsNothing, reason: link.name);
      await _stop(tester, rig);
    }
  });

  testWidgets('mid-drive reconnect: the driving Dock stays, the strip says it once, the panel still sits on the tab bar zone', (tester) async {
    for (final p in _phones) {
      tester.view.physicalSize = p.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness();
      final s = _ReconnectingState(h.services)..retryPendingAtLaunch = false;
      await s.init();
      await s.connect(h.bt.devices.first, RadioKind.bluetooth);
      await s.startDrive();
      final navBar = 72 + p.safeBottom;
      await tester.pumpWidget(AppScope(
        state: s,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(size: p.size, padding: EdgeInsets.only(top: 47, bottom: navBar), viewPadding: EdgeInsets.only(top: 47, bottom: p.safeBottom)),
            child: const DriveScreen(),
          ),
        ),
      ));
      await _frames(tester);
      final before = _panel(tester);
      expect(before.bottom, closeTo(p.size.height - navBar, 0.5), reason: p.name);
      final stop = tester.getRect(find.byKey(const Key('start-stop')));
      s.force(true);
      await _frames(tester);
      expect(tester.takeException(), isNull);
      final panel = _panel(tester);
      expect(panel.bottom, before.bottom, reason: '${p.name}: the bottom edge does not move');
      expect(panel.left, 0);
      expect(panel.right, p.size.width);
      expect(panel.height, before.height + kPanelStripHeight, reason: '${p.name}: only the reserved strip is added');
      expect(tester.getRect(find.byKey(const Key('start-stop'))), stop, reason: '${p.name}: Stop does not move');
      expect(tester.widget<Text>(find.byKey(const Key('dock-strip-text'))).data, 'Radio lost - reconnecting');
      expect(_linkWordsAtBottom(tester, p.size).toList(), isEmpty, reason: '${p.name}: the strip is the one message');
      s.force(false);
      await _frames(tester);
      expect(_panel(tester), before, reason: p.name);
      await s.stopDrive();
      await tester.pump(const Duration(milliseconds: 300));
      await s.disconnect(quiet: true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    }
  });
}

/// AppState whose mid-drive reconnect flag the test sets (the real one needs a dropped link and its retry loop).
class _ReconnectingState extends AppState {
  _ReconnectingState(super.services);
  bool _forced = false;
  @override
  bool get reconnecting => _forced || super.reconnecting;
  void force(bool v) {
    _forced = v;
    notifyListeners();
  }
}
