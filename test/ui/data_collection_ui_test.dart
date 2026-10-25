// Stream 7 WP4 UI: the version-2 disclosure (every category, its own switch, Continue / Turn all off, shown once to
// people who only saw the packet-header sheet), the per-category switches in Settings > Privacy & data sharing (on asks
// first; off stops at once and offers to delete what is saved on this phone, since nothing of it left the phone), the
// honest unavailable states (no barometer, weather not available yet), and the context section of the drive report.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/data_categories.dart' as core;
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/phone_sensors.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';
import 'package:meshsonar/ui/settings/data_sharing.dart';
import 'package:meshsonar/ui/telemetry_sheet.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

final t0 = DateTime.utc(2026, 10, 16, 18);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_collect_ui_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Finder sheet() => find.byKey(const Key('telemetry-sheet'));
  Finder sheetScroll() => find.descendant(of: sheet(), matching: find.byType(Scrollable)).first;

  Future<Harness> openSheet(WidgetTester tester, {Settings? settings}) async {
    useTallScreen(tester);
    final h = Harness();
    if (settings != null) h.settings.saved = settings;
    await h.state.init();
    attachUiPrefs(h.state, UiPrefs(seen: true, telemetryDisclosed: false));
    await tester.pumpWidget(MeshSonarApp(state: h.state));
    await tester.pumpAndSettle();
    expect(sheet(), findsOneWidget);
    return h;
  }

  group('registry', () {
    test('every core category has exactly one Settings entry, in disclosure order, all opt-out', () {
      expect(dataCategories.map((c) => c.coreId), core.dataCategories.map((c) => c.id));
      expect(telemetryCategory.toggleKey, 'telemetry-toggle', reason: 'existing key kept');
      for (final c in dataCategories) {
        expect(c.isOn(const Settings()), isTrue, reason: '${c.id} is on by default');
        final off = c.set(const Settings(), false);
        expect(c.isOn(off), isFalse, reason: c.id);
        for (final other in dataCategories.where((x) => x != c)) {
          expect(other.isOn(off), isTrue, reason: 'turning ${c.id} off leaves ${other.id} alone');
        }
        expect(c.title, core.dataCategory(c.coreId)!.title);
        if (c != telemetryCategory) expect(c.summary, core.dataCategory(c.coreId)!.disclosure);
      }
    });

    test('drive-context categories say nothing has left the phone; only packet headers has a server erase', () {
      for (final c in driveContextCategories) {
        expect(c.eraseFromServer, isNull, reason: '${c.id}: no server endpoint exists');
        if (c.coreId != core.CategoryId.weather) {
          expect(c.localOnly, isTrue);
          expect(c.offEffect, contains('Nothing of it has left this phone'));
          expect(c.destination, contains('Not uploaded'));
        }
      }
      expect(telemetryCategory.eraseFromServer, isNotNull);
    });
  });

  testWidgets('disclosure v2 lists every category with its own switch; Continue keeps the choices', (tester) async {
    final h = await openSheet(tester);
    for (final c in dataCategories) {
      final sw = find.byKey(Key('disclosure-switch-${c.id}'));
      await tester.scrollUntilVisible(sw, 150, scrollable: sheetScroll());
      expect(find.descendant(of: sheet(), matching: find.text(c.title)), findsOneWidget, reason: c.id);
      expect(tester.widget<Switch>(sw).value, isTrue, reason: '${c.id} starts on');
    }
    expect(find.descendant(of: sheet(), matching: find.text(phoneTemperatureNote)), findsOneWidget);
    expect(find.descendant(of: sheet(), matching: find.text(core.savedWithDriveNote)), findsOneWidget);
    expect(find.byKey(const Key('telemetry-keep')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('telemetry-off')).hitTestable(), findsOneWidget);

    final baro = find.byKey(const Key('disclosure-switch-barometer'));
    await tester.scrollUntilVisible(baro, -150, scrollable: sheetScroll());
    await tester.tap(baro);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telemetry-keep')));
    await tester.pumpAndSettle();
    expect(sheet(), findsNothing);
    expect(h.state.settings.collectionOff, {'barometer'});
    expect(h.state.settings.telemetryEnabled, isTrue);
    expect(h.settings.saved.collectionOff, {'barometer'});
    expect(uiPrefsFor(h.state).telemetryDisclosed, isTrue);
    expect(h.state.collectionOn(core.CategoryId.motion), isTrue);
    expect(h.state.collectionOn(core.CategoryId.barometer), isFalse);
  });

  testWidgets('disclosure v2: Turn all off switches every category off', (tester) async {
    final h = await openSheet(tester);
    await tester.tap(find.byKey(const Key('telemetry-off')));
    await tester.pumpAndSettle();
    for (final c in dataCategories) {
      expect(c.isOn(h.state.settings), isFalse, reason: c.id);
    }
    expect(h.settings.saved.toJson()['collection_off'], hasLength(dataCategories.length - 1));
  });

  testWidgets('the sheet shows the current state: headers already off stay off unless switched on', (tester) async {
    final h = await openSheet(tester, settings: const Settings(telemetryEnabled: false));
    expect(tester.widget<Switch>(find.byKey(const Key('disclosure-switch-telemetry'))).value, isFalse);
    await tester.tap(find.byKey(const Key('telemetry-keep')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isFalse);
    expect(h.state.settings.collectionOff, isEmpty);
  });

  group('versioned disclosure flag', () {
    test('someone who saw only the v1 sheet sees v2 once; headers keep their consent', () async {
      final f = File('${tmp.path}/ui_prefs.json')..writeAsStringSync(jsonEncode({'onboarding_seen': true, 'telemetry_disclosed': true}));
      final p = FileUiPrefs(f);
      await p.load();
      expect(p.packetHeadersDisclosed, isTrue);
      expect(p.disclosedVersion, 1);
      expect(p.telemetryDisclosed, isFalse, reason: 'the app shell opens the v2 sheet');
      await p.markTelemetryDisclosed();
      final j = jsonDecode(f.readAsStringSync()) as Map;
      expect(j['collection_disclosed_v'], 2);
      expect(j['telemetry_disclosed'], isTrue);
      final again = FileUiPrefs(f);
      await again.load();
      expect(again.telemetryDisclosed, isTrue, reason: 'shown once');
    });

    test('a fresh install has seen nothing', () async {
      final p = FileUiPrefs(File('${tmp.path}/none.json'));
      await p.load();
      expect(p.telemetryDisclosed, isFalse);
      expect(p.packetHeadersDisclosed, isFalse);
    });
  });

  group('Settings switches', () {
    Future<DiskHarness> open(WidgetTester tester, {void Function(DiskHarness h)? setup}) async {
      useTallScreen(tester);
      final h = DiskHarness(tmp);
      h.approveKey();
      setup?.call(h);
      await h.pumpDiskApp(tester);
      await openSettingsTab(tester);
      return h;
    }

    void seedContext(Harness h) {
      final s = DriveSession(id: 'd1', startedAt: t0, endedAt: t0.add(const Duration(minutes: 5)));
      h.store.seed(s, [DrivePing(id: 'p1', ts: t0, lat: 40.1, lon: -82.9)]);
      h.store.ctx.appendPingContext('d1', 'p1', PingContext(altM: 250, altAccM: 5, pressureHpa: 990));
      h.store.ctx.appendSamples('d1', [DriveSample(ts: t0, src: SampleSource.phone, battPct: 60, pressureHpa: 990)]);
    }

    testWidgets('one switch per category, each with its exact sentence', (tester) async {
      await open(tester);
      for (final c in dataCategories) {
        await showSetting(tester, c.toggleKey);
        expect(find.descendant(of: find.byKey(Key(c.toggleKey)), matching: find.textContaining(c.summary)), findsOneWidget,
            reason: c.id);
      }
    });

    testWidgets('off: stops at once, says nothing left the phone, Delete strips it from the drives here', (tester) async {
      final h = await open(tester, setup: seedContext);
      await showSetting(tester, 'collect-motion-toggle');
      await tester.tap(find.byKey(const Key('collect-motion-toggle')));
      await tester.pumpAndSettle();
      expect(h.state.settings.collectionOff, {'motion'}, reason: 'off before any question');
      expect(find.byKey(const Key('motion-local-dialog')), findsOneWidget);
      expect(find.textContaining('Nothing of it has left this phone'), findsOneWidget);
      expect(find.byKey(const Key('telemetry-erase-dialog')), findsNothing);
      await tester.tap(find.byKey(const Key('motion-local-delete')));
      await settleIo(tester, until: () => h.store.ctx.ctxBySession['d1']?['p1']?.altM == null);
      final ctx = h.store.ctx.ctxBySession['d1']!['p1']!;
      expect(ctx.altM, isNull);
      expect(ctx.pressureHpa, 990, reason: 'other categories stay');
      expect(find.text('Deleted the motion and altitude data from 1 drive on this phone.'), findsOneWidget);
      expect(h.tele.deletes, 0, reason: 'no server call for a category that never left the phone');
    });

    testWidgets('off and Keep leaves what is saved on the phone', (tester) async {
      final h = await open(tester, setup: seedContext);
      await showSetting(tester, 'collect-phone_battery-toggle');
      await tester.tap(find.byKey(const Key('collect-phone_battery-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('phone_battery-local-keep')));
      await tester.pumpAndSettle();
      expect(h.store.ctx.samplesBySession['d1']!.single.battPct, 60);
      expect(h.state.settings.collectionOn('phone_battery'), isFalse);
      expect(find.textContaining('Off: nothing is collected.'), findsOneWidget);
    });

    testWidgets('on asks first with what is collected; cancel keeps it off', (tester) async {
      final h = await open(tester, setup: (h) => h.settings.saved = h.settings.saved.withCollection('device', false));
      await showSetting(tester, 'collect-device-toggle');
      await tester.tap(find.byKey(const Key('collect-device-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-on-dialog')), findsOneWidget);
      expect(find.textContaining('Never shared: Your phone\'s name'), findsOneWidget);
      await tester.tap(find.byKey(const Key('device-on-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(h.state.settings.collectionOn('device'), isFalse);
      await tester.tap(find.byKey(const Key('collect-device-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-on-dialog-confirm')));
      await tester.pumpAndSettle();
      expect(h.state.settings.collectionOn('device'), isTrue);
      expect(h.settings.saved.toJson().containsKey('collection_off'), isFalse);
    });

    testWidgets('honest states: no barometer support, weather not available yet', (tester) async {
      await open(tester);
      await showSetting(tester, 'collect-barometer-toggle');
      expect(find.textContaining('no barometer support'), findsOneWidget);
      await showSetting(tester, 'collect-weather-toggle');
      expect(find.textContaining('Not available yet on this server: it does not look up weather'), findsOneWidget);
    });

    testWidgets('a barometer that gave nothing on the last drive says so', (tester) async {
      final h = Harness()..barometer = FakeBarometer(fail: true);
      useTallScreen(tester);
      await h.state.init();
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await tester.pump();
      await h.state.stopDrive();
      expect(h.state.barometerStatus, SensorStatus.unavailable);
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openSettingsTab(tester);
      await showSetting(tester, 'collect-barometer-toggle');
      expect(find.textContaining('Motion & Fitness access is off'), findsOneWidget);
    });
  });

  group('drive report context section', () {
    Harness seeded({UnitsPreference units = UnitsPreference.metric}) {
      final h = Harness();
      h.settings.saved = h.settings.saved.copyWith(units: units);
      final pings = [
        for (var i = 0; i < 4; i++) DrivePing(id: 'p$i', ts: t0.add(Duration(minutes: i)), lat: 40.1, lon: -82.9),
      ];
      h.store.seed(DriveSession(id: 'd1', startedAt: t0, endedAt: t0.add(const Duration(minutes: 5))), pings);
      for (var i = 0; i < 4; i++) {
        h.store.ctx.appendPingContext('d1', 'p$i', PingContext(altM: 250.0 + i, altAccM: 4));
      }
      h.store.ctx.appendSamples('d1', [
        for (var i = 0; i < 4; i++) ...[
          DriveSample(ts: t0.add(Duration(minutes: i)), src: SampleSource.phone, pressureHpa: 990.0 + i, battPct: 70 - i),
          DriveSample(
            ts: t0.add(Duration(minutes: i)),
            src: SampleSource.radio,
            battMv: 4000 - i,
            uptimeS: 1000 + 60 * i,
            errFlags: i == 3 ? 2 : 0,
            txAirS: 10 + i,
            rxAirS: 20 + 2 * i,
            pkts: PacketCounters(recv: 100 + 10 * i, sent: 5 + i, floodTx: 5 + i, directTx: 0, floodRx: 90 + 10 * i, directRx: 10),
            storageUsedKb: 120,
            storageTotalKb: 1984,
            mcuTempC: 24.0 + 3 * i,
          ),
        ],
      ]);
      h.store.ctx.writeSessionContext('d1',
          SessionContext(device: DeviceDetails(os: 'ios', osVersion: '18.6', model: 'iPhone15,2'), companionExt: CompanionDetails(model: 'Heltec V4', maxTxDbm: 22)));
      return h;
    }

    Finder list() => find.descendant(of: find.byKey(const Key('report-list')), matching: find.byType(Scrollable)).first;

    Future<void> openReport(WidgetTester tester, Harness h, String id) async {
      useTallScreen(tester);
      await h.pumpApp(tester);
      openDriveReport(tester.element(find.byType(Scaffold).first), id);
      await tester.pumpAndSettle();
    }

    testWidgets('pressure, altitude, batteries and radio counters, through Units', (tester) async {
      final h = seeded(units: UnitsPreference.imperial);
      await openReport(tester, h, 'd1');
      await tester.scrollUntilVisible(find.byKey(const Key('chart-ctx-pressure')), 300, scrollable: list());
      expect(find.text('Air pressure (inHg), phone barometer'), findsOneWidget);
      expect(find.textContaining('cabin pressure'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-ctx-altitude')), 300, scrollable: list());
      expect(find.text('GPS altitude (ft)'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-ctx-radio-battery')), 300, scrollable: list());
      await tester.scrollUntilVisible(find.byKey(const Key('ctx-err-flags')), 300, scrollable: list());
      expect(tester.widget<Text>(find.byKey(const Key('ctx-err-flags'))).data, 'channel-activity check (CAD) timed out');
      expect(tester.widget<Text>(find.byKey(const Key('ctx-packets'))).data, '3 / 30');
      expect(tester.widget<Text>(find.byKey(const Key('ctx-storage'))).data, '120 of 1984 KB');
      expect(tester.widget<Text>(find.byKey(const Key('ctx-airtime'))).data, '5.0%');
      expect(tester.widget<Text>(find.byKey(const Key('ctx-device'))).data, 'iPhone15,2, ios 18.6');
      expect(find.textContaining('not how busy the channel was'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-ctx-radio-temp')), -300, scrollable: list());
      expect(find.text('Radio chip temperature (°F)'), findsOneWidget);
      expect(find.byKey(const Key('chart-ctx-temp-bands')), findsOneWidget);
      expect(find.text('Noise floor and SNR by radio temperature'), findsOneWidget);
    });

    testWidgets('a drive without context says so', (tester) async {
      final h = Harness();
      h.store.seed(DriveSession(id: 'old', startedAt: t0, endedAt: t0.add(const Duration(minutes: 1))),
          [DrivePing(id: 'x', ts: t0, lat: 40.1, lon: -82.9)]);
      await openReport(tester, h, 'old');
      await tester.scrollUntilVisible(find.byKey(const Key('report-context-none')), 300, scrollable: list());
      expect(find.byKey(const Key('report-context-none')), findsOneWidget);
    });
  });

  test('disclosure heading constants', () {
    expect(disclosureHeading, 'What MeshSonar collects');
    expect(disclosureLead, contains('No message text'));
  });
}
