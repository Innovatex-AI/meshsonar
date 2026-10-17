// MeshSonar 0.4.0 review fixes (R review of df74762; decisions L, Oct 17). Numbers are R's.
//   (5) antenna sheet: "Don't know" prefilled ON for a null gain; a disabled Save says why.
//   (6) while driving: the chip shows what the drive records; Settings can't edit or forget the connected radio's
//       antenna; no setup button.
//   (8) the saved report keeps its form (category, description, include log, drive) and restores it; a 400 says the
//       report can't be sent as written and offers Edit / Discard.
//   (10) "Open driver key settings" from the report form keeps what was typed.
//   (11) the full-screen map shows "Set up this radio's antenna" while Start is disabled.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';

import 'fakes.dart';
import 'fakes_m1.dart';

const reasonLine = 'Pick a mount, enter the height, and a gain or Don\'t know';
const setupHint = 'Set up this radio\'s antenna';
const appKey = 'secretkey-abcdef-1234';

Finder get sheet => find.byKey(const Key('antenna-sheet'));

bool dontKnowOn(WidgetTester tester) => tester
    .widget<Switch>(find.descendant(
        of: find.byKey(const Key('antenna-gain-unknown')), matching: find.byType(Switch), matchRoot: true))
    .value;

String fieldText(WidgetTester tester, Key key) => tester
    .widget<EditableText>(find.descendant(of: find.byKey(key), matching: find.byType(EditableText), matchRoot: true))
    .controller
    .text;

Settings approved() => const Settings(
    serverUrl: 'https://cmat.example.org', driverKey: appKey, keyStatus: DriverKeyStatus.approved, display: 'KD8XYZ');

void main() {
  group('(5) antenna sheet', () {
    testWidgets('a saved profile with "Don\'t know" gain opens with Don\'t know ON and Save enabled', (tester) async {
      useTallScreen(tester);
      final h = Harness(); // the default radio's profile: inside car, gain null, 1.2 m
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('antenna-chip')));
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      expect(dontKnowOn(tester), isTrue);
      expect(isEnabled(tester, find.byKey(const Key('antenna-save'))), isTrue, reason: 'nothing to fix: saved as it was');
      expect(find.text(reasonLine), findsNothing);
      await drain(tester);
    });

    testWidgets('a 0.3.x antenna with no gain opens with Don\'t know ON (height prefilled, mount still to pick)',
        (tester) async {
      useTallScreen(tester);
      final h = Harness(antennaProfile: false);
      h.settings.saved = const Settings(antenna: Antenna(type: 'external', gainDbi: null, heightM: 1.8));
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      expect(dontKnowOn(tester), isTrue);
      expect(fieldText(tester, const Key('antenna-height-field')), '1.8');
      await drain(tester);
    });

    testWidgets('a 0.3.x antenna with a gain opens with Don\'t know OFF', (tester) async {
      useTallScreen(tester);
      final h = Harness(antennaProfile: false);
      h.settings.saved = const Settings(antenna: Antenna(type: 'external', gainDbi: 5.8, heightM: 1.8));
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      expect(dontKnowOn(tester), isFalse);
      expect(fieldText(tester, const Key('antenna-gain-field')), '5.8');
      await drain(tester);
    });

    testWidgets('while Save is disabled one line says why; it goes once the sheet is complete', (tester) async {
      useTallScreen(tester);
      final h = Harness(antennaProfile: false);
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      expect(isEnabled(tester, find.byKey(const Key('antenna-save'))), isFalse);
      expect(find.text(reasonLine), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mount-roofMagMount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('antenna-height-field')), '1.8');
      await tester.pumpAndSettle();
      expect(find.text(reasonLine), findsOneWidget, reason: 'still no gain and Don\'t know is off');
      await tester.enterText(find.byKey(const Key('antenna-gain-field')), '5.8');
      await tester.pumpAndSettle();
      expect(isEnabled(tester, find.byKey(const Key('antenna-save'))), isTrue);
      expect(find.text(reasonLine), findsNothing);
      await tester.enterText(find.byKey(const Key('antenna-height-field')), '400');
      await tester.pumpAndSettle();
      expect(find.text(reasonLine), findsOneWidget, reason: 'a height out of range disables Save again');
      await drain(tester);
    });
  });

  group('(6) while driving', () {
    testWidgets('the chip shows the recorded antenna, not the profile\'s mount', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('antenna-chip')), matching: find.text('Inside car · 1.2 m')),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('start-stop')));
      await settle(tester);
      expect(h.state.driving, isTrue);
      expect(find.descendant(of: find.byKey(const Key('antenna-chip')), matching: find.text('Internal · 1.2 m')),
          findsOneWidget, reason: 'what the drive records (v1 type, gain, height)');
      await h.state.stopDrive();
      await settle(tester);
      expect(find.descendant(of: find.byKey(const Key('antenna-chip')), matching: find.text('Inside car · 1.2 m')),
          findsOneWidget);
      await drain(tester);
    });

    testWidgets('Settings → Antenna: the connected radio\'s row can\'t be edited or forgotten during a drive',
        (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.settings.saved = const Settings().copyWith(antennaProfiles: {
        'abcdef0123': AntennaProfile(
            mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.utc(2026, 10, 16)),
      });
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await tester.pumpAndSettle();
      expect(h.state.driving, isTrue);
      await openSettings(tester);
      final row = find.byKey(const ValueKey('antenna-profile-abcdef0123'));
      await scrollSettingsTo(tester, row, step: 150);
      await tester.tap(row, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing, reason: 'no editing the antenna a running drive is recording');
      final forget = find.byKey(const ValueKey('antenna-forget-abcdef0123'));
      if (forget.evaluate().isNotEmpty) {
        expect(isEnabled(tester, forget), isFalse);
        await tester.tap(forget, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('antenna-forget-confirm')), findsNothing);
      expect(h.settings.saved.antennaProfiles.keys, contains('abcdef0123'));

      // After the drive both work again.
      await h.state.stopDrive();
      await tester.pumpAndSettle();
      await scrollSettingsTo(tester, row, step: 150);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      await drain(tester);
    });

    testWidgets('no setup button while driving, even if the radio\'s profile goes away mid-drive', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await tester.pumpAndSettle();
      await h.state.forgetAntennaProfile('abcdef0123');
      await tester.pumpAndSettle();
      expect(h.state.driving, isTrue);
      expect(find.byKey(const Key('antenna-setup')), findsNothing);
      expect(find.text(setupHint), findsNothing);
      expect(isEnabled(tester, find.byKey(const Key('start-stop'))), isTrue, reason: 'Stop drive always works');
      await h.state.stopDrive();
      await tester.pumpAndSettle();
      expect(find.text(setupHint), findsOneWidget, reason: 'after the drive the radio asks again');
      await drain(tester);
    });
  });

  testWidgets('(11) the full-screen map shows the setup hint while Start drive is disabled', (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await tester.pumpAndSettle();
    if (sheet.evaluate().isNotEmpty) {
      Navigator.of(tester.element(sheet)).pop();
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('map-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.text(setupHint), findsOneWidget);
    expect(isEnabled(tester, find.byKey(const Key('start-stop'))), isFalse);
    await tester.tap(find.text(setupHint));
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget, reason: 'the hint opens the sheet from the full-screen map too');
    await drain(tester);
  });

  group('(8) the saved report keeps its form', () {
    Future<void> fill(WidgetTester tester) async {
      await openReportFromSettings(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('report-category-gps')));
      await tester.tap(find.byKey(const ValueKey('report-category-gps')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('report-description')), 'GPS jumps around near the river');
      await tester.ensureVisible(find.byKey(const Key('report-include-log')));
      await tester.tap(find.byKey(const Key('report-include-log')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('report-attach-drive')));
      await tester.tap(find.byKey(const Key('report-attach-drive')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Evening loop').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('report-review')));
      await tester.tap(find.byKey(const Key('report-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('report-send')));
      await settle(tester);
      await tester.pumpAndSettle();
    }

    void expectForm(WidgetTester tester) {
      expect(fieldText(tester, const Key('report-description')), 'GPS jumps around near the river');
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('report-category-gps'))).selected, isTrue);
      expect(
          tester
              .widget<Switch>(find.descendant(
                  of: find.byKey(const Key('report-include-log')), matching: find.byType(Switch), matchRoot: true))
              .value,
          isFalse);
      expect(find.descendant(of: find.byKey(const Key('report-attach-drive')), matching: find.textContaining('Evening loop')),
          findsWidgets);
    }

    testWidgets('after a failed send and a restart, the form comes back as it was typed', (tester) async {
      useTallScreen(tester);
      final drafts = FakeReportDraftStore();
      final h1 = M1Harness(drafts: drafts);
      h1.settings.saved = approved();
      seedDrive(h1);
      h1.reports.error = const CmatException('network error: no route');
      await h1.pumpApp(tester);
      await fill(tester);
      expect(drafts.draft, isNotNull);
      final saved = h1.state.savedReport!;
      expect(saved.form.category, 'gps');
      expect(saved.form.description, 'GPS jumps around near the river');
      expect(saved.form.includeLog, isFalse);
      expect(saved.form.driveId, 'd1');
      await drain(tester);

      final h2 = M1Harness(drafts: drafts);
      h2.settings.saved = approved();
      seedDrive(h2);
      await h2.pumpApp(tester);
      expect(h2.state.savedReport!.form.description, 'GPS jumps around near the river');
      await openReportFromSettings(tester);
      expectForm(tester);
      expect(h2.reports.sent, isEmpty);
      await drain(tester);
    });

    testWidgets('a 400 says it can\'t be sent as written; Edit goes back to the form, Discard deletes it',
        (tester) async {
      useTallScreen(tester);
      final h = M1Harness();
      h.settings.saved = approved();
      seedDrive(h);
      h.reports.error = const CmatException('description: bad', status: 400);
      await h.pumpApp(tester);
      await fill(tester);
      expect(find.textContaining('The server couldn\'t accept this report as written.'), findsWidgets);
      expect(find.byKey(const Key('report-edit')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('report-edit')), matching: find.text('Edit report')), findsOneWidget);
      expect(find.byKey(const Key('report-discard')), findsOneWidget);

      await tester.tap(find.byKey(const Key('report-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('report-screen')), findsOneWidget);
      expect(find.byKey(const Key('report-preview')), findsNothing);
      expectForm(tester);

      await tester.ensureVisible(find.byKey(const Key('report-review')));
      await tester.tap(find.byKey(const Key('report-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('report-send')));
      await settle(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('report-discard')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('report-discard-confirm'));
      if (confirm.evaluate().isNotEmpty) {
        await tester.tap(confirm);
        await tester.pumpAndSettle();
      }
      expect(h.drafts.draft, isNull);
      expect(h.state.savedReport, isNull);
      expect(find.byKey(const Key('report-preview')), findsNothing);
      await drain(tester);
    });
  });

  testWidgets('(10) "Open driver key settings" keeps what was typed in the report form', (tester) async {
    useTallScreen(tester);
    final h = M1Harness(); // no key yet
    await h.pumpApp(tester);
    await openReportFromSettings(tester);
    await tester.tap(find.byKey(const ValueKey('report-category-bug')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('report-description')), 'Typed before getting a key');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('report-key-settings')));
    await tester.tap(find.byKey(const Key('report-key-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('section-driver')).hitTestable(), findsOneWidget);

    // Back to the report: either it is still under the settings page, or it opens again from Settings.
    if (find.byKey(const Key('report-screen'), skipOffstage: false).evaluate().isNotEmpty) {
      await tester.pageBack();
      await tester.pumpAndSettle();
    } else {
      await scrollSettingsTo(tester, find.byKey(const Key('report-problem')));
      await tester.tap(find.byKey(const Key('report-problem')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('report-screen')), findsOneWidget);
    expect(fieldText(tester, const Key('report-description')), 'Typed before getting a key');
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('report-category-bug'))).selected, isTrue);
    expect(h.reports.sent, isEmpty);
    await drain(tester);
  });
}
