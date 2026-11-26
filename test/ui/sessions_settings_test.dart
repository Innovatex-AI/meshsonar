import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/about_screen.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

DriveSession sess(String id, DateTime start, {String? label}) =>
    DriveSession(id: id, startedAt: start, endedAt: start.add(const Duration(hours: 1)), label: label, channel: '#wardriving');

/// Delete lives in each drive card's menu.
Future<void> tapDelete(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('menu-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('delete-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('drives list: empty state', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('No drives yet'), findsOneWidget);
  });

  testWidgets('drives list newest first; sync, export and delete', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.store.seed(sess('old', DateTime.utc(2026, 10, 1, 14), label: 'Polaris loop'),
        [silentPing('o1'), heardPing('o2', const [Echo(repeater: 'aa')])],
        syncedFirst: 2);
    h.store.seed(sess('new', DateTime.utc(2026, 10, 15, 14)), [
      silentPing('n1'),
      heardPing('n2', const [Echo(repeater: 'bb')]),
      heardPing('n3', const [Echo(repeater: 'cc')]),
      silentPing('n4'),
    ], syncedFirst: 1);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();

    final newY = tester.getTopLeft(find.byKey(const ValueKey('session-new'))).dy;
    final oldY = tester.getTopLeft(find.byKey(const ValueKey('session-old'))).dy;
    expect(newY, lessThan(oldY));
    expect(find.text('Polaris loop'), findsOneWidget);
    expect(find.text('4 pings'), findsOneWidget);
    expect(find.text('Heard 50%'), findsNWidgets(2));
    expect(find.text('3 not synced'), findsOneWidget);
    expect(find.text('All synced'), findsOneWidget);

    // Sync now
    await tester.tap(find.byKey(const ValueKey('sync-new')));
    await tester.pumpAndSettle();
    expect(h.sync.syncedSessions, ['new']);
    expect(find.text('All synced'), findsNWidgets(2));
    expect(find.text('Uploaded 3 new pings.'), findsOneWidget);

    // Export & share (the progress card above the list puts this button under the sync SnackBar: close it first)
    dismissAppToast();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('export-old')));
    await tester.pumpAndSettle();
    expect(h.store.exportCount, 1);
    expect(h.shared.single.path, endsWith('drive-old.json'));

    // Delete: cancel keeps it, confirm removes it
    await tapDelete(tester, 'old');
    expect(find.text('Delete this drive?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.store.sessionsById.containsKey('old'), isTrue);

    await tapDelete(tester, 'old');
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(h.store.sessionsById.containsKey('old'), isFalse);
    expect(find.byKey(const ValueKey('session-old')), findsNothing);
    await drain(tester);
  });

  testWidgets('delete warns when pings are unsynced', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.store.seed(sess('s', DateTime.utc(2026, 10, 15)), [silentPing('a'), silentPing('b')]);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tapDelete(tester, 's');
    expect(find.textContaining('2 of 2 pings have NOT been uploaded'), findsOneWidget);
  });

  testWidgets('sync without a key explains what to do', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.store.seed(sess('s', DateTime.utc(2026, 10, 15)), [silentPing('a')]);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-s')));
    await tester.pumpAndSettle();
    expect(h.sync.syncedSessions, isEmpty);
    expect(find.textContaining('Create one in Settings'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('key request flow: pending -> refresh -> approved; key never shown in full', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    // The name is optional: left blank, the generic one goes out.

    // Build 76: the form is one tap down, on its own page; it closes itself once the key is there.
    await tester.tap(find.byKey(const Key('key-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('key-name')), 'Andy');
    await tester.enterText(find.byKey(const Key('key-callsign')), 'KD8XYZ');
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(h.client.lastRequest, {'name': 'Andy', 'callsign': 'KD8XYZ', 'email': null});
    expect(find.text('Not confirmed yet'), findsOneWidget);
    expect(h.settings.saved.driverKey, 'secretkey-abcdef-1234');
    expect(h.settings.saved.keyStatus, DriverKeyStatus.pending);
    expect(find.textContaining('secretkey'), findsNothing);
    expect(find.text('Driver key: ••••1234'), findsOneWidget);

    h.client.statusResult = (status: DriverKeyStatus.approved, display: 'KD8XYZ');
    await tester.tap(find.byKey(const Key('key-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Ready to upload'), findsOneWidget);
    expect(h.settings.saved.keyStatus, DriverKeyStatus.approved);

    for (final st in [DriverKeyStatus.rejected, DriverKeyStatus.revoked]) {
      h.client.statusResult = (status: st, display: 'KD8XYZ');
      await tester.tap(find.byKey(const Key('key-refresh')));
      await tester.pumpAndSettle();
      expect(find.text(st == DriverKeyStatus.rejected ? 'Turned down' : 'Switched off'), findsOneWidget);
    }
  });

  testWidgets('key request failure shows a plain error', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    h.client.requestError = const CmatException('', status: 503);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('key-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('key-name')), 'Andy');
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The server had a problem (503)'), findsOneWidget);
    expect(h.settings.saved.driverKey, isNull);
  });

  testWidgets('settings persist: server URL, channel, interval, antenna, auto-sync', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    // Build 76: the server URL is on Account > Server (advanced); its row on the first level names the server.
    expect(find.text('https://meshsonar.com'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('page-account-advanced-caption'))).data, 'meshsonar.com');
    await showSetting(tester, 'server-url');
    expect(find.text('https://meshsonar.com'), findsOneWidget);
    // Back on the first level: scroll the channel row in rather than assuming it fits on the first screen.
    await showSetting(tester, 'channel');
    expect(find.text('#wardriving'), findsOneWidget);

    Future<void> edit(String key, String value) async {
      await showSetting(tester, key); // opens the page the row is on (server-url), or goes back to the first level (channel)
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('edit-field')), value);
      await tester.tap(find.byKey(const Key('edit-save')));
      await tester.pumpAndSettle();
    }

    await edit('server-url', 'not a url');
    expect(find.text('Enter a full address starting with https://'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('edit-field')), 'https://mesh.example.org/');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.serverUrl, 'https://mesh.example.org');
    expect(h.state.client.baseUrl, Uri.parse('https://mesh.example.org'));

    await edit('channel', 'cmh-drive');
    expect(h.settings.saved.channel, '#cmh-drive');
    Future<void> slide(String key, double index) async {
      await showSetting(tester, key);
      final sl = tester.widget<Slider>(find.byKey(Key(key)));
      sl.onChanged!(index);
      sl.onChangeEnd!(index);
      await tester.pumpAndSettle();
    }

    await slide('interval-slider', 7); // 10, 15, … → 45
    expect(h.settings.saved.intervalSec, 45);
    await slide('min-distance-slider', 8); // … 200, 250
    expect(h.settings.saved.minDistanceM, 250);
    // 0.4.0: the antenna is set per radio (spec m1-app-0.4.0 §4), edited from its row in Settings → Antenna.
    await showSetting(tester, 'antenna-profile-abcdef0123');
    await tester.tap(find.byKey(const Key('antenna-profile-abcdef0123')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mount-roofMagMount')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('antenna-gain-unknown')));
    await tester.tap(find.byKey(const Key('antenna-gain-unknown'))); // the seeded profile's gain is "Don't know"
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('antenna-gain-field')), '5.8');
    await tester.enterText(find.byKey(const Key('antenna-height-field')), '1.6');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('antenna-save')));
    await tester.tap(find.byKey(const Key('antenna-save')));
    await tester.pumpAndSettle();
    final antenna = h.settings.saved.antennaProfiles['abcdef0123']!.toAntenna();
    expect(antenna.type, 'external');
    expect(antenna.gainDbi, 5.8);
    expect(antenna.heightM, 1.6);

    await showSetting(tester, 'auto-sync'); // Driving > Uploads
    await tester.tap(find.byKey(const Key('auto-sync')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.autoSync, isFalse);

    // A fresh app on the same store sees the saved values.
    final h2Settings = h.settings.saved;
    final h2 = Harness();
    h2.settings.saved = h2Settings;
    await h2.state.init();
    expect(h2.state.settings.channel, '#cmh-drive');
    expect(h2.state.settings.antennaProfiles['abcdef0123']!.gainDbi, 5.8);
    expect(h2.state.settings.autoSync, isFalse);
  });

  testWidgets('about screen shows MIT licence and notices', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    // About is the last section: scroll to it, not a fixed drag.
    await showSetting(tester, 'about', step: 300);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('about')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MIT License'), findsWidgets);
    await tester.tap(find.byKey(const Key('about-credits'))); // build 76: the credits open on a tap
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('MeshCore Open'), 200,
        scrollable: find.descendant(of: find.byType(AboutScreen), matching: find.byType(Scrollable)).first);
    expect(find.text('MeshCore Open'), findsOneWidget);
  });
}
