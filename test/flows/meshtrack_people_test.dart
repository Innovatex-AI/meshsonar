// MeshTrack user flows: the people of meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md section 5.0, one group
// per person, each asserting what that person experiences. Every phone runs the REAL app objects (chat store +
// ChatService + ChannelAdmin over its own radio, the TxArbiter, MeshTrackWiring + MeshTrackService, Keychain, settings),
// and the widget tests drive the real Group sheet and setup screens on top of that wiring. Messages travel over a
// simulated air (test/flows/meshtrack_world.dart): only radios holding a channel's key hear it.
//
//   U1 two cars in a driveway         U2 club day with a stock-app member   U3 Family always + Club on drive day
//   U4 a MeshCore-TEAM friend         U5 cut someone off (Start fresh)      U6 hamfest, no drive (1 hour)
//   U7 switch radio / reinstall       + privacy for everyone: zones, 200 m buffer, zones not loaded
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';
import 'package:meshsonar/core/meshtrack/smart_beacon.dart' show SmartBeacon;
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/chat/qr_widgets.dart' show QrView;
import 'package:meshsonar/ui/meshtrack/group_setup.dart';
import 'package:meshsonar/ui/meshtrack/group_sheet.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_copy.dart';
import 'package:meshsonar/ui/theme.dart';

import '../ui/meshtrack/mt_kit.dart' show Opener, phone;
import 'meshtrack_world.dart';

// Westerville, Ohio (the simulator's drive area).
const double homeLat = 40.1262, homeLon = -82.9291;

/// Metres north / east as degrees at Westerville.
double north(double m) => m / 111320;
double east(double m) => m / (111320 * 0.7648);

// ------------------------------------------------------------------------------------------------ fakeAsync helpers

/// Runs [f] to completion on fake time, carrying the air as it goes.
T wait<T>(FakeAsync a, MtWorld w, Future<T> f) {
  T? out;
  Object? err;
  var done = false;
  f.then((v) {
    out = v;
    done = true;
  }, onError: (Object e) {
    err = e;
    done = true;
  });
  for (var i = 0; i < 3000 && !done; i++) {
    a.flushMicrotasks();
    a.elapse(const Duration(milliseconds: 10));
    w.air();
  }
  if (err != null) throw err!;
  expect(done, isTrue, reason: 'the operation finished');
  return out as T;
}

/// Moves time by [d] in [tick] steps; [each] runs at every step (GPS fixes), the air is carried after each.
void run(FakeAsync a, MtWorld w, Duration d, {Duration tick = const Duration(seconds: 1), void Function()? each}) {
  final end = a.elapsed + d;
  while (a.elapsed < end) {
    each?.call();
    a.flushMicrotasks();
    a.elapse(tick);
    w.air();
  }
  a.flushMicrotasks();
  w.air();
}

void settle(FakeAsync a, MtWorld w) => run(a, w, const Duration(milliseconds: 200), tick: const Duration(milliseconds: 20));

/// Creates a group on [p] (the setup's prefilled name unless [name]); returns (channel id, key, invite link).
({int id, Uint8List key, String link}) newGroup(FakeAsync a, MtWorld w, MtPhone p, [String? name]) {
  final r = wait(a, w, p.ops.createGroup(name ?? mtDefaultGroupName(p.name)));
  expect(r.ok, isTrue, reason: '$r');
  final id = r.channelId!;
  settle(a, w);
  return (id: id, key: wait(a, w, keyOf(p, id)), link: p.ops.inviteLink(id));
}

int joinGroup(FakeAsync a, MtWorld w, MtPhone p, String link) {
  final r = wait(a, w, p.ops.joinFromLink(link));
  expect(r.ok, isTrue, reason: '$r');
  settle(a, w);
  return r.channelId!;
}

MtFriend? friendOn(MtPhone p, Uint8List key, String name) => p.groupOf(key)?.friends.where((f) => f.name == name).firstOrNull;

/// A MeshCore-TEAM `#TEL:` message: base64 of [lat int32 BE x1e7][lon int32 BE x1e7][companion %][phone %][forwarding].
String teamTel(double lat, double lon) {
  final b = ByteData(11)
    ..setInt32(0, (lat * 1e7).round(), Endian.big)
    ..setInt32(4, (lon * 1e7).round(), Endian.big)
    ..setUint8(8, 80)
    ..setUint8(9, 64)
    ..setUint8(10, 0);
  return '#TEL:${base64.encode(b.buffer.asUint8List())}';
}

// ------------------------------------------------------------------------------------------------ widget helpers

/// The app's MeshTrack screens for one phone: the Group sheet opens from a button (the Drive chip in the app).
Widget host(MtPhone p, DateTime Function() now, {ChatController? chat}) => KeyedSubtree(
      key: ValueKey(p.name),
      child: MeshTrackScope(
        binding: MeshTrackBinding(
          service: p.svc,
          ops: p.ops,
          here: () => (lat: homeLat, lon: homeLon),
          selfName: () => p.name,
          chat: () => chat,
          now: now,
          onCentre: (_, _, _) {},
        ),
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.dark),
          darkTheme: meshSonarTheme(Brightness.dark),
          themeMode: ThemeMode.dark,
          home: Opener((c) => showGroupSheet(c)),
        ),
      ),
    );

/// Counts the person's taps.
class Taps {
  final WidgetTester tester;
  int n = 0;
  Taps(this.tester);
  Future<void> on(Finder f) async {
    if (f.evaluate().isEmpty) {
      final lists = find.byType(Scrollable);
      if (lists.evaluate().isNotEmpty) await tester.scrollUntilVisible(f, 120, scrollable: lists.last);
    }
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    n++;
    await tester.pumpAndSettle();
  }
}

/// A world on widget-test time: [t] moves with every [go].
class WidgetWorld {
  final WidgetTester tester;
  DateTime t = worldT0;
  late final MtWorld w = MtWorld(() => t);
  WidgetWorld(this.tester);

  Future<void> go(Duration d, {Duration tick = const Duration(seconds: 1), void Function()? each}) async {
    var left = d;
    while (left > Duration.zero) {
      final s = left < tick ? left : tick;
      each?.call();
      t = t.add(s);
      await tester.pump(s);
      w.air();
      left -= s;
    }
    await tester.pump();
    w.air();
  }

  Future<void> flush() async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      t = t.add(const Duration(milliseconds: 10));
      w.air();
    }
  }

  /// Stops every phone's engine and lets toasts and timers run out.
  Future<void> done() async {
    for (final n in w.nodes) {
      if (n is MtPhone) unawaited(n.w.dispose());
    }
    await tester.pumpWidget(const SizedBox());
    await go(const Duration(seconds: 70), tick: const Duration(seconds: 10));
  }
}

void main() {
  tearDown(MtSetupSeams.reset);

  // ============================================================================================ U1
  group('U1 two cars in a driveway: see each other, set up in under a minute', () {
    testWidgets('the screens: New group (name prefilled) -> Invite -> the second phone joins from the link -> both Share; 13 taps, no typing',
        (tester) async {
      phone(tester);
      final ww = WidgetWorld(tester);
      final andy = ww.w.phone('Andy');
      final beth = ww.w.phone('Beth');
      await ww.flush();

      // Andy: Drive chip -> New group -> (name prefilled) Create -> Share link -> Done.
      final taps = Taps(tester);
      String? shared;
      MtSetupSeams.shareText = (t) async => shared = t;
      await tester.pumpWidget(host(andy, () => ww.t));
      await taps.on(find.byKey(const Key('open')));
      expect(find.byKey(const Key('mt-empty')), findsOneWidget, reason: 'no group yet: the sheet opens on New group / Join');
      await taps.on(find.byKey(const Key('mt-empty-new')));
      final field = tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('mt-group-name')), matching: find.byType(EditableText)));
      expect(field.controller.text, "Andy's crew", reason: 'the one field is prefilled');
      await taps.on(find.byKey(const Key('mt-create')));
      await ww.flush();
      expect(find.byKey(const Key('mt-invite-qr')), findsOneWidget, reason: 'straight to the Invite screen');
      final id = andy.svc.state.groups.single.channelId;
      final qr = tester.widget<QrView>(find.byKey(const Key('mt-invite-qr')));
      expect(qr.data, andy.ops.inviteLink(id), reason: 'the QR is the real group link');
      await taps.on(find.byKey(const Key('mt-share-link')));
      expect(shared, andy.ops.inviteLink(id));
      final link = (MeshLinks.parse(shared!) as ChannelLink);
      expect(link.name, "Andy's crew");
      await taps.on(find.byKey(const Key('mt-invite-done')));
      expect(andy.radio.withSecret(link.secret), isNotNull, reason: 'the group is a channel on Andy\'s radio');

      // Andy turns Share on (first time: the intro, Got it).
      await taps.on(find.byKey(Key('mt-share-$id')));
      expect(find.byKey(const Key('mt-intro')), findsOneWidget);
      await taps.on(find.byKey(const Key('mt-intro-ok')));
      expect(andy.svc.state.group(id)!.config.share, isTrue);
      expect(andy.svc.state.group(id)!.config.duration, MtShareDuration.thisDrive);

      // Beth: the link arrives in Messages; Drive chip -> Join -> Paste -> Join.
      MtSetupSeams.paste = () async => shared;
      await tester.pumpWidget(host(beth, () => ww.t));
      await taps.on(find.byKey(const Key('open')));
      await taps.on(find.byKey(const Key('mt-empty-join')));
      await taps.on(find.byKey(const Key('mt-paste')));
      await taps.on(find.byKey(const Key('mt-join-go')));
      await ww.flush();
      expect(find.text(mtJoinedBanner("Andy's crew")), findsOneWidget, reason: 'the joined banner');
      final bid = beth.svc.state.groups.single.channelId;
      expect(beth.svc.state.group(bid)!.config.see, isTrue, reason: 'See is on after joining');
      expect(beth.svc.state.group(bid)!.config.share, isFalse, reason: 'Share stays off until she turns it on');
      expect(beth.radio.withSecret(link.secret), isNotNull, reason: 'same key on her radio');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await taps.on(find.byKey(Key('mt-share-$bid')));
      await taps.on(find.byKey(const Key('mt-intro-ok')));
      expect(beth.svc.state.group(bid)!.config.share, isTrue);

      expect(taps.n, 13, reason: 'Andy 7 taps (open, New group, Create, Share link, Done, Share, Got it), Beth 6; nothing typed');

      // Both start the drive and pull out of the driveway: each sees the other within one interval.
      andy.w.driveStarted();
      beth.w.driveStarted();
      final interval = SmartBeacon.interval(30);
      var i = 0;
      await ww.go(const Duration(seconds: 10), each: () {
        i++;
        andy.w.onDriveFix(andy.fix(homeLat + north(8.0 * i), homeLon, speedMps: 8.3, course: 0));
        beth.w.onDriveFix(beth.fix(homeLat + north(8.0 * i) - north(30), homeLon, speedMps: 8.3, course: 0));
      });
      final seenByAndy = andy.svc.state.group(id)!.friends.single;
      final seenByBeth = beth.svc.state.group(bid)!.friends.single;
      expect(seenByAndy.name, 'Beth');
      expect(seenByBeth.name, 'Andy');
      expect(seenByAndy.source, MtSource.meshTrack);
      expect(seenByAndy.onMap, isTrue);
      expect(ww.t.difference(worldT0.add(const Duration(seconds: 1))), lessThan(interval), reason: 'within one interval');
      expect(seenByBeth.lat, closeTo(homeLat, 0.001));
      expect(andy.chatTexts(link.secret), isEmpty, reason: 'positions are not chat bubbles');
      await ww.done();
    });

    test('the radios: each phone sees the other\'s pin within one interval, and it keeps moving with them', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final beth = w.phone('Beth', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy);
        joinGroup(a, w, beth, g.link);
        expect(andy.svc.setShare(andy.groupOf(g.key)!.channelId, true), MtResult.ok);
        expect(beth.svc.setShare(beth.groupOf(g.key)!.channelId, true), MtResult.ok);
        andy.w.driveStarted();
        beth.w.driveStarted();
        // 50 km/h north, Beth 200 m behind.
        var s = 0;
        void fixes() {
          s++;
          andy.w.onDriveFix(andy.fix(homeLat + north(13.9 * s), homeLon, speedMps: 13.9, course: 0));
          beth.w.onDriveFix(beth.fix(homeLat + north(13.9 * s - 200), homeLon, speedMps: 13.9, course: 0));
        }

        final interval = SmartBeacon.interval(50);
        run(a, w, const Duration(seconds: 5), each: fixes);
        final b0 = friendOn(andy, g.key, 'Beth')!;
        final a0 = friendOn(beth, g.key, 'Andy')!;
        expect(b0.speedKmh, 50);
        expect(a0.courseDeg, 0);
        run(a, w, interval + const Duration(seconds: 5), each: fixes);
        final a1 = friendOn(beth, g.key, 'Andy')!;
        expect(a1.lastHeard.isAfter(a0.lastHeard), isTrue, reason: 'a new position one interval later');
        expect(a1.lat, greaterThan(a0.lat), reason: 'the pin moved north with him');
        expect(a1.trail.length, greaterThanOrEqualTo(2), reason: 'a short trail');
        expect(beth.chatTexts(g.key), isEmpty);
        andy.w.driveStopped();
        run(a, w, const Duration(seconds: 5));
        expect(friendOn(beth, g.key, 'Andy')!.stopped, isTrue, reason: 'drive ended: MT1 x, Beth sees him stop at once');
        expect(andy.sentOn(g.key).where((t) => t == 'MT1 x'), hasLength(1));
        for (final p in [andy, beth]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });
  });

  group('U1 review fixes: duration change, Undo, Show position messages', () {
    test('switching This drive -> Until I stop mid-drive sends nothing extra; Stop + Undo waits the floor; the stop still reaches Beth; '
        'Show position messages keeps Beth\'s chat empty and lists Andy in the position list', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final beth = w.phone('Beth', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy);
        final bethId = joinGroup(a, w, beth, g.link);
        final id = andy.groupOf(g.key)!.channelId;
        wait(a, w, beth.ops.setShowPositionMessages(bethId, true));
        expect(andy.svc.setShare(id, true), MtResult.ok);
        andy.w.driveStarted();
        var s = 0;
        void fixes() {
          s++;
          andy.w.onDriveFix(andy.fix(homeLat + north(13.9 * s), homeLon, speedMps: 13.9, course: 0));
        }

        run(a, w, const Duration(seconds: 5), each: fixes);
        final first = andy.sentOn(g.key).length;
        expect(first, 1);
        // The sheet's duration control while sharing: no new "first" send, same session.
        expect(andy.svc.setShare(id, true, duration: MtShareDuration.untilStopped), MtResult.ok);
        run(a, w, const Duration(seconds: 10), each: fixes);
        expect(andy.sentOn(g.key).length, first, reason: 'a duration change is not a new share');
        // Stop, then Undo at once: nothing before the floor (25.4 s from the last send at t = 0).
        andy.svc.setShare(id, false);
        expect(andy.svc.setShare(id, true, duration: MtShareDuration.untilStopped), MtResult.ok);
        run(a, w, const Duration(seconds: 8), each: fixes);
        expect(andy.sentOn(g.key).where((t) => t.startsWith('MT1 @')), hasLength(1), reason: 'the floor holds across off/on');
        run(a, w, const Duration(seconds: 10), each: fixes);
        expect(andy.sentOn(g.key).where((t) => t.startsWith('MT1 @')), hasLength(2));
        andy.svc.setShare(id, false);
        run(a, w, const Duration(seconds: 5));
        expect(friendOn(beth, g.key, 'Andy')!.stopped, isTrue, reason: 'the stop still reaches Beth');
        expect(beth.chatTexts(g.key), isEmpty, reason: 'Show position messages never makes MT1 text chat');
        final list = beth.svc.positionMessages(bethId);
        expect(list.where((m) => m.name == 'Andy'), isNotEmpty);
        expect(list.first.body, 'MT1 x');
        for (final p in [andy, beth]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });
  });

  // ============================================================================================ U2
  group('U2 club drive day: 8 cars on one map, one member on the official MeshCore app', () {
    test('7 MeshTrack cars + a stock-app member who types "lat, lon" and a Plus Code -> "typed" pins; our MT1 text reads in plain chat', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final dave = w.stock('Dave');
        settle(a, w);
        final g = newGroup(a, w, andy, 'Club');
        wait(a, w, dave.join(g.link));
        expect(dave.radio.withSecret(g.key), isNotNull, reason: 'the stock app joins with the same link');
        final others = <MtPhone>[for (final n in ['Bea', 'Cal', 'Eve', 'Fay', 'Gus', 'Hal']) w.phone(n, introSeen: true)];
        settle(a, w);
        for (final p in others) {
          joinGroup(a, w, p, g.link);
        }
        andy.w.driveStarted();
        for (final p in [andy, ...others]) {
          expect(p.svc.setShare(p.groupOf(g.key)!.channelId, true), MtResult.ok);
          if (!identical(p, andy)) p.w.driveStarted();
        }
        var s = 0;
        run(a, w, const Duration(seconds: 6), each: () {
          s++;
          for (var i = 0; i < 7; i++) {
            final p = i == 0 ? andy : others[i - 1];
            p.w.onDriveFix(p.fix(homeLat + north(100.0 * i + 15 * s), homeLon + east(40.0 * i), speedMps: 15, course: 10));
          }
        });

        // Dave types his position the way a person does in the official app.
        wait(a, w, dave.type(g.key, '40.10012, -82.95120'));
        run(a, w, const Duration(seconds: 10));
        final typed = friendOn(andy, g.key, 'Dave')!;
        expect(typed.source, MtSource.typed);
        expect(typed.typed, isTrue, reason: 'shown as a "typed" pin');
        expect(typed.lat, closeTo(40.10012, 1e-5));
        expect(typed.lon, closeTo(-82.95120, 1e-5));
        expect(mtFriendNotes(typed), contains('Typed position'));
        expect(andy.chatTexts(g.key), contains('40.10012, -82.95120'), reason: 'a person wrote it for people: it stays chat');
        wait(a, w, dave.type(g.key, 'parked at 87G8Q5G6+2V see you'));
        run(a, w, const Duration(seconds: 2));
        final code = PlusCode.tryDecode('87G8Q5G6+2V')!;
        expect(friendOn(andy, g.key, 'Dave')!.lat, closeTo(code.lat, 1e-6), reason: 'a Plus Code in a sentence moves his pin');

        // Everyone on one map: 6 other MeshTrack cars + Dave.
        final names = andy.groupOf(g.key)!.friends.map((f) => f.name).toSet();
        expect(names, {'Bea', 'Cal', 'Eve', 'Fay', 'Gus', 'Hal', 'Dave'});
        expect(andy.groupOf(g.key)!.heardLast30Min, 7);
        expect(friendOn(others.last, g.key, 'Andy'), isNotNull);
        expect(friendOn(others.last, g.key, 'Dave')!.typed, isTrue, reason: 'every MeshSonar car sees Dave too');

        // Dave's plain chat shows our positions as readable text whose code pastes into a map app.
        final texts = dave.chatTexts(g.key);
        final mine = texts.where((t) => t.startsWith('MT1 @')).toList();
        expect(mine.length, greaterThanOrEqualTo(7), reason: 'every car\'s MT1 text arrives as chat in the stock app');
        final andys = dave.h.service.page(dave.h.store.channels.list(dave.radioId).firstWhere((c) => c.slot == dave.radio.withSecret(g.key)!.index).convKey)
            .messages
            .where((m) => m.senderName == 'Andy')
            .first;
        final tok = andys.text.split(' ');
        expect(tok[0], 'MT1');
        expect(tok[1], matches(RegExp(r'^@[23456789CFGHJMPQRVWX]{8}\+[23456789CFGHJMPQRVWX]{3}$')), reason: '11-digit Plus Code');
        final area = PlusCode.tryDecode(tok[1].substring(1))!;
        expect(area.lat, closeTo(homeLat, 0.0005));
        expect(area.lon, closeTo(homeLon, 0.0005));
        expect(andys.text, matches(RegExp(r' s54 c10$')), reason: 'speed km/h and course, readable');
        for (final p in [andy, ...others]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });
  });

  // ============================================================================================ U3
  group('U3 Family all the time, Club only on drive day', () {
    test('two groups at once: interval stretched x2, sends 3 s apart; Club off -> MT1 x once to Club, Family keeps going; Undo restores Club', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final wife = w.phone('Beth', introSeen: true);
        final carl = w.phone('Carl', introSeen: true);
        settle(a, w);
        final fam = newGroup(a, w, andy, 'Family');
        final club = newGroup(a, w, andy, 'Club');
        joinGroup(a, w, wife, fam.link);
        joinGroup(a, w, carl, club.link);
        final famId = andy.groupOf(fam.key)!.channelId, clubId = andy.groupOf(club.key)!.channelId;
        expect(andy.svc.setShare(famId, true, duration: MtShareDuration.untilStopped), MtResult.ok);
        andy.w.driveStarted();
        expect(andy.svc.setShare(clubId, true), MtResult.ok, reason: 'Club for this drive');
        expect(andy.svc.state.sharingNames, ['Family', 'Club']);

        // Arrival times of Andy's messages at each channel.
        final at = <String, List<DateTime>>{'fam': [], 'club': []};
        var fSeen = 0, cSeen = 0;
        var s = 0;
        void drive() {
          s++;
          andy.w.onDriveFix(andy.fix(homeLat + north(27.8 * s), homeLon, speedMps: 27.8, course: 0)); // 100 km/h straight
          final f = andy.sentOn(fam.key), c = andy.sentOn(club.key);
          for (; fSeen < f.length; fSeen++) {
            at['fam']!.add(w.now());
          }
          for (; cSeen < c.length; cSeen++) {
            at['club']!.add(w.now());
          }
        }

        run(a, w, const Duration(minutes: 10), each: drive);
        final fam10 = at['fam']!.length, club10 = at['club']!.length;
        // One group at 100 km/h: every 60 s (about 10 in 10 min). Two groups: every 120 s, so about 5 each.
        expect(SmartBeacon.interval(100, groups: 2), const Duration(minutes: 2));
        expect(fam10, inInclusiveRange(5, 6), reason: 'interval stretched by the number of groups');
        expect(club10, inInclusiveRange(5, 6));
        for (var i = 0; i < club10 && i < fam10; i++) {
          final gap = at['club']![i].difference(at['fam']![i]).abs();
          expect(gap.inMilliseconds, inInclusiveRange(3000, 4000), reason: 'one beacon, the two sends 3 s apart');
        }
        expect(friendOn(wife, fam.key, 'Andy'), isNotNull);
        expect(friendOn(carl, club.key, 'Andy'), isNotNull);
        expect(friendOn(wife, club.key, 'Andy'), isNull, reason: 'Beth is not in Club: she cannot read it');

        // Drive day is over for the club: Club off (what the sheet's Share switch calls).
        final before = andy.svc.state.group(clubId)!.config.duration;
        andy.svc.setShare(clubId, false);
        run(a, w, const Duration(minutes: 5), each: drive);
        expect(andy.sentOn(club.key).where((t) => t == 'MT1 x'), hasLength(1), reason: 'MT1 x to Club once');
        expect(andy.sentOn(club.key).last, 'MT1 x', reason: 'nothing more to Club');
        expect(friendOn(carl, club.key, 'Andy')!.stopped, isTrue, reason: 'Carl sees Andy stop at once');
        expect(andy.svc.state.group(famId)!.config.share, isTrue, reason: 'Family untouched');
        expect(at['fam']!.length - fam10, greaterThanOrEqualTo(4), reason: 'Family keeps sharing, now every 60 s again');
        expect(andy.sentOn(fam.key), isNot(contains('MT1 x')));
        expect(andy.svc.state.sharingNames, ['Family']);

        // Undo (the toast's action re-shares with the same duration).
        expect(andy.svc.setShare(clubId, true, duration: before), MtResult.ok);
        final clubBefore = andy.sentOn(club.key).length;
        run(a, w, const Duration(seconds: 10), each: drive);
        expect(andy.sentOn(club.key).length, greaterThan(clubBefore), reason: 'Undo restores Club: positions go there again');
        expect(friendOn(carl, club.key, 'Andy')!.stopped, isFalse);
        expect(andy.svc.state.sharingNames, ['Family', 'Club']);
        for (final p in [andy, wife, carl]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });

    testWidgets('the sheet: Club Share off -> "Stopped sharing with Club" + Undo; Family keeps sharing; Undo shares to Club again', (tester) async {
      phone(tester);
      final ww = WidgetWorld(tester);
      final andy = ww.w.phone('Andy', introSeen: true);
      await ww.flush();
      int make(String n) {
        int? id;
        andy.ops.createGroup(n).then((r) => id = r.channelId);
        return id ?? -1;
      }

      make('Family');
      await ww.flush();
      make('Club');
      await ww.flush();
      final fam = andy.svc.state.groups.firstWhere((g) => g.name == 'Family').channelId;
      final club = andy.svc.state.groups.firstWhere((g) => g.name == 'Club').channelId;
      andy.svc.setShare(fam, true, duration: MtShareDuration.untilStopped);
      andy.w.driveStarted();
      andy.svc.setShare(club, true);
      await ww.go(const Duration(seconds: 8), each: () => andy.w.onDriveFix(andy.fix(homeLat, homeLon, speedMps: 27.8)));
      final clubKey = await keyOf(andy, club);
      expect(andy.sentOn(clubKey), isNotEmpty);

      final taps = Taps(tester);
      await tester.pumpWidget(host(andy, () => ww.t));
      await taps.on(find.byKey(const Key('open')));
      expect(find.text('Sharing with 2 groups: updates about every 2 min at highway speed.'), findsOneWidget);
      await taps.on(find.byKey(Key('mt-share-$club')));
      expect(find.text('Stopped sharing with Club'), findsOneWidget);
      expect(andy.svc.state.group(fam)!.config.share, isTrue);
      await ww.go(const Duration(seconds: 4));
      expect(andy.sentOn(clubKey).where((t) => t == 'MT1 x'), hasLength(1));
      await taps.on(find.text('Undo'));
      expect(andy.svc.state.group(club)!.config.share, isTrue, reason: 'Undo restores Club');
      expect(andy.svc.state.group(club)!.config.duration, MtShareDuration.thisDrive);
      await ww.done();
    });
  });

  // ============================================================================================ U4
  group('U4 a friend on MeshCore-TEAM', () {
    test('their #TEL: message appears as a pin and not as a chat bubble; their #CAP: advert is hidden too', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy, 'Hunting');
        w.say('Jake', g.key, teamTel(40.2345678, -82.8765432));
        w.say('Jake', g.key, '#CAP:AQID');
        w.say('Jake', g.key, 'on the ridge');
        settle(a, w);
        final f = friendOn(andy, g.key, 'Jake')!;
        expect(f.source, MtSource.team);
        expect(f.typed, isFalse);
        expect(f.lat, closeTo(40.2345678, 1e-7));
        expect(f.lon, closeTo(-82.8765432, 1e-7));
        expect(f.onMap, isTrue);
        expect(andy.chatTexts(g.key), ['on the ridge'], reason: 'machine text hidden, his words stay chat');
        andy.w.dispose();
        settle(a, w);
      });
    });
  });

  // ============================================================================================ U5
  group('U5 cut someone off', () {
    test('Start fresh: new key, same name, old group retired, invite ready; the cut-off person\'s later messages never reach the map', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final beth = w.phone('Beth', introSeen: true);
        final carl = w.phone('Carl', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy, 'Club');
        joinGroup(a, w, beth, g.link);
        joinGroup(a, w, carl, g.link);
        for (final p in [beth, carl]) {
          p.svc.setShare(p.groupOf(g.key)!.channelId, true, duration: MtShareDuration.untilStopped);
        }
        andy.svc.setShare(andy.groupOf(g.key)!.channelId, true, duration: MtShareDuration.untilStopped);
        void fixes() {
          andy.location.add(andy.fix(homeLat, homeLon, speedMps: 0));
          beth.location.add(beth.fix(homeLat + north(500), homeLon, speedMps: 0));
          carl.location.add(carl.fix(homeLat - north(800), homeLon, speedMps: 0));
        }

        run(a, w, const Duration(seconds: 5), each: fixes);
        expect(friendOn(andy, g.key, 'Carl'), isNotNull);
        expect(friendOn(carl, g.key, 'Andy'), isNotNull, reason: 'Carl sees Andy before');

        final oldId = andy.groupOf(g.key)!.channelId;
        final res = wait(a, w, andy.ops.startFresh(oldId));
        expect(res.ok, isTrue, reason: '$res');
        final nid = res.channelId!;
        settle(a, w);
        final nkey = wait(a, w, keyOf(andy, nid));
        expect(sameKey(nkey, g.key), isFalse, reason: 'a new key');
        expect(andy.channel(nid).name, 'Club', reason: 'same name');
        expect(andy.ops.isGroup(oldId), isFalse, reason: 'old group retired');
        expect(andy.radio.withSecret(g.key), isNull, reason: 'the old key is off Andy\'s radio');
        expect(andy.channel(oldId).slot, isNull, reason: 'old channel kept on the phone with its history');
        final invite = MeshLinks.parse(andy.ops.inviteLink(nid)) as ChannelLink;
        expect(sameKey(invite.secret, nkey), isTrue, reason: 'the invite carries the new key');
        expect(invite.name, 'Club');
        expect(andy.svc.state.group(nid)!.friends, isEmpty, reason: 'a fresh roster');
        expect(andy.sentOn(nkey), isEmpty);

        // Andy re-invites Beth only.
        joinGroup(a, w, beth, andy.ops.inviteLink(nid));
        beth.svc.setShare(beth.groupOf(nkey)!.channelId, true, duration: MtShareDuration.untilStopped);
        andy.svc.setShare(nid, true, duration: MtShareDuration.untilStopped);
        run(a, w, const Duration(minutes: 6), each: () {
          fixes();
          // Carl moves so he keeps sending on the old key.
          carl.location.add(carl.fix(homeLat - north(800) + north(w.now().second * 20.0), homeLon, speedMps: 5));
        });
        expect(carl.sentOn(g.key).where((t) => t.startsWith('MT1 @')).length, greaterThan(1), reason: 'Carl keeps sending on the old key');
        expect(friendOn(andy, nkey, 'Beth'), isNotNull, reason: 'Beth is in the fresh group');
        expect(friendOn(andy, nkey, 'Carl'), isNull, reason: 'Carl is not shown on the map');
        expect(andy.svc.state.groups.expand((x) => x.friends).where((f) => f.name == 'Carl'), isEmpty);
        // Even a message that did reach the old channel row is not a group any more: nothing on the map.
        final consumed = andy.svc.onChannelText(MtInboundText(
            channelId: oldId, text: 'Carl: MT1 @${PlusCode.encode(homeLat, homeLon)}', receivedAt: w.now()));
        // Build 77 (round 3 C-U2): a position update in a channel that is not a group here is taken out of chat (collapsed,
        // never unread), so it is consumed; what matters is that it puts no one on the map.
        expect(consumed, isTrue);
        expect(andy.svc.state.groups.expand((x) => x.friends).where((f) => f.name == 'Carl'), isEmpty);
        // And Carl stops seeing Andy: he only gets silence on the old key.
        expect(friendOn(carl, g.key, 'Andy')!.lastHeard.isBefore(w.now().subtract(const Duration(minutes: 5))), isTrue);
        for (final p in [andy, beth, carl]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });

    test('Start fresh right after a position went out: the old group still gets MT1 x on the OLD key, nothing leaks to the new one', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final carl = w.phone('Carl', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy, 'Club');
        joinGroup(a, w, carl, g.link);
        final oldId = andy.groupOf(g.key)!.channelId;
        andy.svc.setShare(oldId, true, duration: MtShareDuration.untilStopped);
        andy.location.add(andy.fix(homeLat, homeLon, speedMps: 0));
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 500));
        w.air();
        expect(andy.sentOn(g.key), hasLength(1), reason: 'a position just went out (the next send must wait 3 s)');
        expect(friendOn(carl, g.key, 'Andy')!.stopped, isFalse);
        final res = wait(a, w, andy.ops.startFresh(oldId));
        expect(res.ok, isTrue);
        run(a, w, const Duration(seconds: 10));
        final nkey = wait(a, w, keyOf(andy, res.channelId!));
        expect(andy.sentOn(nkey), isEmpty, reason: 'the old group\'s stop never goes out under the new key');
        expect(andy.sentOn(g.key).last, 'MT1 x', reason: 'the old group is told once, on its own key');
        expect(friendOn(carl, g.key, 'Andy')!.stopped, isTrue, reason: 'Carl sees Andy stop at once');
        andy.w.dispose();
        carl.w.dispose();
        settle(a, w);
      });
    });

    testWidgets('the sheet: group menu -> Start fresh shows the Invite screen with the NEW link and why to re-invite', (tester) async {
      phone(tester);
      final ww = WidgetWorld(tester);
      final andy = ww.w.phone('Andy', introSeen: true);
      await ww.flush();
      unawaited(andy.ops.createGroup('Club'));
      await ww.flush();
      final old = andy.svc.state.groups.single.channelId;
      final oldLink = andy.ops.inviteLink(old);
      final taps = Taps(tester);
      await tester.pumpWidget(host(andy, () => ww.t));
      await taps.on(find.byKey(const Key('open')));
      await taps.on(find.byKey(Key('mt-menu-$old')));
      await taps.on(find.text('Start fresh'));
      await ww.flush();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-invite-qr')), findsOneWidget, reason: 'invite shown');
      expect(find.textContaining('New link.'), findsOneWidget);
      final nid = andy.svc.state.groups.single.channelId;
      expect(nid, isNot(old));
      final qr = tester.widget<QrView>(find.byKey(const Key('mt-invite-qr')));
      expect(qr.data, andy.ops.inviteLink(nid));
      expect(qr.data, isNot(oldLink));
      expect(find.text('Club'), findsWidgets, reason: 'same name');
      expect(taps.n, 3, reason: 'three taps to cut someone off');
      await ww.done();
    });
  });

  // ============================================================================================ U6
  group('U6 walking a hamfest lot, no drive', () {
    test('Share "1 hour" with no drive: positions from the phone location; after the hour MT1 x once and sharing off', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final beth = w.phone('Beth', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy, 'Hamfest');
        joinGroup(a, w, beth, g.link);
        final id = andy.groupOf(g.key)!.channelId;
        expect(andy.svc.state.driving, isFalse);
        expect(andy.svc.setShare(id, true, duration: MtShareDuration.oneHour), MtResult.ok);
        settle(a, w);
        expect(andy.w.phoneFixesActive, isTrue, reason: 'the phone location, no drive');
        expect(andy.svc.state.reason, isNot(MtShareReason.waitingForDrive));
        expect(andy.svc.state.sharingNames, ['Hamfest'], reason: 'the chip says Sharing: Hamfest');
        // Walking around the lot at 1.2 m/s, a fix every 10 s.
        var k = 0;
        void walk() {
          k++;
          andy.location.add(andy.fix(homeLat + north(12.0 * k % 400), homeLon + east(3.0 * k % 200), speedMps: 1.2, course: 0));
        }

        run(a, w, const Duration(seconds: 20), tick: const Duration(seconds: 10), each: walk);
        final first = friendOn(beth, g.key, 'Andy');
        expect(first, isNotNull, reason: 'Beth sees him right away');
        expect(first!.lat, closeTo(homeLat, 0.005));
        run(a, w, const Duration(minutes: 60, seconds: 10), tick: const Duration(seconds: 10), each: walk);
        final positions = andy.sentOn(g.key).where((t) => t.startsWith('MT1 @')).toList();
        expect(positions.length, greaterThanOrEqualTo(10), reason: 'walking pace: about every 5 min for an hour');
        for (final p in positions) {
          final c = PlusCode.tryDecode(p.split(' ')[1].substring(1))!;
          expect(c.lat, closeTo(homeLat, 0.005), reason: 'from the phone\'s location');
        }
        expect(andy.sentOn(g.key).where((t) => t == 'MT1 x'), hasLength(1), reason: 'the hour ended: MT1 x once');
        expect(andy.svc.state.group(id)!.config.share, isFalse, reason: 'sharing off');
        expect(andy.svc.state.reason, MtShareReason.off);
        expect(andy.w.phoneFixesActive, isFalse, reason: 'the phone location is let go');
        expect(andy.events.whereType<MtSharingStopped>().single.cause, MtStopCause.durationEnded);
        expect(friendOn(beth, g.key, 'Andy')!.stopped, isTrue);
        final after = andy.sent.length;
        run(a, w, const Duration(minutes: 10), tick: const Duration(seconds: 10), each: walk);
        expect(andy.sent.length, after, reason: 'nothing after the hour');
        for (final p in [andy, beth]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });
  });

  // ============================================================================================ U7
  group('U7 a second radio, or a reinstall', () {
    test('switch radio: groups restored from the Keychain to the new radio without asking; friends heard there', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final beth = w.phone('Beth', introSeen: true);
        settle(a, w);
        final fam = newGroup(a, w, andy, 'Family');
        final club = newGroup(a, w, andy, 'Club');
        joinGroup(a, w, beth, fam.link);
        final second = radioIdOf(99);
        andy.radios[second] = FakeRadioSlots(8);
        andy.disconnect();
        andy.connectTo(second);
        settle(a, w);
        expect(andy.radio.withSecret(fam.key), isNotNull, reason: 'Family written to the new radio');
        expect(andy.radio.withSecret(club.key), isNotNull, reason: 'Club too');
        expect(andy.svc.state.groups.map((g) => g.name).toSet(), {'Family', 'Club'});
        expect(andy.svc.state.groups.every((g) => g.config.onRadio && g.config.see), isTrue);
        expect(andy.events, isEmpty, reason: 'nothing asked, nothing stopped');
        beth.svc.setShare(beth.groupOf(fam.key)!.channelId, true, duration: MtShareDuration.untilStopped);
        run(a, w, const Duration(seconds: 3), each: () => beth.location.add(beth.fix(homeLat, homeLon)));
        expect(friendOn(andy, fam.key, 'Beth'), isNotNull, reason: 'Beth shows on the map through the new radio');
        andy.w.dispose();
        beth.w.dispose();
        settle(a, w);
      });
    });

    test('reinstall (no chat database, no settings; the Keychain stays): groups come back on the radio', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        settle(a, w);
        final fam = newGroup(a, w, andy, 'Family');
        final club = newGroup(a, w, andy, 'Club');
        andy.w.dispose();
        settle(a, w);
        // The app is deleted and installed again; a new radio this time (the old one was sold).
        final fresh = MtPhone('Andy', now: w.now, radioId: radioIdOf(50), keychain: andy.keychain);
        w.nodes.add(fresh);
        fresh.boot();
        settle(a, w);
        expect(fresh.svc.state.groups.map((g) => g.name).toSet(), {'Family', 'Club'});
        expect(fresh.radio.withSecret(fam.key), isNotNull);
        expect(fresh.radio.withSecret(club.key), isNotNull);
        expect(fresh.ops.inviteLink(fresh.groupOf(fam.key)!.channelId), fam.link, reason: 'same group, same invite');
        fresh.w.dispose();
        settle(a, w);
      });
    });

    testWidgets('a full radio: "Not on this radio" with Make room, which opens the radio\'s channel list', (tester) async {
      phone(tester);
      final ww = WidgetWorld(tester);
      final keychain = InMemorySecretStore();
      final andy = MtPhone('Andy', now: () => ww.t, radioId: radioIdOf(1), keychain: keychain, introSeen: true);
      ww.w.nodes.add(andy);
      andy.boot();
      await ww.flush();
      unawaited(andy.ops.createGroup('Family'));
      await ww.flush();
      final key = await keyOf(andy, andy.svc.state.groups.single.channelId);
      final full = FakeRadioSlots(2)..put(1, 'Other', List.filled(16, 0x55));
      andy.radios[radioIdOf(7)] = full;
      andy.disconnect();
      andy.connectTo(radioIdOf(7));
      await ww.flush();
      final g = andy.svc.state.groups.single;
      expect(andy.ops.notOnRadio(g.channelId), isTrue);
      expect(g.config.share, isFalse);
      expect(andy.svc.setShare(g.channelId, true), MtResult.notOnRadio);

      final chat = ChatController(store: andy.h.store, service: andy.h.service, sink: SwitchableSink(), wardriveChannelName: () => '#wardriving');
      chat.debugUseRadio(radioIdOf(7));
      final taps = Taps(tester);
      await tester.pumpWidget(host(andy, () => ww.t, chat: chat));
      await taps.on(find.byKey(const Key('open')));
      expect(find.text(mtNotOnRadio), findsOneWidget);
      await taps.on(find.byKey(Key('mt-make-room-${g.channelId}')));
      expect(find.byKey(const Key('mt-make-room-screen')), findsOneWidget);
      expect(find.text('Other'), findsOneWidget, reason: 'the channel list where the person removes one');

      // Room is made (Other removed): the group goes back on without asking.
      full.clearSlot(1);
      andy.admin.syncFromRadio(radioIdOf(7));
      await ww.flush();
      expect(full.withSecret(key), isNotNull);
      expect(andy.ops.notOnRadio(andy.svc.state.groups.single.channelId), isFalse);
      chat.dispose();
      await ww.done();
    });
  });

  // ============================================================================================ privacy, everyone
  group('privacy for every person: zones, the 200 m buffer, zones not loaded', () {
    test('no send inside a zone or within 200 m of its edge; none while zones are not loaded; manual send and meet-up obey it', () {
      fakeAsync((a) {
        final w = MtWorld(() => worldT0.add(a.elapsed));
        final andy = w.phone('Andy', introSeen: true);
        final beth = w.phone('Beth', introSeen: true);
        settle(a, w);
        final g = newGroup(a, w, andy, 'Family');
        joinGroup(a, w, beth, g.link);
        final id = andy.groupOf(g.key)!.channelId;
        const zone = PrivacyZone(lat: homeLat, lon: homeLon, radiusM: 300, label: 'Home');

        // Zones not loaded yet (app start): nothing goes out.
        andy.zones = PrivacyZones.notLoaded;
        andy.svc.setShare(id, true, duration: MtShareDuration.untilStopped);
        run(a, w, const Duration(seconds: 30), each: () => andy.location.add(andy.fix(homeLat + north(5000), homeLon)));
        expect(andy.sentOn(g.key), isEmpty);
        expect(andy.svc.state.reason, MtShareReason.zonesNotLoaded);
        expect(andy.svc.sendMyPosition(id), MtResult.zonesNotLoaded);

        andy.zones = const PrivacyZones([zone]);
        // Inside the zone (home).
        run(a, w, const Duration(minutes: 6), each: () => andy.location.add(andy.fix(homeLat + north(100), homeLon, speedMps: 1)));
        // 150 m outside the edge (inside the 200 m buffer).
        run(a, w, const Duration(minutes: 6), each: () => andy.location.add(andy.fix(homeLat + north(450), homeLon, speedMps: 1)));
        expect(andy.sentOn(g.key), isEmpty, reason: 'nothing inside the zone or its 200 m buffer');
        expect(andy.svc.state.reason, MtShareReason.privacyZone, reason: 'chip: Sharing paused: privacy zone');
        expect(andy.svc.sendMyPosition(id), MtResult.privacyZone, reason: 'Send my position obeys the zones');
        expect(andy.svc.meetHere(id, homeLat, homeLon), MtResult.privacyZone, reason: 'a meet-up point cannot point at home');
        expect(friendOn(beth, g.key, 'Andy'), isNull, reason: 'Beth never learns where home is');
        expect(andy.logs.join('\n'), isNot(contains(homeLat.toStringAsFixed(2))), reason: 'no coordinates in the log');

        // 250 m outside the edge: outside the buffer, it goes.
        run(a, w, const Duration(seconds: 5), each: () => andy.location.add(andy.fix(homeLat + north(550), homeLon, speedMps: 1)));
        expect(andy.sentOn(g.key), hasLength(1));
        final c = PlusCode.tryDecode(andy.sentOn(g.key).single.split(' ')[1].substring(1))!;
        expect(distanceM(c.lat, c.lon, homeLat, homeLon), greaterThan(300 + 200));
        expect(friendOn(beth, g.key, 'Andy'), isNotNull);

        // Driving back into the zone: friends see him go quiet, no position inside.
        final n = andy.sentOn(g.key).length;
        run(a, w, const Duration(minutes: 10), each: () => andy.location.add(andy.fix(homeLat + north(50), homeLon, speedMps: 1)));
        expect(andy.sentOn(g.key).length, n);
        for (final p in [andy, beth]) {
          p.w.dispose();
        }
        settle(a, w);
      });
    });
  });
}
