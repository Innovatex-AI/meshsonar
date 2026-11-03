// Room join flow (chat plan 4.2 / 4.9): the bar offers [Log in to post], the login sheet joins, the bar and the list row show
// the joined state. The old stand-alone room screen is gone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/login_outcome.dart';
import 'package:meshsonar/ui/design/drive_guard.dart';
import 'package:meshsonar/ui/radios/repeater_admin/login_sheet.dart';
import 'package:meshsonar/ui/radios/rooms/room_join_bar.dart';
import 'package:meshsonar/ui/radios/rooms/room_joins.dart';
import 'package:meshsonar/ui/theme.dart';

const key = 'cd12' '00000000000000000000000000000000000000000000000000000000ab';

LoginSheetModel roomModel({RemoteLogin? grant, LoginKind fail = LoginKind.admin}) => LoginSheetModel(
      title: 'Valley Room',
      keyHex: key,
      isRoom: true,
      attempt: (pw, {required guest, required route}) async {
        if (pw == 'wrong') return const LoginOutcome(LoginKind.wrongPassword);
        final r = grant ?? const RemoteLogin(isAdmin: false, aclPermissions: 2);
        RoomJoins.set(key, r);
        return LoginOutcome(r.isAdmin ? LoginKind.admin : LoginKind.guest);
      },
    );

Widget app(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS), home: Scaffold(body: child));

void main() {
  setUp(() {
    RoomJoins.clear();
    DriveGuard.instance.reset();
  });

  testWidgets('not joined: [Log in to post]; wrong password keeps the sheet; the right one joins and the bar says Joined', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(RoomJoinBar(keyHex: key, name: 'Valley Room', modelBuilder: (_) => roomModel())));
    expect(find.byKey(const Key('room-bar-login')), findsOneWidget);
    expect(find.text('Log in to post'), findsOneWidget);
    await t.tap(find.byKey(const Key('room-log-in')));
    await t.pump(const Duration(milliseconds: 700));
    await t.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('login-sheet')), findsOneWidget);
    expect(find.text('Enter the room password.'), findsOneWidget);
    await t.enterText(find.byKey(const Key('login-password')), 'wrong');
    await t.pump();
    await t.tap(find.byKey(const Key('login-go')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('login-wrong')), findsOneWidget);
    expect(RoomJoins.of(key), isNull);
    await t.enterText(find.byKey(const Key('login-password')), 'roompw');
    await t.pump();
    await t.tap(find.byKey(const Key('login-go')));
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    await t.pump(const Duration(milliseconds: 700));
    expect(RoomJoins.of(key), isNotNull);
    expect(find.byKey(const Key('login-sheet')), findsNothing, reason: 'the sheet closes on success');
    expect(find.byKey(const Key('room-joined')), findsOneWidget);
    expect(find.text('Joined'), findsOneWidget);
    expect(find.byKey(const Key('room-manage-chat')), findsNothing, reason: 'Manage is for admins');
  });

  testWidgets('joined as admin shows Manage; read-only guest says so', (t) async {
    RoomJoins.set(key, const RemoteLogin(isAdmin: true));
    await t.pumpWidget(app(RoomJoinBar(keyHex: key, name: 'Valley Room')));
    expect(find.text('Joined as admin'), findsOneWidget);
    expect(find.byKey(const Key('room-manage-chat')), findsOneWidget);
    RoomJoins.set(key, const RemoteLogin(isAdmin: false, aclPermissions: 1));
    await t.pump();
    expect(find.text('Joined, read only'), findsOneWidget);
    expect(find.byKey(const Key('room-manage-chat')), findsNothing);
  });

  test('RoomJoins labels and change notifications', () {
    var n = 0;
    void l() => n++;
    RoomJoins.changes.addListener(l);
    expect(RoomJoins.label(key), isNull);
    RoomJoins.set(key.toUpperCase(), const RemoteLogin(isAdmin: false, aclPermissions: 2));
    expect(RoomJoins.label(key), 'Joined');
    RoomJoins.clear();
    RoomJoins.changes.removeListener(l);
    expect(n, 2);
    expect(radioIdOf(null), 'unknown');
    expect(radioIdOf('AB' * 32), 'ab' * 6);
  });
}
