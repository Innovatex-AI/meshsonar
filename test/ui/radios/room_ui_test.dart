import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/room_session.dart';
import 'package:meshsonar/ui/radios/rooms/room_screen.dart';

import '../../support/repeater_admin_fake.dart';
import 'admin_rig.dart';

Future<({FakeAdminRepeater room, AdminFakeTransport radio, RoomController c})> roomRig(WidgetTester tester, {bool readOnlyGuest = false}) async {
  final out = await tester.runAsync(() async {
    final room = FakeAdminRepeater(key: repKey(), name: 'Valley Room', role: 'room', adminPassword: 'adminpw', guestPassword: 'roompw');
    room.roomPosts.add((authorHex: 'cd' * 32, text: 'welcome to the valley', ts: 1700000100));
    if (readOnlyGuest) room.prefs['allow.read.only'] = 'on';
    final radio = AdminFakeTransport({room.keyHex: room});
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 250), messagePollInterval: const Duration(milliseconds: 20));
    final info = await link.start();
    final session = LinkRadioSession(link, info: info);
    final c = RoomController(room: RoomSession(radio: session, keyHex: room.keyHex, name: room.name), title: 'Valley Room', nameForPrefix: (p) => p == 'cdcdcdcd' ? 'Hill Walker' : null);
    return (room: room, radio: radio, c: c, link: link);
  });
  addTearDown(() async => tester.runAsync(() => out!.link.close()));
  return (room: out!.room, radio: out.radio, c: out.c);
}

Future<void> endRoomTest(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  testWidgets('join with the room password, read the pushed post with the author\'s name, post, and see your own post come back', (tester) async {
    sizeScreen(tester);
    final r = await roomRig(tester);
    await tester.pumpWidget(app(RoomScreen(controller: r.c)));
    expect(find.byKey(const Key('room-login')), findsOneWidget);
    expect(find.textContaining('never sent to MeshSonar'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('room-login-go'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('room-password')), 'wrong');
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-login-go')));
    await pumpUntilFound(tester, find.byKey(const Key('room-login-error')));
    expect(find.textContaining('No answer'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('room-password')), 'roompw');
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-login-go')));
    await pumpUntilFound(tester, find.text('welcome to the valley'));
    expect(find.textContaining('Hill Walker'), findsOneWidget);
    expect(find.byKey(const Key('room-compose')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('room-compose')), 'hello from the truck');
    await tester.tap(find.byKey(const Key('room-send')));
    await pumpUntilFound(tester, find.textContaining('You '));
    expect(find.textContaining('You '), findsOneWidget);
    expect(r.radio.sentFrames.where((f) => f[0] == 2 && f[1] == 0).length, 1);
    await endRoomTest(tester);
  });

  testWidgets('a read-only guest reads but the composer is replaced by the reason', (tester) async {
    sizeScreen(tester);
    final r = await roomRig(tester, readOnlyGuest: true);
    await tester.pumpWidget(app(RoomScreen(controller: r.c)));
    await tester.enterText(find.byKey(const Key('room-password')), 'anything');
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-login-go')));
    await pumpUntilFound(tester, find.text('welcome to the valley'));
    expect(find.byKey(const Key('room-readonly')), findsOneWidget);
    expect(find.byKey(const Key('room-compose')), findsNothing);
    await endRoomTest(tester);
  });

  for (final cfg in [(w: 390.0, h: 844.0, s: 1.0, d: false), (w: 820.0, h: 1180.0, s: 1.0, d: true), (w: 390.0, h: 3000.0, s: 2.5, d: true)]) {
    testWidgets('room screen lays out at ${cfg.w.toInt()}x${cfg.h.toInt()} text ${cfg.s}x ${cfg.d ? 'dark' : 'light'}', (tester) async {
      sizeScreen(tester, w: cfg.w, h: cfg.h);
      final r = await roomRig(tester);
      await tester.pumpWidget(app(RoomScreen(controller: r.c), dark: cfg.d, textScale: cfg.s));
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byKey(const Key('room-password')), 'roompw');
      await tester.pump();
      await tester.tap(find.byKey(const Key('room-login-go')));
      await pumpUntilFound(tester, find.text('welcome to the valley'));
      expect(tester.takeException(), isNull);
      final s = tester.getSize(find.byKey(const Key('room-send')));
      expect(s.width, greaterThanOrEqualTo(48));
      await endRoomTest(tester);
    });
  }
}
