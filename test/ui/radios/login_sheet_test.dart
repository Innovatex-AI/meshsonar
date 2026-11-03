// The login sheet's states (chat plan 4.9): one password field, no Admin/Guest control, factory-password warning, and the
// failure states that must look different (wrong password vs no reply vs radio busy). Goldens pin the layout of each state.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/admin_password_vault.dart';
import 'package:meshsonar/radio/login_outcome.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/ui/radios/repeater_admin/login_sheet.dart';
import 'package:meshsonar/ui/theme.dart';

LoginSheetModel model(Future<LoginOutcome> Function(String, {required bool guest, required LoginRoute route}) attempt,
        {int Function()? ahead, AdminPasswordVault? vault, VoidCallback? onCancel}) =>
    LoginSheetModel(title: 'INNO-OB-2', keyHex: 'ab' * 32, routeLine: 'Via 3 repeaters · Strong', attempt: attempt, queueAhead: ahead ?? () => 0, vault: vault, onCancel: onCancel);

Widget host(LoginSheetModel m, {bool dark = false, double scale = 1.0}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
      darkTheme: meshSonarTheme(Brightness.dark).copyWith(platform: TargetPlatform.iOS),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(body: LoginSheet(model: m, popOnSuccess: false)),
    );

Future<void> size(WidgetTester t, [Size s = const Size(390, 844)]) async {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Future<void> typeAndGo(WidgetTester t, String pw) async {
  await t.enterText(find.byKey(const Key('login-password')), pw);
  await t.pump();
  await t.tap(find.byKey(const Key('login-go')));
  await t.pump();
}

void main() {
  testWidgets('one password field, a guest button, and no Admin/Guest switch', (t) async {
    await size(t);
    await t.pumpWidget(host(model((pw, {required guest, required route}) async => const LoginOutcome(LoginKind.admin))));
    await t.pump();
    expect(find.byKey(const Key('login-password')), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsOneWidget);
    expect(find.byKey(const Key('login-guest')), findsOneWidget);
    expect(find.text('Log in as guest'), findsOneWidget);
    expect(find.byType(CupertinoSlidingSegmentedControl<LoginRoute>), findsNothing, reason: 'route choice is hidden under More options');
    expect(find.textContaining('Admin'), findsNothing);
    expect(find.byKey(const Key('login-defaults')), findsOneWidget);
    expect(find.textContaining('"password" for admin and "hello" for guests'), findsOneWidget);
    expect(t.widget<CupertinoButton>(find.byKey(const Key('login-go'))).onPressed, isNull, reason: 'nothing typed yet');
    expect(find.text('Cancel'), findsOneWidget);
    expect(t.getTopLeft(find.text('Cancel')).dx, lessThan(t.getTopLeft(find.text('Log in').first).dx), reason: 'Cancel is leading');
    await t.tap(find.byKey(const Key('login-more')));
    await t.pump();
    expect(find.byKey(const Key('login-route')), findsOneWidget);
    expect(find.text('Saved route'), findsOneWidget);
    expect(find.text('Search for it'), findsOneWidget);
  });

  testWidgets('factory password warning appears for "password" and "hello" only', (t) async {
    await size(t);
    await t.pumpWidget(host(model((pw, {required guest, required route}) async => const LoginOutcome(LoginKind.admin))));
    await t.enterText(find.byKey(const Key('login-password')), 'password');
    await t.pump();
    expect(find.byKey(const Key('login-factory')), findsOneWidget);
    expect(find.text('Factory password. Anyone nearby can log in. Change it after you sign in.'), findsOneWidget);
    await t.enterText(find.byKey(const Key('login-password')), 'hello');
    await t.pump();
    expect(find.byKey(const Key('login-factory')), findsOneWidget);
    await t.enterText(find.byKey(const Key('login-password')), 'hunter22');
    await t.pump();
    expect(find.byKey(const Key('login-factory')), findsNothing);
  });

  testWidgets('wrong password and no reply are visibly different', (t) async {
    await size(t);
    var kind = LoginKind.wrongPassword;
    await t.pumpWidget(host(model((pw, {required guest, required route}) async =>
        kind == LoginKind.wrongPassword ? const LoginOutcome(LoginKind.wrongPassword, 'That password was not accepted.') : const LoginOutcome(LoginKind.noReply, 'x', 24))));
    await typeAndGo(t, 'nope');
    await t.pump();
    expect(find.byKey(const Key('login-wrong')), findsOneWidget);
    expect(find.text('That password was not accepted.'), findsOneWidget);
    expect(find.byKey(const Key('login-noreply')), findsNothing);
    expect(find.byKey(const Key('login-search')), findsNothing, reason: 'a node that answered needs no wider search');

    kind = LoginKind.noReply;
    await t.tap(find.byKey(const Key('login-go')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('login-noreply')), findsOneWidget);
    expect(find.byKey(const Key('login-wrong')), findsNothing);
    expect(find.textContaining('No reply after 24 s'), findsOneWidget);
    expect(find.textContaining('Wrong password'), findsOneWidget, reason: 'the no-reply text always lists wrong password as a cause');
    expect(find.byKey(const Key('login-search')), findsOneWidget);
    expect(find.byKey(const Key('login-retry')), findsOneWidget);
  });

  testWidgets('radio busy shows the queue position, and the button becomes Cancel login while waiting', (t) async {
    await size(t);
    final c = Completer<LoginOutcome>();
    var cancelled = 0;
    await t.pumpWidget(host(model((pw, {required guest, required route}) => c.future, ahead: () => 1, onCancel: () => cancelled++)));
    await typeAndGo(t, 'secret');
    await t.pump();
    expect(find.byKey(const Key('login-busy')), findsOneWidget);
    expect(find.textContaining('busy with another request (waiting 1 of 2)'), findsOneWidget);
    expect(find.text('Cancel login'), findsOneWidget);
    await t.tap(find.byKey(const Key('login-go')));
    await t.pump();
    expect(cancelled, 1);
    expect(find.text('Log in'), findsWidgets);
    c.complete(const LoginOutcome(LoginKind.admin));
    await t.pump();
  });

  testWidgets('success says who you are signed in as, guest is read only', (t) async {
    await size(t);
    await t.pumpWidget(host(model((pw, {required guest, required route}) async => guest ? const LoginOutcome(LoginKind.guest) : const LoginOutcome(LoginKind.admin))));
    await typeAndGo(t, 'secret');
    await t.pump();
    expect(find.text('Signed in as Admin'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(model((pw, {required guest, required route}) async => const LoginOutcome(LoginKind.guest))));
    await t.tap(find.byKey(const Key('login-guest')));
    await t.pump();
    await t.pump();
    expect(find.textContaining('Signed in as Guest'), findsOneWidget);
    expect(find.textContaining('read only'), findsOneWidget);
  });

  testWidgets('remember and Face ID switches appear only with a store; Face ID only when remembering', (t) async {
    await size(t);
    final v = AdminPasswordVault(store: InMemorySecretStore(), authenticate: () async => true);
    final m = model((pw, {required guest, required route}) async => const LoginOutcome(LoginKind.admin), vault: v);
    await t.runAsync(m.load);
    await t.pumpWidget(host(m));
    await t.pump();
    expect(find.byKey(const Key('login-remember')), findsOneWidget);
    expect(find.byKey(const Key('login-faceid')), findsNothing);
    await t.runAsync(() => m.setRemember(true));
    await t.pump();
    expect(find.byKey(const Key('login-faceid')), findsOneWidget);
    await t.runAsync(() => m.setRemember(false));
    await t.pump();
    expect(find.byKey(const Key('login-faceid')), findsNothing);
  });

  // Layout goldens of the states (test font: structure and colour, not glyph shapes; SF Pro is checked on the simulator).
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    for (final st in ['idle', 'wrong', 'noreply', 'busy', 'success']) {
      testWidgets('golden $st $mode', (t) async {
        await size(t);
        final c = Completer<LoginOutcome>();
        final m = model((pw, {required guest, required route}) => switch (st) {
              'wrong' => Future.value(const LoginOutcome(LoginKind.wrongPassword)),
              'noreply' => Future.value(const LoginOutcome(LoginKind.noReply, '', 24)),
              'success' => Future.value(const LoginOutcome(LoginKind.admin)),
              _ => c.future,
            }, ahead: st == 'busy' ? () => 1 : null);
        await t.pumpWidget(host(m, dark: dark));
        if (st != 'idle') await typeAndGo(t, 'password');
        await t.pump();
        await t.pump();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/login_${st}_$mode.png'));
        c.complete(const LoginOutcome(LoginKind.other));
        await t.pump();
      });
    }
  }

  testWidgets('AX3 text scale: nothing overflows and the pinned button stays reachable', (t) async {
    await size(t, const Size(375, 667));
    final m = model((pw, {required guest, required route}) async => const LoginOutcome(LoginKind.noReply, '', 24));
    await t.pumpWidget(host(m, scale: 2.35));
    await t.dragUntilVisible(find.byKey(const Key('login-password')), find.byType(ListView), const Offset(0, -80));
    await typeAndGo(t, 'password');
    await t.pump();
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('login-go')).hitTestable(), findsOneWidget);
  });
}
