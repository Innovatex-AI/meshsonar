// Antenna picker, once per radio (spec m1-app-0.4.0 §4): AC-11, AC-14 (UI half), AC-15, AC-16 (sheet).
//
// UI contract (keys chosen by Q; texts from the spec):
//   Sheet Key('antenna-sheet'), title "How is this radio's antenna set up?"; mounts ValueKey('mount-<handheld|insideCar|
//     roofMagMount|fixedMast>') ("Handheld", "Inside car", "Roof mag-mount", "Fixed mast"); gain field
//     Key('antenna-gain-field') + "Don't know" switch Key('antenna-gain-unknown'); height field Key('antenna-height-field')
//     in metres; Key('antenna-save'). Upgrade note "Before 0.4.0 you chose External" (or Internal).
//   Drive screen: chip Key('antenna-chip') ("Roof mag-mount · 5.8 dBi · 1.8 m"), tap opens the sheet, locked while
//     driving; without a profile Start drive is disabled and the hint "Set up this radio's antenna" reopens the sheet.
//   Settings → Antenna: one row per saved radio ValueKey('antenna-profile-<key>'), tap to edit;
//     ValueKey('antenna-forget-<key>') forgets it (optional confirm Key('antenna-forget-confirm')).
// AppState: antennaProfile (connected radio's, or null), needsAntennaSetup; Settings.antennaProfiles.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'fakes.dart';
import 'fakes_m1.dart';

const title = 'How is this radio\'s antenna set up?';
const otherRadio = SelfInfo(
  publicKey: 'FFEE000111',
  name: 'Mast Radio',
  radio: Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22),
  firmware: 'v1.9.0',
);

Finder get sheet => find.byKey(const Key('antenna-sheet'));
Finder mount(String m) => find.byKey(ValueKey('mount-$m'));

String fieldText(WidgetTester tester, String key) => tester
    .widget<EditableText>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText), matchRoot: true))
    .controller
    .text;

Future<void> connectUi(WidgetTester tester, {String device = 'MeshCore-Truck'}) async {
  await tester.tap(find.byKey(const Key('connection-chip')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(device));
  await settle(tester);
  await tester.pumpAndSettle();
}

Future<void> closeSheet(WidgetTester tester) async {
  Navigator.of(tester.element(sheet)).pop();
  await tester.pumpAndSettle();
}

Future<void> fillSheet(WidgetTester tester, {required String m, String? gain, bool dontKnow = false, required String height}) async {
  await tester.ensureVisible(mount(m));
  await tester.tap(mount(m));
  await tester.pumpAndSettle();
  if (dontKnow) {
    await tester.ensureVisible(find.byKey(const Key('antenna-gain-unknown')));
    await tester.tap(find.byKey(const Key('antenna-gain-unknown')));
    await tester.pumpAndSettle();
  } else if (gain != null) {
    await tester.enterText(find.byKey(const Key('antenna-gain-field')), gain);
  }
  await tester.enterText(find.byKey(const Key('antenna-height-field')), height);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('antenna-save')));
  await tester.tap(find.byKey(const Key('antenna-save')));
  await tester.pumpAndSettle();
}

bool startEnabled(WidgetTester tester) => isEnabled(tester, find.byKey(const Key('start-stop')));

void main() {
  testWidgets('AC-11: first connect opens the sheet and blocks Start; saving enables it; same radio never prompts again',
      (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false)..approveKey();
    await h.pumpApp(tester);
    await connectUi(tester);
    expect(sheet, findsOneWidget);
    expect(find.text(title), findsOneWidget);
    for (final m in ['handheld', 'insideCar', 'roofMagMount', 'fixedMast']) {
      expect(mount(m), findsOneWidget);
    }
    expect(isEnabled(tester, find.byKey(const Key('antenna-save'))), isFalse, reason: 'no mount, no height yet');
    expect(h.state.needsAntennaSetup, isTrue);

    // Dismissed without saving: Start drive stays disabled with the hint; the hint reopens the sheet.
    await closeSheet(tester);
    expect(startEnabled(tester), isFalse);
    expect(find.text('Set up this radio\'s antenna'), findsOneWidget);
    await h.state.startDrive();
    await tester.pump();
    expect(h.state.driving, isFalse, reason: 'no drive without the radio\'s antenna');
    await tester.tap(find.text('Set up this radio\'s antenna'));
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);

    await fillSheet(tester, m: 'roofMagMount', gain: '5.8', height: '1.8');
    await save(tester);
    expect(sheet, findsNothing);
    expect(h.state.needsAntennaSetup, isFalse);
    expect(startEnabled(tester), isTrue);
    expect(find.text('Set up this radio\'s antenna'), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('antenna-chip')), matching: find.text('Roof mag-mount · 5.8 dBi · 1.8 m')),
        findsOneWidget);
    final p = h.settings.saved.antennaProfiles['abcdef0123']!;
    expect(p.mount, AntennaMount.roofMagMount);
    expect(p.gainDbi, 5.8);
    expect(p.heightM, 1.8);
    expect(h.settings.saved.antennaProfiles.keys, ['abcdef0123'], reason: 'keyed by the lower-case public key');

    // AC-14, UI half: the drive gets the v1 mapping of this radio's profile.
    await tester.tap(find.byKey(const Key('start-stop')));
    await settle(tester);
    expect(h.state.driving, isTrue);
    expect(h.store.sessionsById.values.single.antenna.toJson(), {'type': 'external', 'gain_dbi': 5.8, 'height_m': 1.8});
    // Locked while driving: the chip doesn't open the sheet.
    await tester.tap(find.byKey(const Key('antenna-chip')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);

    // Reconnect the same radio: no prompt.
    await h.state.disconnect();
    await tester.pumpAndSettle();
    await connectUi(tester);
    expect(sheet, findsNothing);
    expect(startEnabled(tester), isTrue);

    // A different radio prompts.
    await h.state.disconnect();
    await tester.pumpAndSettle();
    h.selfInfo = otherRadio;
    await connectUi(tester);
    expect(sheet, findsOneWidget);
    await drain(tester);
  });

  testWidgets('Save needs a mount and a height in range; gain −10…20 dBi or "Don\'t know" (→ gain_dbi null)',
      (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false);
    await h.pumpApp(tester);
    await connectUi(tester);
    final saveBtn = find.byKey(const Key('antenna-save'));
    await fillSheet(tester, m: 'handheld', gain: '2', height: '');
    expect(isEnabled(tester, saveBtn), isFalse, reason: 'height is required');
    for (final bad in ['-1', '300.5', 'tall']) {
      await tester.enterText(find.byKey(const Key('antenna-height-field')), bad);
      await tester.pumpAndSettle();
      expect(isEnabled(tester, saveBtn), isFalse, reason: 'height $bad');
    }
    await tester.enterText(find.byKey(const Key('antenna-height-field')), '1.2');
    await tester.pumpAndSettle();
    expect(isEnabled(tester, saveBtn), isTrue);
    for (final bad in ['25', '-11']) {
      await tester.enterText(find.byKey(const Key('antenna-gain-field')), bad);
      await tester.pumpAndSettle();
      expect(isEnabled(tester, saveBtn), isFalse, reason: 'gain $bad');
    }
    await tester.ensureVisible(find.byKey(const Key('antenna-gain-unknown')));
    await tester.tap(find.byKey(const Key('antenna-gain-unknown')));
    await tester.pumpAndSettle();
    expect(isEnabled(tester, saveBtn), isTrue, reason: '"Don\'t know" replaces the gain');
    await save(tester);
    expect(h.settings.saved.antennaProfiles['abcdef0123']!.gainDbi, isNull);
    await h.state.startDrive();
    await tester.pump();
    expect(h.store.sessionsById.values.single.antenna.toJson(), {'type': 'internal', 'gain_dbi': null, 'height_m': 1.2});
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('the simulator follows the same rule', (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false);
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('connection-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simulator')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    await closeSheet(tester);
    expect(startEnabled(tester), isFalse);
    await drain(tester);
  });

  for (final (old, firstMounts, otherMounts, note) in [
    ('external', ['roofMagMount', 'fixedMast'], ['handheld', 'insideCar'], 'Before 0.4.0 you chose External'),
    ('internal', ['handheld', 'insideCar'], ['roofMagMount', 'fixedMast'], 'Before 0.4.0 you chose Internal'),
  ]) {
    testWidgets('AC-15: upgrading from 0.3.x with an $old antenna prefills gain and height, mount unselected, '
        'matching mounts first; nothing else in settings changes', (tester) async {
      useTallScreen(tester);
      final h = Harness(antennaProfile: false);
      final before = Settings(
        driverKey: 'secretkey-abcdef-1234',
        keyStatus: DriverKeyStatus.approved,
        display: 'KD8XYZ',
        antenna: Antenna(type: old, gainDbi: 5.8, heightM: 1.8),
        intervalSec: 45,
      );
      h.settings.saved = before;
      await h.pumpApp(tester);
      await connectUi(tester);
      expect(sheet, findsOneWidget);
      expect(find.textContaining(note), findsOneWidget);
      expect(fieldText(tester, 'antenna-gain-field'), '5.8');
      expect(fieldText(tester, 'antenna-height-field'), '1.8');
      expect(isEnabled(tester, find.byKey(const Key('antenna-save'))), isFalse, reason: 'mount left unselected');
      double y(String m) => tester.getTopLeft(mount(m)).dy;
      for (final f in firstMounts) {
        for (final o in otherMounts) {
          expect(y(f), lessThan(y(o)), reason: '$f is offered before $o');
        }
      }
      await tester.tap(mount(firstMounts.first));
      await tester.pumpAndSettle();
      await save(tester);
      final after = h.settings.saved.toJson()..remove('antenna_profiles')..remove('auto_key'); // the fake store loads with auto key off
      final want = before.toJson()..remove('antenna_profiles')..remove('auto_key');
      expect(after, want, reason: 'the old antenna key is kept (read-only) and nothing else changed');
      expect(h.settings.saved.antennaProfiles['abcdef0123']!.gainDbi, 5.8);
      expect(h.settings.saved.antennaProfiles['abcdef0123']!.heightM, 1.8);

      // Once saved, that radio never prompts again, even after a restart.
      final h2 = Harness(antennaProfile: false)..settings.saved = h.settings.saved;
      await h2.pumpApp(tester);
      await connectUi(tester);
      expect(sheet, findsNothing);
      expect(h2.state.antennaProfile!.mount, AntennaMount.values.byName(firstMounts.first));
      await drain(tester);
    });
  }

  testWidgets('AC-11: Settings → Antenna lists saved radios; edit and Forget work; a forgotten radio prompts again',
      (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false);
    h.settings.saved = const Settings().copyWith(antennaProfiles: {
      'abcdef0123': AntennaProfile(
          mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.utc(2026, 10, 16)),
      'ffee000111': AntennaProfile(
          mount: AntennaMount.fixedMast, gainDbi: null, heightM: 9, updatedAt: DateTime.utc(2026, 10, 16)),
    });
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('antenna-profile-abcdef0123'));
    await scrollSettingsTo(tester, row, step: 150);
    expect(find.descendant(of: row, matching: find.textContaining(RegExp('Truck Radio|abcdef', caseSensitive: false))),
        findsWidgets, reason: 'name if known, else key prefix');
    expect(find.descendant(of: row, matching: find.textContaining('Roof mag-mount')), findsWidgets);
    expect(find.descendant(of: row, matching: find.textContaining('5.8')), findsWidgets);
    await scrollSettingsTo(tester, find.byKey(const ValueKey('antenna-profile-ffee000111')), step: 150);
    expect(find.descendant(of: find.byKey(const ValueKey('antenna-profile-ffee000111')), matching: find.textContaining('Fixed mast')),
        findsWidgets);

    // Edit: tap the row, change the height.
    await scrollSettingsTo(tester, row, step: -150);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    await tester.enterText(find.byKey(const Key('antenna-height-field')), '2.4');
    await tester.pumpAndSettle();
    await save(tester);
    expect(h.settings.saved.antennaProfiles['abcdef0123']!.heightM, 2.4);
    expect(h.settings.saved.antennaProfiles['abcdef0123']!.mount, AntennaMount.roofMagMount);

    // Forget the connected radio: it prompts again on the next connect; the other radio is untouched.
    final forget = find.byKey(const ValueKey('antenna-forget-abcdef0123'));
    await scrollSettingsTo(tester, forget, step: 100);
    await tester.tap(forget);
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('antenna-forget-confirm'));
    if (confirm.evaluate().isNotEmpty) {
      await tester.tap(confirm);
      await tester.pumpAndSettle();
    }
    expect(h.settings.saved.antennaProfiles.keys, ['ffee000111']);
    await h.state.disconnect();
    await openDriveTab(tester);
    await tester.pumpAndSettle();
    await connectUi(tester);
    expect(sheet, findsOneWidget);
    await drain(tester);
  });

  testWidgets('the drive-screen chip opens the sheet when not driving; setAntennaType is gone (no global toggle)',
      (tester) async {
    useTallScreen(tester);
    final h = Harness(); // default radio has an inside-car profile (fakes.dart testAntennaProfiles)
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('antenna-toggle')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('antenna-chip')), matching: find.textContaining('Inside car')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('antenna-chip')));
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(fieldText(tester, 'antenna-height-field'), '1.2');
    await drain(tester);
  });

  testWidgets('AC-16: sheet at 320 dp and 2.0× text has no overflow, labelled controls and 48 dp targets', (tester) async {
    tester.view.physicalSize = const Size(960, 2400);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final semantics = tester.ensureSemantics();
    final h = Harness(antennaProfile: false);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    for (final label in ['Handheld', 'Inside car', 'Roof mag-mount', 'Fixed mast', 'Don\'t know']) {
      expect(find.bySemanticsLabel(RegExp(RegExp.escape(label))), findsWidgets, reason: label);
    }
    await fillSheet(tester, m: 'fixedMast', dontKnow: true, height: '6');
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await drain(tester);
  });
}
