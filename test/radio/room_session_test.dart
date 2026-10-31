import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/room_session.dart';

import '../support/repeater_admin_fake.dart';

Uint8List key(int n) => Uint8List.fromList(List<int>.generate(32, (i) => (n * 11 + i * 5) & 0xff)..[0] = 0xab);

Future<({FakeAdminRepeater room, AdminFakeTransport radio, LinkRadioSession session, RoomSession rs})> rig({String pw = 'roompw', Duration poll = const Duration(milliseconds: 20)}) async {
  final room = FakeAdminRepeater(key: key(3), name: 'Valley Room', role: 'room', adminPassword: 'adminpw', guestPassword: pw);
  room.roomPosts.add((authorHex: 'cd' * 32, text: 'welcome to the valley', ts: 1700000100));
  final radio = AdminFakeTransport({room.keyHex: room});
  final link = MeshCoreCompanionLink(radio,
      timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 250), messagePollInterval: poll);
  final info = await link.start();
  final session = LinkRadioSession(link, info: info);
  final rs = RoomSession(radio: session, keyHex: room.keyHex, name: room.name);
  return (room: room, radio: radio, session: session, rs: rs);
}

void main() {
  test('login pushes the stored posts as signed text (txt_type 2); they land in posts, once each', () async {
    final r = await rig();
    // a guest login on a room with a room password = read and write
    final login = await r.rs.login('roompw');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(login.isAdmin, isFalse);
    expect(r.rs.loggedIn, isTrue);
    expect(r.rs.posts.length, 1);
    expect(r.rs.posts.single.text, 'welcome to the valley');
    expect(r.rs.posts.single.authorPrefixHex, 'cdcdcdcd');
    expect(r.rs.posts.single.mine, isFalse);
    expect(r.rs.unread, 1);
    r.rs.markRead();
    expect(r.rs.unread, 0);
    await r.session.close();
  });

  test('admin password logs in as admin and may post; wrong password is plain silence', () async {
    final r = await rig();
    await expectLater(r.rs.login('wrong'), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.silent)));
    expect(r.rs.loggedIn, isFalse);
    final l = await r.rs.login('adminpw');
    expect(l.isAdmin, isTrue);
    expect(r.rs.canPost, isTrue);
    await r.session.close();
  });

  test('a post is a plain direct message (txt_type 0) and comes back as a signed post from you', () async {
    final r = await rig();
    await r.rs.login('adminpw');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final out = await r.rs.post('hello from the hill');
    expect(out, RoomPostOutcome.sent);
    expect(r.radio.sentFrames.where((f) => f[0] == 2 && f[1] == 0).length, 1, reason: 'exactly one plain-text send to the room');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final mine = r.rs.posts.where((p) => p.text == 'hello from the hill').toList();
    expect(mine.length, 1);
    expect(mine.single.mine, isTrue);
    expect(mine.single.authorPrefixHex, toHex(r.radio.publicKey.take(4).toList()));
    await r.session.close();
  });

  test('with the room password you may post; as a read-only guest (allow.read.only) you read but cannot post', () async {
    final r = await rig(pw: 'roompw');
    final rw = await r.rs.login('roompw');
    expect(rw.canPost, isTrue);
    await r.session.close();
    final g = await rig();
    g.room.prefs['allow.read.only'] = 'on';
    final login = await g.rs.login('anything');
    expect(login.isAdmin, isFalse);
    expect(login.canPost, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(g.rs.posts, isNotEmpty, reason: 'a guest still reads');
    expect(await g.rs.post('hi'), RoomPostOutcome.notAllowed);
    expect(g.radio.sentFrames.where((f) => f[0] == 2), isEmpty, reason: 'nothing left the phone');
    await g.session.close();
  });

  test('not logged in: post is refused', () async {
    final r = await rig();
    expect(await r.rs.post('hi'), RoomPostOutcome.notLoggedIn);
    expect(r.radio.sentFrames.where((f) => f[0] == 2), isEmpty);
    await r.session.close();
  });

  test('a room that is out of range stays silent; the same post is not duplicated when it reappears', () async {
    final r = await rig();
    await r.rs.login('adminpw');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final n = r.rs.posts.length;
    // the room re-pushes the same post after a re-login (sync_since 0): deduped by author, time and text
    await r.rs.login('adminpw');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(r.rs.posts.length, n);
    await r.session.close();
  });
}
