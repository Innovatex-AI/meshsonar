// Build 77, redesign round 5 (More, Settings): the pieces not covered next to their own rows elsewhere. One Upload choice
// kept in the two old settings (old files read the same), the "set up" note for a phone whose driver key is not made
// yet, More > Radio without "More tools", one name for My radio's settings, "Change radio settings", and What is shared
// saying where drive data goes once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/settings/data_sharing.dart' show contextDestinationLine;
import 'package:meshsonar/ui/settings/drives_section.dart';

import '../fakes.dart';
import '../settings_test_kit.dart';

Finder _inMore(String key) => find.descendant(of: find.byKey(const Key('more-list')), matching: find.byKey(Key(key)));

void main() {
  test('UploadWhen reads the two settings of every older build and writes them back', () {
    expect(UploadWhen.of(const Settings(autoSync: true, syncDuringDrive: true)), UploadWhen.whileDriving);
    expect(UploadWhen.of(const Settings(autoSync: true, syncDuringDrive: false)), UploadWhen.atEnd);
    expect(UploadWhen.of(const Settings(autoSync: false, syncDuringDrive: true)), UploadWhen.manual);
    expect(UploadWhen.of(const Settings(autoSync: false, syncDuringDrive: false)), UploadWhen.manual);
    for (final w in UploadWhen.values) {
      expect(UploadWhen.of(w.apply(const Settings())), w);
      final json = w.apply(const Settings()).toJson();
      expect(UploadWhen.of(Settings.fromJson(json)), w, reason: 'saved and read back');
    }
    expect(UploadWhen.manual.label, 'Only when I tap Upload', reason: 'decision 9: Upload, not Sync');
  });

  testWidgets('a phone whose driver key is not made yet says so on More > Drives and in Uploads (O5)', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.client.requestError = Exception('offline'); // the automatic key cannot be made (no network at first launch)
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.hasKey, isFalse);
    expect(uploadSetupNote(h.state), 'Will upload when this phone is set up.');
    await tapShellTab(tester, 'More');
    await tester.pumpAndSettle();
    expect(find.descendant(of: _inMore('more-drives'), matching: find.text('Will upload when this phone is set up.')), findsOneWidget);

    // A person who removed their key (autoKey off) is not "being set up": no note.
    await h.state.updateSettings(h.state.settings.copyWith(autoKey: false));
    await tester.pumpAndSettle();
    expect(uploadSetupNote(h.state), isNull);
    expect(find.descendant(of: _inMore('more-drives'), matching: find.text('Your saved drives and reports')), findsOneWidget);
  });

  testWidgets('More > Radio: "My radio\'s settings" (one name), no "More tools" group; the page says "Change radio settings"', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connectSimulator();
    await tester.pumpAndSettle();
    while (find.byKey(const Key('app-sheet')).evaluate().isNotEmpty) {
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
    await tapShellTab(tester, 'More');
    await tester.tap(find.byKey(const Key('more-radio')));
    await tester.pumpAndSettle();
    expect(find.text('More tools'), findsNothing);
    expect(find.byKey(const Key('more-noiseFloor')), findsNothing);
    expect(find.byKey(const Key('more-telemetry')), findsNothing);
    expect(find.text('Check my radio\'s settings'), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('more-radioSettings')), matching: find.text('My radio\'s settings')), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-radioSettings')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('My radio\'s settings')), findsOneWidget);
    expect(find.text('Change radio settings'), findsOneWidget);
    expect(find.text('Change name, position or frequency'), findsNothing);
  });

  testWidgets('Settings > Radio names the same screen "My radio\'s settings"', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await showSetting(tester, 'radio-tab-link');
    expect(find.descendant(of: find.byKey(const Key('radio-tab-link')), matching: find.text('My radio\'s settings')), findsOneWidget);
    expect(find.text('Radio details'), findsNothing);
  });

  testWidgets('What is shared says where drive data goes once, at the top; the rows keep one line of their own (S8)', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await openSettingsPageRow(tester, 'sharing');
    final where = contextDestinationLine(h.state);
    expect(find.descendant(of: find.byKey(const Key('settings-page-help')), matching: find.textContaining(where)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('settings-page-sharing')), matching: find.textContaining(where)), findsOneWidget,
        reason: 'said once on the page, not under every switch');
  });
}
