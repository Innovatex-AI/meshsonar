// Shared by the repeater admin widget tests: a real companion link over the fake radio and repeater, a real admin session,
// and the controller the screens use.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show RadioPreset;
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/repeater_admin.dart';
import 'package:meshsonar/ui/radios/repeater_admin/admin_controller.dart';
import 'package:meshsonar/ui/radios/repeater_admin/repeater_admin_screen.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../support/repeater_admin_fake.dart';

const preset = RadioPreset(name: 'USA/Canada (Recommended)', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);

Uint8List repKey() => Uint8List.fromList(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff)..[0] = 0xdf);

class AdminRig {
  final FakeAdminRepeater rep;
  final AdminFakeTransport radio;
  final MeshCoreCompanionLink link;
  final RepeaterAdminController controller;
  AdminRig(this.rep, this.radio, this.link, this.controller);
}

Future<AdminRig> makeRig({bool room = false, void Function(FakeAdminRepeater)? setup, RadioPreset? regionPreset = preset}) async {
  final rep = FakeAdminRepeater(key: repKey(), role: room ? 'room' : 'repeater', name: room ? 'Valley Room' : 'INNO-OB-2');
  setup?.call(rep);
  final radio = AdminFakeTransport({rep.keyHex: rep});
  final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 250));
  await link.start();
  final session = RepeaterAdminSession(
      radio: link, keyHex: rep.keyHex, nodeType: room ? 3 : 2, delay: (d) async {}, limits: const AdminLimits(writeGap: Duration.zero, cliMax: 1000));
  final names = {'1bcee248': 'Hilltop North', '1fd4038f': 'Water Tower'};
  final controller = RepeaterAdminController(
    session: session,
    title: rep.name,
    isRoom: room,
    regionPreset: regionPreset,
    nameForPrefix: (p) => names[p] ?? (radio.keyHex.startsWith(p) ? 'My Companion' : null),
    fullKeyForPrefix: (p) => p == 'a9b1acd3a408' ? 'a9b1acd3a408${'11' * 26}' : null,
    lastAdvertEpoch: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600,
  );
  return AdminRig(rep, radio, link, controller);
}

/// Lets real timers and microtasks run (the link and the fake repeater use them), then pumps a frame.
Future<void> settle(WidgetTester tester, {int ms = 40}) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump(const Duration(milliseconds: 50));
}

/// A few frames, enough for dialogs and sheets to open or close; never waits for spinners to stop (pumpAndSettle would).
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done, {int rounds = 150}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await settle(tester, ms: 10);
  }
}

Future<void> pumpUntilFound(WidgetTester tester, Finder f, {int rounds = 150}) => pumpUntil(tester, () => f.evaluate().isNotEmpty, rounds: rounds);

void sizeScreen(WidgetTester tester, {double w = 390, double h = 844}) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget app(Widget home, {bool dark = false, double textScale = 1.0}) => MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      darkTheme: meshSonarTheme(Brightness.dark),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
      home: home,
    );

AdminRig? _lastRig;

/// A widget test that always ends cleanly: waits for work still in flight on the real timers, tears the tree down and lets
/// snack bar timers run out.
void adminTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    _lastRig = null;
    await body(tester);
    final rig = _lastRig;
    if (rig != null) {
      await pumpUntil(tester, () => !rig.controller.usingAirtime && !rig.controller.loadingOverview && !rig.controller.loadingSettings && !rig.controller.loadingNeighbours && !rig.controller.loadingAcl && !rig.controller.loadingRegions, rounds: 400);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}

Future<AdminRig> openAdmin(WidgetTester tester,
    {bool login = true,
    String password = 'secret',
    bool room = false,
    double w = 390,
    double h = 3000,
    bool dark = false,
    double textScale = 1.0,
    void Function(FakeAdminRepeater)? setup}) async {
  sizeScreen(tester, w: w, h: h);
  final rig = (await tester.runAsync(() => makeRig(room: room, setup: setup)))!;
  _lastRig = rig;
  addTearDown(() async {
    await tester.runAsync(() => rig.link.close());
  });
  await tester.pumpWidget(app(RepeaterAdminScreen(controller: rig.controller, keyHex: rig.rep.keyHex, ownsController: false), dark: dark, textScale: textScale));
  await tester.pump();
  if (login) {
    await tester.enterText(find.byKey(const Key('admin-password')), password);
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin-login-go')));
    await pumpUntil(tester, () => rig.controller.stage == AdminStage.ready);
    await pumpUntil(tester, () => !rig.controller.loadingOverview);
    await tester.pump();
  }
  return rig;
}
