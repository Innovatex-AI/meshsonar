// Screens for the 0.3.0 fixes: rejected pings counted apart (no Sync for them), rename uploads, server change asks
// first and drops the key, the account link hint and "Get a key on the website".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';

import 'fakes.dart';

final settingsScroll = find
    .descendant(
      of: find.byKey(const Key('settings-list')),
      matching: find.byType(Scrollable),
    )
    .first;

DriveSession ended(String id, {String? label}) => DriveSession(
  id: id,
  startedAt: DateTime.utc(2026, 10, 15, 14),
  endedAt: DateTime.utc(2026, 10, 15, 15),
  label: label,
  channel: '#wardriving',
);

Future<void> openDrives(WidgetTester tester) async {
  await tester.tap(find.text('Drives'));
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'rejected pings show as "N rejected", not "not synced", and do not enable Sync',
    (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      // 5 pings: 3 synced, 2 rejected by the server.
      h.store.seed(
        ended('d1'),
        [for (var i = 0; i < 5; i++) silentPing('p$i')],
        syncedFirst: 3,
        rejectedLast: 2,
      );
      await h.pumpApp(tester);
      await openDrives(tester);

      expect(find.byKey(const ValueKey('rejected-d1')), findsOneWidget);
      expect(find.text('· 2 rejected'), findsOneWidget);
      expect(find.textContaining('not synced'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('unsynced-d1'))).data,
        'Synced',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('sync-d1')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('sync-all')), findsNothing);
      expect(find.text('Everything is uploaded.'), findsOneWidget);

      // One more ping waiting: Sync comes back and the count leaves the rejected ones out.
      h.store.pingsBySession['d1']!.add(silentPing('p5'));
      await h.state.refreshSessions();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('unsynced-d1'))).data,
        '1 not synced',
      );
      expect(find.text('· 2 rejected'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('sync-d1')))
            .onPressed,
        isNotNull,
      );

      // The detail screen agrees.
      await tester.tap(find.byKey(const ValueKey('open-d1')));
      await tester.pumpAndSettle();
      expect(find.text('Sync 1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-sync')));
      await tester.pumpAndSettle();
      expect(find.text('Synced'), findsWidgets);
      expect(find.text('· 2 rejected'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'rename saves into the drive and the next Sync uploads the name',
    (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      h.store.seed(ended('d1'), [silentPing('p0')], syncedFirst: 1);
      await h.pumpApp(tester);
      await openDrives(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('unsynced-d1'))).data,
        'All synced',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('sync-d1')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('menu-d1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rename-d1')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('sent to the server on the next sync'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('rename-field')),
        'Route 3 north',
      );
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();

      expect(h.store.sessionsById['d1']!.label, 'Route 3 north');
      expect(find.text('Route 3 north'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('unsynced-d1'))).data,
        'Name not synced',
      );
      expect(find.text('1 drive name waiting to upload'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sync-d1')));
      await tester.pumpAndSettle();
      expect(h.sync.syncedSessions, ['d1']);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('unsynced-d1'))).data,
        'All synced',
      );
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'changing the server with a key asks first, explains why, and removes the key',
    (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      await h.pumpApp(tester);
      await openSettings(tester);
      expect(find.byKey(const Key('masked-key')), findsOneWidget);

      Future<void> enterUrl(String url) async {
        await tester.scrollUntilVisible(
          find.byKey(const Key('server-url')),
          100,
          scrollable: settingsScroll,
        );
        await tester.tap(find.byKey(const Key('server-url')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('edit-field')), url);
        await tester.tap(find.byKey(const Key('edit-save')));
        await tester.pumpAndSettle();
      }

      // Same URL: nothing to confirm, nothing changes.
      await enterUrl('https://meshsonar.com/');
      expect(find.byKey(const Key('server-change-dialog')), findsNothing);
      expect(h.settings.saved.driverKey, isNotNull);

      // Another address of the same server (0.5.0): no question, the key stays.
      await enterUrl('https://cmh.meshsonar.com');
      expect(find.byKey(const Key('server-change-dialog')), findsNothing);
      expect(h.settings.saved.serverUrl, 'https://cmh.meshsonar.com');
      expect(h.settings.saved.driverKey, isNotNull);
      await enterUrl('https://meshsonar.com');
      expect(find.byKey(const Key('server-change-dialog')), findsNothing);
      expect(h.settings.saved.serverUrl, 'https://meshsonar.com');
      expect(h.settings.saved.driverKey, isNotNull);

      // Not a plain https alias (http, a port, a sub-path): asks like any other server.
      for (final url in [
        'http://meshsonar.com',
        'https://meshsonar.com:8443',
        'https://cmh.meshsonar.com/api',
      ]) {
        await enterUrl(url);
        expect(
          find.byKey(const Key('server-change-dialog')),
          findsOneWidget,
          reason: url,
        );
        await tester.tap(find.byKey(const Key('server-change-cancel')));
        await tester.pumpAndSettle();
        expect(h.state.settings.serverUrl, 'https://meshsonar.com');
        expect(h.settings.saved.driverKey, isNotNull);
      }

      await enterUrl('https://other.example');
      expect(find.byKey(const Key('server-change-dialog')), findsOneWidget);
      expect(
        find.textContaining('only works on the server that issued it'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('server-change-cancel')));
      await tester.pumpAndSettle();
      expect(h.state.settings.serverUrl, 'https://meshsonar.com');
      expect(h.state.settings.driverKey, isNotNull);

      await enterUrl('https://other.example');
      await tester.tap(find.byKey(const Key('server-change-confirm')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.serverUrl, 'https://other.example');
      expect(h.settings.saved.driverKey, isNull);
      expect(h.settings.saved.keyStatus, DriverKeyStatus.none);
      await tester.scrollUntilVisible(
        find.byKey(const Key('key-request')),
        -100,
        scrollable: settingsScroll,
      );
      expect(find.byKey(const Key('key-request')), findsOneWidget);
    },
  );

  testWidgets('without a key, changing the server needs no confirmation', (
    tester,
  ) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettings(tester);
    // With no key, the request form above this tile (now with the privacy-zones link too, 0.8.0) can leave it
    // right at the fold; ensureVisible after the scroll clears it of the bottom navigation bar.
    await tester.scrollUntilVisible(find.byKey(const Key('server-url')), 100, scrollable: settingsScroll);
    await tester.ensureVisible(find.byKey(const Key('server-url')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-url')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('edit-field')),
      'https://other.example',
    );
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-change-dialog')), findsNothing);
    expect(h.settings.saved.serverUrl, 'https://other.example');
  });

  testWidgets(
    'driver key: account hint names <server>/me and the website button opens <server>/me/devices',
    (tester) async {
      useTallScreen(tester);
      final h = Harness()
        ..settings.saved = const Settings(
          serverUrl: 'https://mesh.example.org',
        );
      await h.pumpApp(tester);
      await openSettings(tester);
      final hint = tester
          .widget<Text>(find.byKey(const Key('account-hint')))
          .data!;
      expect(
        hint,
        'Manage your drives and privacy at https://mesh.example.org/me — sign in with the same email you registered with',
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('key-website')),
        100,
        scrollable: settingsScroll,
      );
      expect(find.text('Get a key on the website'), findsOneWidget);
      await tester.tap(find.byKey(const Key('key-website')));
      await tester.pumpAndSettle();
      expect(h.openedUrls, [Uri.parse('https://mesh.example.org/me/devices')]);

      // Also shown once a key is saved.
      h.settings.saved = const Settings(
        serverUrl: 'https://mesh.example.org',
        driverKey: 'k-123456',
        keyStatus: DriverKeyStatus.pending,
      );
      await h.state.init();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('masked-key')),
        -100,
        scrollable: settingsScroll,
      );
      expect(find.byKey(const Key('masked-key')), findsOneWidget);
      expect(find.byKey(const Key('account-hint')), findsOneWidget);
      expect(find.byKey(const Key('key-website')), findsOneWidget);
    },
  );

  testWidgets(
    'driver key: hidden by default, tap to reveal and copy, hides again, auto-hides after 30 s',
    (tester) async {
      useTallScreen(tester);
      final h = Harness()
        ..settings.saved = const Settings(
          serverUrl: 'https://mesh.example.org',
          driverKey: 'k-abcdef123456',
          keyStatus: DriverKeyStatus.approved,
        );
      await h.pumpApp(tester);
      await openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('masked-key')),
        -100,
        scrollable: settingsScroll,
      );
      expect(find.text('k-abcdef123456'), findsNothing);
      expect(find.byKey(const Key('revealed-key')), findsNothing);
      expect(find.byKey(const Key('key-info')), findsOneWidget);

      await tester.tap(find.byKey(const Key('key-reveal')));
      await tester.pump();
      expect(find.byKey(const Key('revealed-key')), findsOneWidget);
      expect(find.text('k-abcdef123456'), findsOneWidget);
      expect(find.byKey(const Key('key-copy')), findsOneWidget);

      await tester.tap(find.byKey(const Key('key-reveal')));
      await tester.pump();
      expect(find.text('k-abcdef123456'), findsNothing);

      await tester.tap(find.byKey(const Key('key-reveal')));
      await tester.pump();
      expect(find.text('k-abcdef123456'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('k-abcdef123456'), findsNothing);
    },
  );
}
