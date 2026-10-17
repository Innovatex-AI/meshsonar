import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

import 'fakes.dart';

/// A driver key created on the website (/me/devices) can be pasted into the app.
void main() {
  Future<Harness> openSettings(WidgetTester tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('key-have')));
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('pasting a website key checks it with the server, then saves it', (tester) async {
    final h = await openSettings(tester);
    expect(find.byKey(const Key('key-paste')), findsOneWidget);
    expect(find.byKey(const Key('key-request')), findsOneWidget, reason: 'requesting a new key still works');

    h.client.statusResult = (status: DriverKeyStatus.approved, display: 'KE4BFI');
    await tester.enterText(find.byKey(const Key('key-paste')), '  ms_websiteKey0123456789abcdefghijklmnopqrstuv9876  ');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();

    expect(h.client.lastStatusKey, 'ms_websiteKey0123456789abcdefghijklmnopqrstuv9876', reason: 'key is trimmed');
    expect(h.settings.saved.driverKey, 'ms_websiteKey0123456789abcdefghijklmnopqrstuv9876');
    expect(h.settings.saved.keyStatus, DriverKeyStatus.approved);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Driver key: ••••9876'), findsOneWidget);
    expect(find.textContaining('websiteKey'), findsNothing, reason: 'the full key is never shown');
    expect(h.client.requestCalls, 0);
  });

  testWidgets('a pending website key is saved and shows pending', (tester) async {
    final h = await openSettings(tester);
    h.client.statusResult = (status: DriverKeyStatus.pending, display: 'KE4BFI');
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_pendingkey000000000000000000000000000000001');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.keyStatus, DriverKeyStatus.pending);
    expect(find.text('Pending approval'), findsOneWidget);
  });

  testWidgets('an empty paste asks for the key and calls nothing', (tester) async {
    final h = await openSettings(tester);
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(find.text('Paste the driver key from the website.'), findsOneWidget);
    expect(h.client.statusCalls, 0);
    expect(h.settings.saved.driverKey, isNull);
  });

  testWidgets('a key the server does not know is not saved', (tester) async {
    final h = await openSettings(tester);
    h.client.statusError = const CmatException('', status: 401);
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_typo');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(find.textContaining("doesn't recognise that key"), findsOneWidget);
    expect(h.settings.saved.driverKey, isNull);
    expect(find.byKey(const Key('key-paste')), findsOneWidget, reason: 'still on the entry form');
  });

  testWidgets('a server error while checking shows a plain error and saves nothing', (tester) async {
    final h = await openSettings(tester);
    h.client.statusError = const CmatException('', status: 503);
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_somekey');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The server had a problem (503)'), findsOneWidget);
    expect(h.settings.saved.driverKey, isNull);
  });

  testWidgets('the error shows next to the paste field, not above the request form', (tester) async {
    final h = await openSettings(tester);
    h.client.statusError = const CmatException('', status: 401);
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_typo');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    final err = find.byKey(const Key('key-paste-error'));
    expect(err, findsOneWidget);
    expect(tester.getTopLeft(err).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('key-paste'))).dy));
  });

  for (final dead in [DriverKeyStatus.rejected, DriverKeyStatus.revoked]) {
    testWidgets('a ${dead.name} key from the website is not saved', (tester) async {
      final h = await openSettings(tester);
      h.client.statusResult = (status: dead, display: 'KE4BFI');
      await tester.enterText(find.byKey(const Key('key-paste')), 'ms_deadkey');
      await tester.tap(find.byKey(const Key('key-use')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.driverKey, isNull);
      expect(find.textContaining('That key was ${dead.name}'), findsOneWidget);
    });
  }

  testWidgets('a key with a line break in the middle is cleaned before it is checked and saved', (tester) async {
    final h = await openSettings(tester);
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_abcdefghij\nklmnop qrst\tuvwx');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(h.client.lastStatusKey, 'ms_abcdefghijklmnopqrstuvwx');
    expect(h.settings.saved.driverKey, 'ms_abcdefghijklmnopqrstuvwx');
  });

  testWidgets('after saving, removing the key brings back an empty, folded form (the key never reappears)', (tester) async {
    final h = await openSettings(tester);
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_secretfragmentXYZ1234');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.driverKey, 'ms_secretfragmentXYZ1234');
    await tester.tap(find.byKey(const Key('forget-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(h.settings.saved.driverKey, isNull);
    expect(find.byKey(const Key('key-paste')), findsNothing, reason: 'paste field is folded away again');
    expect(find.textContaining('secretfragment'), findsNothing);
  });

  testWidgets('if the server changes while the key is being checked, nothing is saved', (tester) async {
    final h = await openSettings(tester);
    final first = h.client;
    first.statusGate = Completer<void>();
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_racekey');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pump();
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://other.example.org'));
    first.statusGate!.complete();
    await tester.pumpAndSettle();
    expect(h.settings.saved.driverKey, isNull);
    expect(find.textContaining('The server changed while the key was being checked'), findsOneWidget);
  });
}
