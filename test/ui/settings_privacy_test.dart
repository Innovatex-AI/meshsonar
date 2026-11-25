// Settings > Privacy & data sharing, and the first-run disclosure: one source of truth for the words, opt-out
// switches driven by the category registry, confirmation before sharing starts, and erase on the way out.
import 'toast_test_kit.dart';
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
import 'package:meshsonar/ui/settings/settings_index.dart';

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
    test('packet headers first, then the stream-7 drive-context categories (data_collection_ui_test covers them)', () {
      expect(dataCategories.map((c) => c.id),
          ['telemetry', 'motion', 'barometer', 'phone_battery', 'device', 'radio_health', 'radio_config', 'weather']);
      expect(telemetryCategory.toggleKey, 'telemetry-toggle', reason: 'existing key kept');
    });

    test('every category is opt-out: on in a fresh Settings', () {
      for (final c in dataCategories) {
        expect(c.isOn(const Settings()), isTrue, reason: c.id);
        expect(c.isOn(c.set(const Settings(), false)), isFalse, reason: c.id);
      }
    });

    test('the observer disclosure names every field the record sends (v1 and v2)', () {
      // TelemetryRecord.wireKeysV2 is the privacy contract (Nov 8 2026: v2 adds raw, channel, cell); each key must be
      // covered by a disclosed item.
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
        'raw': 'public packets in full',
        'channel': 'public channel and # channel',
        'cell': '~5 km area',
        'pos': 'exact position during a drive',
        'own': 'repeats of your own pings',
      };
      expect(words.keys, unorderedEquals(TelemetryRecord.wireKeysV2), reason: 'a new wire key needs a disclosure line');
      for (final e in words.entries) {
        expect(shared, contains(e.value), reason: '${e.key} is sent but not disclosed');
      }
      expect(shared, contains('region code'));
      expect(shared, contains('app version'));
      // The observer block: random id, radio model / firmware / preset / antenna (no home position since 0.38).
      expect(shared, isNot(contains('home')));
      for (final w in ['random observer number', 'board model', 'firmware', 'frequency', 'antenna']) {
        expect(shared, contains(w), reason: 'observer field "$w" not disclosed');
      }
      final never = telemetryCategory.neverShared.join(' ').toLowerCase();
      for (final w in ['direct messages', 'private channels', 'public key', 'exact position']) {
        expect(never, contains(w));
      }
    });
  });

  testWidgetsT('first-run sheet and Settings say the same words (one source)', (tester) async {
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
    // Build 76: the section is "Sharing & privacy"; the sheet's line names it from the same constant.
    expect(sectionInfo('privacy').title, privacySectionTitle);
    await showSetting(tester, 'telemetry-toggle');
    expect(find.text(privacySectionTitle.toUpperCase()), findsOneWidget, reason: 'the section the sheet points to exists by that name');
    expect(find.descendant(of: find.byKey(const Key('telemetry-toggle')), matching: find.text(telemetryCategory.title)), findsOneWidget);
    // The switch has one short line now; the registry's words (the ones the sheet showed) are on "What MeshSonar shares".
    expect(find.descendant(of: find.byKey(const Key('telemetry-toggle')), matching: find.text(telemetryCategory.onStatus!(h.state)!)), findsOneWidget);
    await showSetting(tester, 'privacy-what-shared');
    await tester.tap(find.byKey(const Key('privacy-what-shared')));
    await tester.pumpAndSettle();
    final page = find.byKey(const Key('what-shared-screen'));
    final scroll = find.descendant(of: page, matching: find.byType(Scrollable)).first;
    expect(find.descendant(of: page, matching: find.text(telemetryCategory.disclosureLead)), findsOneWidget);
    for (final x in telemetryCategory.shared) {
      await tester.scrollUntilVisible(find.text(x), 200, scrollable: scroll);
      expect(find.descendant(of: page, matching: find.text(x)), findsOneWidget, reason: x);
    }
    for (final x in telemetryCategory.neverShared) {
      await tester.scrollUntilVisible(find.text('Never: $x'), 200, scrollable: scroll);
      expect(find.descendant(of: page, matching: find.text('Never: $x')), findsOneWidget, reason: x);
    }
    await tester.scrollUntilVisible(find.text(telemetryCategory.destination), 200, scrollable: scroll);
    expect(find.descendant(of: page, matching: find.text(telemetryCategory.destination)), findsOneWidget);
  });

  testWidgetsT('turning sharing on asks first and states what is shared; cancel keeps it off', (tester) async {
    final h = await open(tester, settings: const Settings(
        driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved, telemetryEnabled: false));
    await showSetting(tester, 'telemetry-toggle');
    expect(find.descendant(of: find.byKey(const Key('telemetry-toggle')), matching: find.textContaining('Off: this phone shares nothing')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('telemetry-toggle'))).value, isFalse);
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-on-dialog')), findsOneWidget);
    expect(find.textContaining('Never shared: Direct messages and private channels'), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-on-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isFalse, reason: 'nothing changes without the confirmation');

    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telemetry-on-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isTrue);
    expect(h.settings.saved.telemetryEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('telemetry-toggle'))).value, isTrue);
    expect(find.textContaining('Off: this phone shares nothing'), findsNothing);
  });

  testWidgetsT('Share with MeshSonar is ONE switch: first row of Sharing & privacy, not on the Observer or What is shared pages',
      (tester) async {
    await open(tester);
    await showSetting(tester, 'telemetry-toggle');
    expect(find.byType(SwitchListTile).evaluate().where((e) => (e.widget as SwitchListTile).title is Text && ((e.widget as SwitchListTile).title as Text).data == telemetryCategory.title),
        hasLength(1));
    expect(find.descendant(of: find.byKey(const Key('section-privacy')), matching: find.byKey(const Key('telemetry-toggle'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('observer-share-toggle')), matching: find.byKey(const Key('telemetry-toggle'))), findsOneWidget,
        reason: 'the pre-76 Observer switch key is around the same switch');
    for (final other in ['page-observer', 'page-sharing', 'privacy-location', 'privacy-zones', 'privacy-policy']) {
      expect(tester.getTopLeft(find.byKey(const Key('telemetry-toggle'))).dy, lessThan(tester.getTopLeft(find.byKey(Key(other))).dy),
          reason: 'the switch is above $other');
    }
    expect(settingsEntryAliases['observer-share'], 'telemetry-toggle');
    expect(resolveSettingsTarget('observer-share')?.section, 'privacy');
    expect(resolveSettingsTarget('observer-share')?.page, isNull);
    for (final page in ['observer', 'sharing']) {
      await openSettingsPageRow(tester, page);
      expect(find.byKey(Key('settings-page-$page')), findsOneWidget);
      expect(find.byKey(const Key('telemetry-toggle')), findsNothing, reason: 'not repeated on the $page page');
      expect(find.byKey(const Key('observer-share-toggle')), findsNothing, reason: page);
      await closeSettingsPage(tester);
    }
    // The What is shared page: the seven per-item switches and the full list.
    await openSettingsPageRow(tester, 'sharing');
    for (final c in driveContextCategories) {
      await showSetting(tester, c.toggleKey);
      expect(find.descendant(of: find.byKey(const Key('settings-page-sharing')), matching: find.byKey(Key(c.toggleKey))), findsOneWidget, reason: c.id);
    }
    expect(driveContextCategories, hasLength(7));
  });

  testWidgetsT('turning it off with a key stops it and offers the erase; Erase calls DELETE', (tester) async {
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
    expect(find.text('Erased 7 shared observer packets.'), findsOneWidget);
  });

  testWidgetsT('turning it off and keeping the server copy sends no DELETE', (tester) async {
    final h = await open(tester);
    await showSetting(tester, 'telemetry-toggle');
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telemetry-erase-keep')));
    await settleIo(tester);
    expect(h.tele.deletes, 0);
    expect(h.state.settings.telemetryEnabled, isFalse);
  });

  testWidgetsT('without a key: off is immediate, says so, and there is nothing to erase', (tester) async {
    final h = await open(tester, key: false);
    await showSetting(tester, 'telemetry-toggle');
    expect(find.textContaining('nothing is collected until this phone has a driver key'), findsOneWidget);
    // The erase row lives on the Observer page (build 76); without a key there is none.
    await showSetting(tester, 'telemetry-location-selector');
    expect(find.byKey(const Key('settings-page-observer')), findsOneWidget);
    expect(find.byKey(const Key('telemetry-erase-now')), findsNothing);
    await showSetting(tester, 'telemetry-toggle');
    await tester.tap(find.byKey(const Key('telemetry-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-erase-dialog')), findsNothing);
    expect(h.state.settings.telemetryEnabled, isFalse);
    expect(find.textContaining('Share with MeshSonar is off.'), findsOneWidget);
  });

  testWidgetsT('erase without turning sharing off: destructive confirm, then DELETE', (tester) async {
    final h = await open(tester);
    await showSetting(tester, 'telemetry-erase-now');
    expect(find.descendant(of: find.byKey(const Key('settings-page-observer')), matching: find.byKey(const Key('telemetry-erase-now'))), findsOneWidget,
        reason: 'build 76: on Sharing & privacy > Observer and MQTT feeds');
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

  testWidgetsT('"What MeshSonar shares" lists every category item, every other flow and the location points',
      (tester) async {
    final h = await open(tester, settings: const Settings(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved)
        .withCollection('barometer', false));
    await showSetting(tester, 'privacy-what-shared');
    expect(find.byKey(const Key('settings-page-sharing')), findsOneWidget, reason: 'the full list is the last row of What is shared');
    await tester.tap(find.byKey(const Key('privacy-what-shared')));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('what-shared-screen'));
    final scroll = find.descendant(of: list, matching: find.byType(Scrollable)).first;
    // Build 76: a summary card first (how many are on, and the way back to the switches).
    final summary = find.byKey(const Key('what-shared-summary'));
    expect(find.descendant(of: summary, matching: find.text('${dataCategories.length - 1} of ${dataCategories.length} on')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.textContaining('Settings > $privacySectionTitle')), findsOneWidget);
    // Each category: its title as a heading, and the state as an On / Off pill next to it (was "Title: on").
    expect(find.text('Share with MeshSonar: on'), findsNothing);
    for (final c in dataCategories) {
      final pill = find.byKey(Key('what-shared-state-${c.id}'));
      await tester.scrollUntilVisible(pill, 200, scrollable: scroll);
      expect(find.descendant(of: pill, matching: find.text(c.id == 'barometer' ? 'Off' : 'On')), findsOneWidget, reason: c.id);
      expect(find.descendant(of: list, matching: find.text(c.title)), findsWidgets, reason: c.id);
      expect((tester.getCenter(pill).dy - tester.getCenter(find.descendant(of: list, matching: find.text(c.title)).first).dy).abs(), lessThan(60),
          reason: '${c.id}: the pill sits with its heading');
    }
    await tester.drag(scroll, const Offset(0, 100000));
    await tester.pumpAndSettle();
    for (final t in [
      ...telemetryCategory.shared,
      for (final f in otherDataFlows) f.body,
      for (final p in locationPoints) p.body,
    ]) {
      await tester.scrollUntilVisible(find.text(t), 200, scrollable: scroll);
      expect(find.text(t), findsOneWidget);
    }
    // The page ends with the privacy policy.
    final policy = find.byKey(const Key('what-shared-policy'));
    await tester.scrollUntilVisible(policy, 200, scrollable: scroll);
    expect(tester.getSize(policy).height, greaterThanOrEqualTo(48));
    await tester.tap(policy);
    await tester.pumpAndSettle();
    expect(h.openedUrls.last, Uri.parse('https://meshsonar.com/privacy'));
    // The summary card goes back to the switches.
    await tester.drag(scroll, const Offset(0, 100000));
    await tester.pumpAndSettle();
    await tester.tap(summary);
    await tester.pumpAndSettle();
    expect(list, findsNothing);
    expect(find.byKey(const Key('settings-page-sharing')), findsOneWidget);
  });

  testWidgetsT('Location row opens the same explainer the first run shows, read-only', (tester) async {
    await open(tester);
    await showSetting(tester, 'privacy-location');
    // Build 76: one short line on the row; the four points are on the page it opens.
    expect(find.descendant(of: find.byKey(const Key('privacy-location')), matching: find.text('Why the app asks for "Always", and what it is never used for.')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('section-privacy')), matching: find.byKey(const Key('privacy-location'))), findsOneWidget);
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

    testWidgetsT('the Units row shows the explanation and follows the choice', (tester) async {
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
