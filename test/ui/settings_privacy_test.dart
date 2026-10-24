// Settings > Privacy & data sharing, and the first-run disclosure: one source of truth for the words, opt-out
// switches driven by the category registry, confirmation before sharing starts, and erase on the way out.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/ui/settings/data_sharing.dart';
import 'package:meshsonar/ui/settings/display_section.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_settings_privacy_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<DiskHarness> open(WidgetTester tester, {bool key = true, Settings? settings}) async {
    useTallScreen(tester);
    final h = DiskHarness(tmp);
    if (key) h.approveKey();
    if (settings != null) h.settings.saved = settings;
    await h.pumpDiskApp(tester);
    await openSettingsTab(tester);
    return h;
  }

  group('registry', () {
    test('only categories the app really collects are listed; packet headers is the one today', () {
      expect(dataCategories.map((c) => c.id), ['telemetry']);
      expect(telemetryCategory.toggleKey, 'telemetry-toggle', reason: 'existing key kept');
    });

    test('every category is opt-out: on in a fresh Settings', () {
      for (final c in dataCategories) {
        expect(c.isOn(const Settings()), isTrue, reason: c.id);
        expect(c.isOn(c.set(const Settings(), false)), isFalse, reason: c.id);
      }
    });

    test('the packet-header disclosure names every field the record sends', () {
      // TelemetryRecord.wireKeys is the privacy contract; each key must be covered by a disclosed item.
      final shared = telemetryCategory.shared.join(' ').toLowerCase();
      final words = {
        'rx_ts': 'time',
        'type': 'packet type',
        'route': 'route type',
        'hash_size': 'path codes',
        'path': 'repeaters it passed through',
        'snr': 'snr',
        'rssi': 'rssi',
        'pkt_hash': 'fingerprint',
      };
      expect(words.keys, unorderedEquals(TelemetryRecord.wireKeys), reason: 'a new wire key needs a disclosure line');
      for (final e in words.entries) {
        expect(shared, contains(e.value), reason: '${e.key} is sent but not disclosed');
      }
      expect(shared, contains('region code'));
      expect(shared, contains('app version'));
    });
  });

  testWidgets('first-run sheet and Settings say the same words (one source)', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.state.init();
    attachUiPrefs(h.state, UiPrefs(seen: true, telemetryDisclosed: false));
    await tester.pumpWidget(MeshSonarApp(state: h.state));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('telemetry-sheet'));
    expect(sheet, findsOneWidget);
    for (final x in [...telemetryCategory.shared, ...telemetryCategory.neverShared, telemetryCategory.destination]) {
      expect(find.descendant(of: sheet, matching: find.text(x)), findsOneWidget, reason: x);
    }
    expect(find.descendant(of: sheet, matching: find.text(changeYourMindLine)), findsOneWidget);
    expect(changeYourMindLine, contains(privacySectionTitle));
    // Both choices are on screen without scrolling.
    expect(find.byKey(const Key('telemetry-keep')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('telemetry-off')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-keep')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isTrue);

    await openSettingsTab(tester);
    expect(find.text('PRIVACY & DATA SHARING'), findsOneWidget, reason: 'the section the sheet points to exists by that name');
    await showSetting(tester, 'telemetry-toggle');
    expect(find.text(telemetryCategory.title), findsOneWidget);
    expect(find.textContaining(telemetryCategory.summary), findsOneWidget);
  });

  testWidgets('turning sharing on asks first and states what is shared; cancel keeps it off', (tester) async {
    final h = await open(tester, settings: const Settings(
        driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved, telemetryEnabled: false));
    await showSetting(tester, 'telemetry-toggle');
    expect(find.textContaining('Off: nothing is collected.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-on-dialog')), findsOneWidget);
    expect(find.textContaining('Never shared: Message text'), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-on-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isFalse, reason: 'nothing changes without the confirmation');

    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telemetry-on-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isTrue);
    expect(h.settings.saved.telemetryEnabled, isTrue);
  });

  testWidgets('turning it off with a key stops it and offers the erase; Erase calls DELETE', (tester) async {
    final h = await open(tester);
    await showSetting(tester, 'telemetry-toggle');
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isFalse, reason: 'off takes effect before any question');
    expect(find.byKey(const Key('telemetry-erase-dialog')), findsOneWidget);
    expect(find.textContaining(telemetryCategory.offEffect), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-erase-yes')));
    await settleIo(tester, until: () => h.tele.deletes == 1);
    expect(h.tele.deletes, 1);
    expect(find.text('Erased 7 shared packet headers.'), findsOneWidget);
  });

  testWidgets('turning it off and keeping the server copy sends no DELETE', (tester) async {
    final h = await open(tester);
    await showSetting(tester, 'telemetry-toggle');
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telemetry-erase-keep')));
    await settleIo(tester);
    expect(h.tele.deletes, 0);
    expect(h.state.settings.telemetryEnabled, isFalse);
  });

  testWidgets('without a key: off is immediate, says so, and there is nothing to erase', (tester) async {
    final h = await open(tester, key: false);
    await showSetting(tester, 'telemetry-toggle');
    expect(find.textContaining('nothing is collected until this phone has a driver key'), findsOneWidget);
    expect(find.byKey(const Key('telemetry-erase-now')), findsNothing);
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-erase-dialog')), findsNothing);
    expect(h.state.settings.telemetryEnabled, isFalse);
    expect(find.textContaining('Share packet headers is off.'), findsOneWidget);
  });

  testWidgets('erase without turning sharing off: destructive confirm, then DELETE', (tester) async {
    final h = await open(tester);
    await showSetting(tester, 'telemetry-erase-now');
    await tester.tap(find.byKey(const Key('telemetry-erase-now')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-erase-now-dialog')), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.textContaining('Sharing stays on'), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-erase-now-dialog-cancel')));
    await settleIo(tester);
    expect(h.tele.deletes, 0);
    await tester.tap(find.byKey(const Key('telemetry-erase-now')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telemetry-erase-now-dialog-confirm')));
    await settleIo(tester, until: () => h.tele.deletes == 1);
    expect(h.tele.deletes, 1);
    expect(h.state.settings.telemetryEnabled, isTrue);
  });

  testWidgets('"What MeshSonar shares" lists every category item, every other flow and the location points',
      (tester) async {
    await open(tester);
    await showSetting(tester, 'privacy-what-shared');
    await tester.tap(find.byKey(const Key('privacy-what-shared')));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('what-shared-screen'));
    final scroll = find.descendant(of: list, matching: find.byType(Scrollable)).first;
    expect(find.text('Share packet headers: on'), findsOneWidget);
    for (final t in [
      ...telemetryCategory.shared,
      for (final f in otherDataFlows) f.body,
      for (final p in locationPoints) p.body,
    ]) {
      await tester.scrollUntilVisible(find.text(t), 200, scrollable: scroll);
      expect(find.text(t), findsOneWidget);
    }
  });

  testWidgets('Location row opens the same explainer the first run shows, read-only', (tester) async {
    await open(tester);
    await showSetting(tester, 'privacy-location');
    expect(find.text(locationSummary), findsOneWidget);
    await tester.tap(find.byKey(const Key('privacy-location')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('always-location-screen')), findsOneWidget);
    final scroll =
        find.descendant(of: find.byKey(const Key('always-location-screen')), matching: find.byType(Scrollable)).first;
    for (final p in locationPoints) {
      await tester.scrollUntilVisible(find.text(p.head), 150, scrollable: scroll);
      expect(find.text(p.head), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.byKey(const Key('always-location-done')), 150, scrollable: scroll);
    expect(find.byKey(const Key('always-location-continue')), findsNothing, reason: 'no permission prompt from Settings');
    await tester.tap(find.byKey(const Key('always-location-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('always-location-screen')), findsNothing);
  });

  group('units wording matches the behaviour', () {
    test('auto explains the locale rule and says what it resolved to', () {
      expect(unitsExplanation(UnitsPreference.auto, Units.imperial), contains('Auto follows your phone\'s region'));
      expect(unitsExplanation(UnitsPreference.auto, Units.imperial), contains('imperial (ft, mi, mph)'));
      expect(unitsExplanation(UnitsPreference.auto, Units.metric), contains('metric (m, km, km/h)'));
      expect(imperialCountries, {'US', 'LR', 'MM'}, reason: 'the explanation names exactly these');
      expect(unitsExplanation(UnitsPreference.metric, Units.metric), startsWith('Showing metric'));
    });

    testWidgets('the Units row shows the explanation and follows the choice', (tester) async {
      final h = await open(tester, settings: const Settings(units: UnitsPreference.metric));
      await showSetting(tester, 'units-tile');
      expect(find.text(unitsExplanation(UnitsPreference.metric, h.state.units)), findsOneWidget);
      await tester.tap(find.text('Imperial'));
      await tester.pumpAndSettle();
      expect(h.settings.saved.units, UnitsPreference.imperial);
      expect(find.text(unitsExplanation(UnitsPreference.imperial, Units.imperial)), findsOneWidget);
    });
  });
}
