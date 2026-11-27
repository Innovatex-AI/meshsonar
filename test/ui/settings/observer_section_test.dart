// Settings > Observer (release 0.38 A6, observer-everywhere-mqtt-plan-2026-11-15.md section 3.3): the master switch, the
// status, the MQTT feeds (10 slots, preset picker with search and caution badges, Custom with Keychain password, per-slot
// status / packets / last error, Test, delete), the loading / empty / error / offline states, the vocabulary, and
// Dynamic Type at AX3.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/mqtt_presets.dart';
import 'package:meshsonar/core/observer_engine.dart';
import 'package:meshsonar/ui/radios/observer_join_screen.dart';
import 'package:meshsonar/ui/settings/data_sharing.dart';
import 'package:meshsonar/ui/settings/observer_section.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';

import '../fakes.dart';
import '../settings_test_kit.dart';
import '../toast_test_kit.dart';

String _bundled() => File(ObserverPresets.asset).readAsStringSync();

class _Rig {
  final Harness h = Harness();
  final FakeObserverEngine engine = FakeObserverEngine();
  _Rig({Settings? settings}) {
    h.settings.saved = settings ??
        const Settings(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved, display: 'KD8XYZ');
    h.observerEngineFactory = () => engine;
    ObserverPresets.debugStore = MqttPresetStore(
      loadBundled: () async => _bundled(),
      fetcher: () => h.client.mqttPresets,
    );
  }
}

Finder get _sheetScroll =>
    find.descendant(of: find.byKey(const Key('mqtt-slot-sheet')), matching: find.byType(Scrollable)).first;
Finder get _pickerScroll =>
    find.descendant(of: find.byKey(const Key('mqtt-preset-picker')), matching: find.byType(Scrollable)).first;

Future<_Rig> _open(WidgetTester tester, {Settings? settings, void Function(_Rig r)? before}) async {
  useTallScreen(tester);
  final r = _Rig(settings: settings);
  before?.call(r);
  await r.h.pumpApp(tester);
  await openSettingsTab(tester);
  await showSetting(tester, 'mqtt-add-feed');
  return r;
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('mqtt-add-feed')));
  await settleIo(tester);
  expect(find.byKey(const Key('mqtt-preset-picker')), findsOneWidget);
}

Future<void> _inSheet(WidgetTester tester, String key, {Finder? scroll}) async {
  await tester.scrollUntilVisible(find.byKey(Key(key)), 150, scrollable: scroll ?? _sheetScroll);
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

const _slotA = MqttSlotSettings(id: 'slot-1', presetId: 'corecomms', name: 'CoreComms', host: 'mqtt.corecomms.net', wsPath: '/mqtt');

void main() {
  tearDown(() => ObserverPresets.debugStore = null);

  group('the section', () {
    testWidgetsT('empty: master switch, status, "MQTT feeds (0 of 10)", the plain wording and Add a feed', (tester) async {
      await _open(tester);
      // Build 76: the Observer rows are the page "Observer and MQTT feeds" of Sharing & privacy. The master switch is ONE
      // switch, on the first level (checked at the end of this test), not a second copy on this page.
      expect(find.byKey(const Key('settings-page-observer')), findsOneWidget);
      expect(find.byKey(const Key('observer-share-toggle')), findsNothing, reason: 'no second copy of the master switch');
      expect(find.byKey(const Key('observer-status')), findsOneWidget);
      expect(find.text('MQTT feeds (0 of 10)'), findsOneWidget);
      expect(find.byKey(const Key('mqtt-feeds-empty')), findsOneWidget);
      expect(find.text(mqttFeedsHelp), findsOneWidget);
      // Build 76 cut the help to one short line; the long version (with the public key) is on "What MeshSonar shares".
      for (final w in ['public packets', 'Never your position', 'private messages', 'each starts off']) {
        expect(mqttFeedsHelp, contains(w));
      }
      final flow = otherDataFlows.firstWhere((f) => f.title == 'MQTT feeds to other sites').body;
      for (final w in ['public packets', 'public key', 'Never your position', 'off until you turn it on']) {
        expect(flow, contains(w), reason: 'the full disclosure keeps "$w"');
      }
      final add = tester.widget<ListTile>(find.byKey(const Key('mqtt-add-feed')));
      expect(add.enabled, isTrue);
      final header = tester.getSemantics(find.byKey(const Key('mqtt-feeds-title')));
      expect(header.flagsCollection.isHeader, isTrue, reason: 'VoiceOver: the feeds list has a header');
      // The master switch: first row of Sharing & privacy, with the key of both pre-76 switches.
      await showSetting(tester, 'observer-share-toggle');
      expect(find.byKey(const Key('settings-page-observer')), findsNothing, reason: 'back on the first level');
      expect(find.byKey(const Key('observer-share-toggle')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('observer-share-toggle')), matching: find.byKey(const Key('telemetry-toggle'))),
          findsOneWidget, reason: 'one switch, both keys');
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('telemetry-toggle'))).value, isTrue);
      expect(tester.getTopLeft(find.byKey(const Key('telemetry-toggle'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('page-observer'))).dy),
          reason: 'the switch comes before the row that opens the Observer page');
    });

    testWidgetsT('the master switch is Share with MeshSonar: off asks for the erase like Privacy, the feeds say why', (tester) async {
      final r = await _open(tester);
      await showSetting(tester, 'observer-share-toggle');
      await tester.tap(find.byKey(const Key('observer-share-toggle')));
      await tester.pumpAndSettle();
      expect(r.h.state.settings.telemetryEnabled, isFalse, reason: 'off takes effect before any question');
      expect(find.byKey(const Key('telemetry-erase-dialog')), findsOneWidget, reason: 'same flow as Privacy');
      await tester.tap(find.byKey(const Key('telemetry-erase-keep')));
      await settleIo(tester);
      expect(find.textContaining('this phone shares nothing, with MeshSonar or any MQTT feed'), findsOneWidget);
      expect(observerStatusLine(r.h.state), startsWith('Off. Turn on "Share with MeshSonar" in Settings > $privacySectionTitle'));
      expect(r.engine.last!.sharing, isFalse, reason: 'the engine is told at once');
      expect(tester.widget<Text>(find.byKey(const Key('page-observer-caption'))).data, 'Off: sharing is off.',
          reason: 'the row that opens the Observer page says it too');
      // On the Observer page the status row says where the switch is now.
      await showSetting(tester, 'observer-status');
      expect(find.textContaining('Turn on "Share with MeshSonar" in Settings > $privacySectionTitle'), findsOneWidget);
    });

    testWidgetsT('10 feeds: Add a feed is disabled and says why', (tester) async {
      final ten = [for (var i = 1; i <= 10; i++) MqttSlotSettings(id: 'slot-$i', name: 'Feed $i', host: 'h$i.example')];
      await _open(tester, settings: Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: ten));
      expect(find.text('MQTT feeds (10 of 10)'), findsOneWidget);
      final add = tester.widget<ListTile>(find.byKey(const Key('mqtt-add-feed')));
      expect(add.enabled, isFalse);
      expect(find.text('All 10 feeds are in use. Delete one to add another.'), findsOneWidget);
      expect(nextSlotId(ten), isNull);
      expect(nextSlotId(ten.sublist(1)), 'slot-1', reason: 'the first free id is reused');
    });
  });

  group('preset picker', () {
    testWidgetsT('search, sections, no caution text; a preset is added OFF', (tester) async {
      final r = await _open(tester);
      await _openPicker(tester);
      expect(find.text('Popular'), findsOneWidget);
      expect(find.byKey(const Key('mqtt-preset-custom')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('mqtt-preset-search')), 'letsmesh');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mqtt-preset-letsmesh-us')), findsOneWidget);
      expect(find.byKey(const Key('mqtt-preset-letsmesh-eu')), findsOneWidget);
      expect(find.byKey(const Key('mqtt-preset-meshmapper')), findsNothing);
      expect(find.byKey(const Key('mqtt-preset-letsmesh-us-caution')), findsNothing);
      expect(find.textContaining('Ask the operator'), findsNothing);
      await tester.tap(find.byKey(const Key('mqtt-preset-letsmesh-us')));
      await settleIo(tester);
      final slots = r.h.state.settings.mqttSlots;
      expect(slots.single.presetId, 'letsmesh-us');
      expect(slots.single.id, 'slot-1');
      expect(slots.single.enabled, isFalse, reason: 'every preset starts off');
      expect(find.textContaining('Added LetsMesh US. It stays off until you turn it on.'), findsOneWidget);
      expect(r.engine.last!.slots.single.id, 'slot-1', reason: 'the engine gets the new slot');
      // Already added: shown with a check and not offered twice.
      await showSetting(tester, 'mqtt-add-feed');
      await _openPicker(tester);
      await tester.enterText(find.byKey(const Key('mqtt-preset-search')), 'letsmesh us');
      await tester.pumpAndSettle();
      expect(find.text('Already in your feeds'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const Key('mqtt-preset-letsmesh-us'))).enabled, isFalse);
    });

    testWidgetsT('no match: the empty state offers a custom feed', (tester) async {
      await _open(tester);
      await _openPicker(tester);
      await tester.enterText(find.byKey(const Key('mqtt-preset-search')), 'nosuchbroker');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mqtt-presets-empty')), findsOneWidget);
      await tester.tap(find.text('Add a custom feed'));
      await settleIo(tester);
      expect(find.byKey(const Key('mqtt-slot-sheet')), findsOneWidget);
      expect(find.text('Custom feed'), findsWidgets);
    });

    testWidgetsT('offline: the built-in list, and the picker says so', (tester) async {
      final r = await _open(tester);
      // FakeCmatClient: a network error has no HTTP status.
      r.h.client.mqttPresetsError = const CmatException('network error: offline');
      await _openPicker(tester);
      expect(find.textContaining('Offline: showing the list built into the app'), findsOneWidget);
      expect(find.byKey(const Key('mqtt-preset-corecomms')), findsOneWidget);
    });

    testWidgetsT('online: the server list is used and the picker says it is up to date', (tester) async {
      final r = await _open(tester);
      final c = r.h.client;
      c
        ..mqttPresetsEtag = '"s1"'
        ..mqttPresetsResult = const MqttPresetList(presets: [
          MqttPreset(id: 'corecomms', name: 'CoreComms (server)', host: 'mqtt.corecomms.net', wsPath: '/mqtt'),
        ]);
      await _openPicker(tester);
      expect(find.textContaining('Up to date with the server'), findsOneWidget);
      expect(find.text('CoreComms (server)'), findsOneWidget);
      expect(find.byKey(const Key('mqtt-preset-letsmesh-us')), findsNothing);
      expect(c.mqttPresetAsks, [null]);
    });

    testWidgetsT('a broken list: the error state with Try again, Custom still works', (tester) async {
      await _open(tester);
      ObserverPresets.debugStore = MqttPresetStore(loadBundled: () async => '{"presets": 3}', fetcher: () => throw StateError('x'));
      await _openPicker(tester);
      expect(find.byKey(const Key('mqtt-presets-error')), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const Key('mqtt-preset-custom'))).onTap, isNotNull);
    });
  });

  group('a feed', () {
    testWidgetsT('turning on a feed is one tap: no confirm, no caution badge', (tester) async {
      const slot = MqttSlotSettings(id: 'slot-1', presetId: 'meshmapper', name: 'MeshMapper', host: 'mqtt.meshmapper.net');
      final r = await _open(tester,
          settings: const Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [slot]));
      await settleIo(tester);
      await showSetting(tester, 'mqtt-slot-slot-1');
      expect(find.textContaining('Ask the operator'), findsNothing);
      await tester.tap(find.byKey(const Key('mqtt-slot-slot-1-switch')));
      await settleIo(tester);
      expect(find.byKey(const Key('mqtt-caution-slot-1')), findsNothing, reason: 'no confirm dialog');
      expect(r.h.state.settings.mqttSlots.single.enabled, isTrue);
      expect(r.engine.last!.slots.single.enabled, isTrue);
    });

    testWidgetsT('status from the engine: icon and words, packets sent in 24 h, last error', (tester) async {
      final r = await _open(tester,
          settings: Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [_slotA.copyWith(enabled: true)]));
      r.engine.emitStatus(const [ObserverFeedStatus(slotId: 'slot-1', state: ObserverFeedState.connected, sent24h: 42)]);
      await tester.pumpAndSettle();
      expect(find.text('Connected\n42 packets sent in 24 h'), findsOneWidget);
      r.engine.emitStatus(const [
        ObserverFeedStatus(slotId: 'slot-1', state: ObserverFeedState.authFailed, sent24h: 42, lastError: 'The site refused the login.'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Auth failed\n42 packets sent in 24 h\nLast error: The site refused the login.'), findsOneWidget);
      for (final st in ObserverFeedState.values) {
        expect(feedStateSymbol(st), isNotNull, reason: 'every state has an icon as well as its words');
      }
    });

    testWidgetsT('without an engine status: Off, or what it waits for', (tester) async {
      final r = await _open(tester,
          settings: Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [
            _slotA,
            _slotA.copyWith(enabled: true).copyWithId('slot-2'),
          ]));
      expect(find.byKey(const Key('mqtt-slot-slot-1-status')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('mqtt-slot-slot-1-status'))).data, 'Off');
      expect(tester.widget<Text>(find.byKey(const Key('mqtt-slot-slot-2-status'))).data, 'Waiting for radio',
          reason: 'an observer without a radio: the feed waits for it');
      r.h.state.updateSettings(r.h.state.settings.copyWith(telemetryEnabled: false));
      await settleIo(tester);
      expect(tester.widget<Text>(find.byKey(const Key('mqtt-slot-slot-2-status'))).data, 'Off\nShare with MeshSonar is off.',
          reason: 'it says why, without calling it an error');
    });

    testWidgetsT('Custom: host, port, path, TLS, airport code, username; password only in the Keychain', (tester) async {
      final r = await _open(tester);
      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('mqtt-preset-custom')));
      await settleIo(tester);
      // Validation: nothing saved without a host.
      await tester.tap(find.byKey(const Key('mqtt-slot-save')));
      await tester.pumpAndSettle();
      expect(find.text('Enter the broker\'s host name'), findsOneWidget);
      expect(r.h.state.settings.mqttSlots, isEmpty);

      await tester.enterText(find.byKey(const Key('mqtt-field-name')), 'My broker');
      await tester.enterText(find.byKey(const Key('mqtt-field-host')), 'mqtt.mine.example');
      await tester.enterText(find.byKey(const Key('mqtt-field-port')), '8443');
      await _inSheet(tester, 'mqtt-field-path');
      await tester.enterText(find.byKey(const Key('mqtt-field-path')), '/ws');
      await _inSheet(tester, 'mqtt-field-iata');
      await tester.enterText(find.byKey(const Key('mqtt-field-iata')), 'day');
      await _inSheet(tester, 'mqtt-field-auth');
      await tester.tap(find.text('Password'));
      await tester.pumpAndSettle();
      await _inSheet(tester, 'mqtt-field-user');
      await tester.enterText(find.byKey(const Key('mqtt-field-user')), 'andy');
      await _inSheet(tester, 'mqtt-field-pass');
      await tester.enterText(find.byKey(const Key('mqtt-field-pass')), 'hunter2-secret');
      await tester.tap(find.byKey(const Key('mqtt-slot-save')));
      await settleIo(tester);

      final s = r.h.state.settings.mqttSlots.single;
      expect(s.id, 'slot-1');
      expect(s.presetId, isNull);
      expect(s.name, 'My broker');
      expect(s.host, 'mqtt.mine.example');
      expect(s.port, 8443);
      expect(s.wsPath, '/ws');
      expect(s.tls, isTrue);
      expect(s.iata, 'DAY');
      expect(s.auth, MqttAuth.password);
      expect(s.username, 'andy');
      expect(s.enabled, isFalse, reason: 'a new feed is off until turned on');
      expect(utf8.decode((await r.h.secretStore.read('mqtt.slot-1'))!), 'hunter2-secret');
      expect(jsonEncode(r.h.settings.saved.toJson()), isNot(contains('hunter2')), reason: 'never in settings.json');
      expect(find.textContaining('Added My broker'), findsOneWidget);
    });

    testWidgetsT("MeshSonar's own server is refused as a feed host, in any spelling, with plain words", (tester) async {
      final r = await _open(tester);
      for (final host in ['mqtt.meshsonar.com', 'MQTT.MeshSonar.com.', 'mqtt.meshsonar.com:8883']) {
        await _openPicker(tester);
        await tester.tap(find.byKey(const Key('mqtt-preset-custom')));
        await settleIo(tester);
        await tester.enterText(find.byKey(const Key('mqtt-field-host')), host);
        await tester.tap(find.byKey(const Key('mqtt-slot-save')));
        await tester.pumpAndSettle();
        expect(find.text(meshSonarBrokerRefusal), findsOneWidget, reason: host);
        final err = tester.widget<TextField>(find.descendant(of: find.byKey(const Key('mqtt-field-host')), matching: find.byType(TextField)));
        expect(err.decoration?.errorMaxLines, greaterThanOrEqualTo(3), reason: 'the refusal is a sentence: not cut to one line');
        expect(r.h.state.settings.mqttSlots, isEmpty, reason: 'nothing saved for $host');
        await tester.tap(find.byKey(const Key('mqtt-slot-cancel')));
        await settleIo(tester);
        await showSetting(tester, 'mqtt-add-feed');
      }
      expect(meshSonarBrokerRefusal, isNot(matches(RegExp(r'broker|MQTT_|IATA|JWT', caseSensitive: false))),
          reason: 'plain words, no jargon');
    });

    testWidgetsT('a saved slot pointing at MeshSonar\'s own server says Not allowed, whatever the engine says', (tester) async {
      const ours = MqttSlotSettings(id: 'slot-1', name: 'Ours', host: 'mqtt.meshsonar.com', enabled: true);
      final r = await _open(tester,
          settings: const Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [ours]));
      await settleIo(tester);
      expect(tester.widget<Text>(find.byKey(const Key('mqtt-slot-slot-1-status'))).data, 'Not allowed\n$meshSonarBrokerRefusal');
      r.engine.emitStatus(const [ObserverFeedStatus(slotId: 'slot-1', state: ObserverFeedState.connecting)]);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('mqtt-slot-slot-1-status'))).data, 'Not allowed\n$meshSonarBrokerRefusal');
      expect(r.h.state.settings.mqttSlots.single, ours, reason: 'the saved slot is kept, not dropped');
      // It can never connect, so its switch is off and cannot be turned on (sim tour: it looked like a normal off feed).
      final sw = tester.widget<Switch>(find.byKey(const Key('mqtt-slot-slot-1-switch')));
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNull);
    });

    testWidgetsT('a preset list that names MeshSonar\'s own server never offers it', (tester) async {
      final r = await _open(tester);
      r.h.client
        ..mqttPresetsEtag = '"s2"'
        ..mqttPresetsResult = const MqttPresetList(presets: [
          MqttPreset(id: 'ours', name: 'MeshSonar', host: 'mqtt.meshsonar.com', wsPath: '/mqtt'),
          MqttPreset(id: 'corecomms', name: 'CoreComms', host: 'mqtt.corecomms.net', wsPath: '/mqtt'),
        ]);
      await _openPicker(tester);
      expect(find.byKey(const Key('mqtt-preset-corecomms')), findsOneWidget);
      expect(find.byKey(const Key('mqtt-preset-ours')), findsNothing);
    });

    testWidgetsT('Test sends the form\'s feed to the engine (status message only) and shows the result', (tester) async {
      final r = await _open(tester,
          settings: const Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [_slotA]));
      await showSetting(tester, 'mqtt-slot-slot-1');
      await tester.tap(find.byKey(const Key('mqtt-slot-slot-1')));
      await settleIo(tester);
      await _inSheet(tester, 'mqtt-field-path');
      await tester.enterText(find.byKey(const Key('mqtt-field-path')), '/');
      await _inSheet(tester, 'mqtt-slot-test');
      await tester.tap(find.byKey(const Key('mqtt-slot-test')));
      await settleIo(tester);
      expect(r.engine.tested.single.wsPath, '/', reason: 'the edited, unsaved path is what is tested');
      expect(r.engine.tested.single.host, 'mqtt.corecomms.net');
      await _inSheet(tester, 'mqtt-test-result');
      expect(find.text('Connected: the site accepted the login and the status message.'), findsOneWidget);
      expect(r.h.state.settings.mqttSlots.single.wsPath, '/mqtt', reason: 'Test saves nothing');
    });

    testWidgetsT('Delete removes the feed at once (Undo brings it back) and its Keychain password after the window', (tester) async {
      const pw = MqttSlotSettings(id: 'slot-3', name: 'Pw', host: 'pw.example', auth: MqttAuth.password, username: 'u');
      final r = await _open(tester,
          settings: const Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [_slotA, pw]));
      await r.h.secretStore.write('mqtt.slot-3', utf8.encode('pw'));
      await showSetting(tester, 'mqtt-slot-slot-3');
      await tester.tap(find.byKey(const Key('mqtt-slot-slot-3')));
      await settleIo(tester);
      await _inSheet(tester, 'mqtt-slot-delete');
      await tester.tap(find.byKey(const Key('mqtt-slot-delete')));
      await settleIo(tester);
      expect(find.byKey(const Key('mqtt-delete-slot-3')), findsNothing, reason: 'no confirm dialog');
      expect(r.h.state.settings.mqttSlots.map((x) => x.id), ['slot-1']);
      expect(find.text('Deleted Pw.'), findsOneWidget);
      expect(await r.h.secretStore.read('mqtt.slot-3'), isNotNull, reason: 'the password waits out the Undo window');
      await tester.pump(const Duration(seconds: 7));
      await settleIo(tester);
      expect(await r.h.secretStore.read('mqtt.slot-3'), isNull);
    });

    testWidgetsT('changing only the password of a running feed restarts it so it logs in again now', (tester) async {
      const pw = MqttSlotSettings(id: 'slot-1', name: 'Pw', host: 'pw.example', auth: MqttAuth.password, username: 'u', enabled: true);
      final r = await _open(tester,
          settings: const Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [pw]));
      await r.h.secretStore.write('mqtt.slot-1', utf8.encode('old'));
      await showSetting(tester, 'mqtt-slot-slot-1');
      await tester.tap(find.byKey(const Key('mqtt-slot-slot-1')));
      await settleIo(tester);
      await _inSheet(tester, 'mqtt-field-pass');
      expect(find.text('Saved in the Keychain: leave empty to keep it'), findsOneWidget);
      final before = r.engine.states.length;
      await tester.enterText(find.byKey(const Key('mqtt-field-pass')), 'new-one');
      await tester.tap(find.byKey(const Key('mqtt-slot-save')));
      await settleIo(tester);
      expect(utf8.decode((await r.h.secretStore.read('mqtt.slot-1'))!), 'new-one');
      final seen = r.engine.states.sublist(before).map((s) => s.slots.single.enabled).toList();
      expect(seen, containsAllInOrder([false, true]), reason: 'off then on: a fresh login with the new password');
    });
  });

  group('vocabulary (build plan §4.5 item 6)', () {
    test('Observer, Share with MeshSonar and MQTT feed; no old terms', () {
      final all = [
        observerHelp,
        mqttFeedsHelp,
        ...observerSettingsEntries.expand((e) => [e.title, e.summary]),
        observerJoinTitle,
        observerJoinIntro,
        for (final f in otherDataFlows) '${f.title} ${f.body}',
      ].join('\n');
      for (final old in ['Home observer', 'Become an observer', 'Drive observer', 'Claimed radios']) {
        expect(all, isNot(contains(old)), reason: old);
      }
      expect(telemetryCategory.title, 'Share with MeshSonar');
      // Build 76: the master switch is one row (Sharing & privacy, first level); its pre-76 Observer id is an alias of it.
      expect(observerSettingsEntries.map((e) => e.title), containsAll(['Observer status', 'MQTT feeds']));
      expect(settingsEntry('observer-share').id, 'telemetry-toggle');
      expect(settingsEntry('observer-share').title, 'Share with MeshSonar');
      expect(settingsEntry('observer-share').page, isNull, reason: 'first level');
      expect(observerSettingsEntries.every((e) => e.page == 'observer' && e.section == 'privacy'), isTrue);
      expect(settingsPage('observer').title, 'Sharing status and other sites'); // build 77 (round 5 S9)
    expect(settingsPage('observer').was, 'Observer and MQTT feeds');
      expect(observerJoinIntro, contains('Settings > '));
      expect(otherDataFlows.map((f) => f.title), contains('MQTT feeds to other sites'));
    });
  });

  group('Dynamic Type AX3', () {
    for (final what in ['section', 'picker', 'custom sheet']) {
      testWidgetsT('$what lays out at 3.1x text on a 390 dp phone without overflow', (tester) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final r = _Rig(
            settings: Settings(driverKey: 'k-1234567890', keyStatus: DriverKeyStatus.approved, mqttSlots: [
          _slotA.copyWith(enabled: true),
          const MqttSlotSettings(id: 'slot-2', presetId: 'letsmesh-us', name: 'LetsMesh US', host: 'mqtt-us-v1.letsmesh.net'),
        ]));
        await r.h.pumpApp(tester);
        await openSettingsTab(tester);
        // AX3 on this screen (the shell around it is not part of this check).
        tester.platformDispatcher.textScaleFactorTestValue = 3.1;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await showSetting(tester, 'observer-share-toggle', step: 300);
        await showSetting(tester, 'mqtt-add-feed', step: 300);
        r.engine.emitStatus(const [
          ObserverFeedStatus(slotId: 'slot-1', state: ObserverFeedState.radioCantSign, lastError: 'The connected radio cannot sign a login.'),
        ]);
        await tester.pumpAndSettle();
        if (what != 'section') {
          await showSetting(tester, 'mqtt-add-feed', step: 300);
          await _openPicker(tester);
          if (what == 'custom sheet') {
            await _inSheet(tester, 'mqtt-preset-custom', scroll: _pickerScroll);
            // At AX3 the row is taller than the sheet: tap its top, as a person would.
            await tester.tapAt(tester.getTopLeft(find.byKey(const Key('mqtt-preset-custom'))) + const Offset(40, 30));
            await settleIo(tester);
            await _inSheet(tester, 'mqtt-slot-test');
          } else {
            await tester.scrollUntilVisible(find.byKey(const Key('mqtt-preset-meshmapper')), 200, scrollable: _pickerScroll);
          }
        }
        expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow at AX3');
      });
    }
  });
}

extension on MqttSlotSettings {
  MqttSlotSettings copyWithId(String id) => MqttSlotSettings(
        id: id,
        presetId: presetId,
        name: name,
        host: host,
        port: port,
        wsPath: wsPath,
        tls: tls,
        aud: aud,
        iata: iata,
        auth: auth,
        username: username,
        enabled: enabled,
      );
}

