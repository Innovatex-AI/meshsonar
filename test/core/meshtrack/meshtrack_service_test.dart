import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/channel_text_tap.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/meshtrack/meshtrack_service.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';
import 'package:meshsonar/core/privacy_zones.dart';

final _t0 = DateTime.utc(2026, 11, 16, 12);
const _home = (lat: 40.0, lon: -83.0);

class _Store implements MtLastKnownStore {
  String? data;
  int writes = 0;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String json) async {
    data = json;
    writes++;
  }

  @override
  Future<void> clear() async => data = null;
}

class _H {
  final FakeAsync a;
  final sent = <({int ch, String text, Duration at})>[];
  final logs = <String>[];
  final events = <MtEvent>[];
  final groupsOut = <List<MtGroupConfig>>[];
  MtBudget budget = MtBudget.ok;
  int budgetCalls = 0;
  PrivacyZones zones = const PrivacyZones([]);
  final _Store store;
  late final MeshTrackService s;

  _H(this.a, {int seed = 1, _Store? store}) : store = store ?? _Store() {
    s = MeshTrackService(
      sendChannelText: (ch, text) async {
        sent.add((ch: ch, text: text, at: a.elapsed));
        return true;
      },
      budget: (_, _) {
        budgetCalls++;
        return budget;
      },
      zones: () => zones,
      selfName: () => 'Me',
      lastKnown: this.store,
      log: logs.add,
      now: () => _t0.add(a.elapsed),
      random: math.Random(seed),
      onGroupsChanged: groupsOut.add,
    );
    s.events.listen(events.add);
    s.start();
    a.flushMicrotasks();
  }

  DateTime get now => _t0.add(a.elapsed);

  MtFix fix({double lat = 39.9, double lon = -82.9, double kmh = 50, double course = 90, double acc = 5}) =>
      MtFix(lat: lat, lon: lon, at: now, accuracyM: acc, speedMps: kmh / 3.6, courseDeg: course);

  /// Drives for [secs] seconds, a fix each second, moving east.
  void drive(int secs, {double kmh = 50, double lat = 39.9, double startLon = -82.9}) {
    var lon = startLon;
    for (var i = 0; i < secs; i++) {
      s.onFix(fix(lat: lat, lon: lon, kmh: kmh));
      a.elapse(const Duration(seconds: 1));
      lon += kmh / 3.6 / (111320 * math.cos(lat * math.pi / 180));
    }
  }

  void ready({List<int> groups = const [1], bool share = true, MtShareDuration d = MtShareDuration.untilStopped}) {
    s.syncGroups([for (final g in groups) MtGroupConfig(channelId: g, name: 'G$g')]);
    s.setRadioConnected(true);
    if (share) {
      for (final g in groups) {
        expect(s.setShare(g, true, duration: d), MtResult.ok);
      }
    }
  }

  bool rx(int ch, String text, {DateTime? senderTs}) =>
      s.onChannelText(MtInboundText(channelId: ch, text: text, receivedAt: now, senderTs: senderTs, snr: 7.5, pathLen: 2));

  List<String> texts([int? ch]) => [for (final x in sent) if (ch == null || x.ch == ch) x.text];
  int stops(int ch) => texts(ch).where((t) => t == 'MT1 x').length;
  int positions([int? ch]) => texts(ch).where((t) => t.startsWith('MT1 @')).length;

  void end() {
    s.dispose();
    a.flushMicrotasks();
  }
}

void _run(void Function(_H h) body, {int seed = 1, _Store? store}) => fakeAsync((a) {
      final h = _H(a, seed: seed, store: store);
      body(h);
      h.end();
    });

void main() {
  group('eligibility', () {
    Channel ch(String name, ChannelKind kind, {int slot = 3}) => Channel(radioId: 'r', slot: slot, name: name, kind: kind);
    final random16 = Uint8List.fromList(List.generate(16, (i) => i * 7 + 3));

    test('private channel with a random key is allowed', () {
      expect(MeshTrackGroup.eligible(ch('Family', ChannelKind.private)), isTrue);
      expect(MeshTrackGroup.eligible(ch('Family', ChannelKind.private), secret: random16), isTrue);
      expect(MeshTrackGroup.eligible(ch('Family', ChannelKind.private, slot: 0).copyWith(clearSlot: true)), isTrue);
    });

    test('refuses Public, # channels, system and the wardrive channel', () {
      expect(MeshTrackGroup.eligible(ch('Public', ChannelKind.public, slot: 0)), isFalse);
      expect(MeshTrackGroup.eligible(ch('Public', ChannelKind.private)), isFalse);
      expect(MeshTrackGroup.eligible(ch('Family', ChannelKind.private, slot: 0)), isFalse);
      expect(MeshTrackGroup.eligible(ch('#ohio', ChannelKind.hashtag)), isFalse);
      expect(MeshTrackGroup.eligible(ch('#ohio', ChannelKind.private)), isFalse);
      expect(MeshTrackGroup.eligible(ch('#wardrive', ChannelKind.system)), isFalse);
      expect(MeshTrackGroup.eligible(ch('wardrive', ChannelKind.private), wardriveChannelName: '#wardrive'), isFalse);
      expect(MeshTrackGroup.eligible(ch('Pings', ChannelKind.private), wardriveChannelName: 'pings'), isFalse);
    });

    test('refuses a key anyone can derive', () {
      expect(MeshTrackGroup.eligible(ch('Family', ChannelKind.private), secret: publicChannelSecret16), isFalse);
      expect(MeshTrackGroup.eligible(ch('ohio', ChannelKind.private), secret: hashtagSecret16('#ohio')), isFalse);
      expect(MeshTrackGroup.eligible(ch('Family', ChannelKind.private), secret: [1, 2, 3]), isFalse);
    });
  });

  group('privacy zones', () {
    test('no send inside a zone or within 200 m of its edge; sends 300 m out', () => _run((h) {
          h.zones = const PrivacyZones([PrivacyZone(lat: 40, lon: -83, radiusM: 300)]);
          h.ready();
          final inBuffer = eastOf(_home.lat, _home.lon, 450); // 150 m outside the edge
          h.s.onFix(h.fix(lat: inBuffer.lat, lon: inBuffer.lon));
          h.a.elapse(const Duration(seconds: 5));
          expect(h.sent, isEmpty);
          expect(h.s.state.reason, MtShareReason.privacyZone);
          expect(h.logs, contains('meshtrack: skipped: zone'));
          final inside = eastOf(_home.lat, _home.lon, 100);
          h.s.onFix(h.fix(lat: inside.lat, lon: inside.lon));
          h.a.elapse(const Duration(seconds: 5));
          expect(h.sent, isEmpty);
          expect(h.s.sendMyPosition(1), MtResult.privacyZone);
          expect(h.s.meetHere(1, inside.lat, inside.lon), MtResult.privacyZone);
          final out = eastOf(_home.lat, _home.lon, 600); // 300 m outside
          h.s.onFix(h.fix(lat: out.lat, lon: out.lon));
          h.a.elapse(const Duration(seconds: 5));
          expect(h.positions(), 1);
          expect(h.s.state.reason, MtShareReason.sharing);
        }));

    test('fix accuracy widens the buffer', () => _run((h) {
          h.zones = const PrivacyZones([PrivacyZone(lat: 40, lon: -83, radiusM: 300)]);
          h.ready();
          final p = eastOf(_home.lat, _home.lon, 560); // 260 m out, but 80 m accuracy
          h.s.onFix(h.fix(lat: p.lat, lon: p.lon, acc: 80));
          h.a.elapse(const Duration(seconds: 5));
          expect(h.sent, isEmpty);
        }));

    test('zones not loaded: nothing is sent (fail closed)', () => _run((h) {
          h.zones = PrivacyZones.notLoaded;
          h.ready();
          h.drive(30);
          expect(h.sent, isEmpty);
          expect(h.s.state.reason, MtShareReason.zonesNotLoaded);
          expect(h.s.sendMyPosition(1), MtResult.zonesNotLoaded);
          expect(h.s.meetHere(1, 39, -84), MtResult.zonesNotLoaded);
          h.zones = const PrivacyZones([]);
          h.drive(3);
          expect(h.positions(), 1);
        }));
  });

  group('gates and reasons', () {
    test('waiting for GPS: no fix, poor accuracy, stale fix', () => _run((h) {
          h.ready();
          expect(h.s.sendMyPosition(1), MtResult.waitingForGps);
          h.s.onFix(h.fix(acc: 150));
          h.a.elapse(const Duration(seconds: 2));
          expect(h.sent, isEmpty);
          expect(h.s.state.reason, MtShareReason.waitingForGps);
          h.s.onFix(h.fix());
          h.a.elapse(const Duration(seconds: 40));
          expect(h.positions(), 1);
          expect(h.s.sendMyPosition(1), MtResult.waitingForGps); // last fix now 40 s old
        }));

    test('radio disconnected pauses; This drive waits for a drive', () => _run((h) {
          h.ready(d: MtShareDuration.thisDrive);
          h.drive(5);
          expect(h.sent, isEmpty);
          expect(h.s.state.reason, MtShareReason.waitingForDrive);
          h.s.driveStarted();
          h.drive(2);
          expect(h.positions(), 1);
          h.s.setRadioConnected(false);
          expect(h.s.state.reason, MtShareReason.radioDisconnected);
          expect(h.s.sendMyPosition(1), MtResult.radioDisconnected);
        }));

    test('airtime limit: skipped, not queued, backs off for the floor and logs once', () => _run((h) {
          h.budget = MtBudget.airtimeLimit;
          h.ready();
          h.drive(15);
          expect(h.sent, isEmpty);
          expect(h.s.state.reason, MtShareReason.airtimeLimit);
          expect(h.logs.where((l) => l == 'meshtrack: skipped: airtime limit'), hasLength(1), reason: 'one log line per state change');
          expect(h.budgetCalls, 1, reason: 'no retry on every fix: the next try waits the floor (25.4 s at the default preset)');
          h.budget = MtBudget.ok;
          h.drive(9); // t = 24 s: still inside the floor of the refused try
          expect(h.positions(), 0);
          h.drive(3);
          expect(h.positions(), 1, reason: 'the owed position goes once the floor has passed');
          expect(h.s.state.reason, MtShareReason.sharing);
          // Refused again later: logged again (a new state change).
          h.budget = MtBudget.airtimeLimit;
          h.drive(200);
          expect(h.logs.where((l) => l == 'meshtrack: skipped: airtime limit'), hasLength(2));
        }));

    test('a slow-moving position carries no s0 (s0 is the parked message only)', () => _run((h) {
          h.ready();
          h.s.onFix(h.fix(kmh: 0.4));
          h.a.elapse(const Duration(seconds: 1));
          expect(h.texts().single, isNot(contains(' s')), reason: 'below 1 km/h: no speed');
          expect(h.texts().single, startsWith('MT1 @'));
        }));

    test('exact sends 11 digits, approximate 8', () => _run((h) {
          h.ready();
          h.drive(2);
          final code = h.texts().single.split(' ')[1].substring(1);
          expect(code.length, 12);
          expect(h.texts().single, contains(' s50 c90'));
          h.s.setPositionMode(MtPositionMode.approximate);
          h.s.sendMyPosition(1);
          h.a.elapse(const Duration(seconds: 5));
          final approx = h.texts().last.split(' ')[1].substring(1);
          expect(approx.length, 9);
          expect(approx.endsWith('+'), isTrue);
          expect(PlusCode.isFull(approx), isTrue);
        }));
  });

  group('ping listen window', () {
    test('held while listening, goes 1 s after the window closes', () => _run((h) {
          h.ready();
          h.s.setPingWindow(const MtPingWindow(listening: true));
          h.drive(4);
          expect(h.sent, isEmpty);
          final closeAt = h.a.elapsed;
          h.s.setPingWindow(const MtPingWindow());
          h.a.elapse(const Duration(milliseconds: 500));
          expect(h.sent, isEmpty);
          h.a.elapse(const Duration(milliseconds: 600));
          expect(h.positions(), 1);
          expect(h.sent.single.at - closeAt, greaterThanOrEqualTo(const Duration(seconds: 1)));
        }));

    test('held while the next ping is due within 3 s', () => _run((h) {
          h.ready();
          h.s.setPingWindow(MtPingWindow(nextPingAt: h.now.add(const Duration(seconds: 2))));
          h.s.onFix(h.fix());
          h.a.elapse(const Duration(milliseconds: 1500));
          expect(h.sent, isEmpty);
          // the ping went out and its window opened, then closed
          h.s.setPingWindow(const MtPingWindow(listening: true));
          h.a.elapse(const Duration(seconds: 10));
          expect(h.sent, isEmpty);
          h.s.setPingWindow(MtPingWindow(nextPingAt: h.now.add(const Duration(seconds: 30))));
          h.a.elapse(const Duration(seconds: 2));
          expect(h.positions(), 1);
        }));
  });

  group('several groups', () {
    test('one send per group, 3 s apart; intervals stretched by the group count', () => _run((h) {
          h.ready(groups: [1, 2]);
          h.drive(400, kmh: 100);
          final p1 = h.sent.where((x) => x.ch == 1).toList();
          final p2 = h.sent.where((x) => x.ch == 2).toList();
          expect(p1.length, p2.length);
          for (var i = 0; i < p1.length; i++) {
            expect(p2[i].at - p1[i].at, const Duration(seconds: 3));
            expect(p2[i].text, p1[i].text);
          }
          for (var i = 1; i < p1.length; i++) {
            expect(p1[i].at - p1[i - 1].at, greaterThanOrEqualTo(const Duration(seconds: 119)));
          }
          expect(p1.length, 4); // 0, 120, 240, 360 s
        }));

    test('at most 3 groups share at once', () => _run((h) {
          h.ready(groups: [1, 2, 3, 4], share: false);
          for (final g in [1, 2, 3]) {
            expect(h.s.setShare(g, true), MtResult.ok);
          }
          expect(h.s.setShare(4, true), MtResult.tooManyGroups);
          expect(h.s.state.canShareMore, isFalse);
          expect(h.s.state.sharingNames, ['G1', 'G2', 'G3']);
          h.s.setShare(2, false);
          expect(h.s.setShare(4, true), MtResult.ok);
        }));
  });

  group('requests', () {
    test('answered after a random 2-10 s delay, at most once per 30 s', () {
      final delays = <Duration>{};
      for (var seed = 0; seed < 12; seed++) {
        _run((h) {
          h.ready();
          h.drive(2);
          h.a.elapse(const Duration(seconds: 20));
          h.s.onFix(h.fix());
          final before = h.positions();
          final at = h.a.elapsed;
          h.rx(1, 'Sam: MT1 ?');
          h.a.elapse(const Duration(milliseconds: 1999));
          expect(h.positions(), before);
          h.a.elapse(const Duration(seconds: 9));
          expect(h.positions(), before + 1);
          delays.add(h.sent.last.at - at);
          expect(h.sent.last.at - at, lessThanOrEqualTo(const Duration(seconds: 10)));
          h.s.onFix(h.fix());
          h.rx(1, 'Ann: MT1 ?');
          h.a.elapse(const Duration(seconds: 12));
          expect(h.positions(), before + 1, reason: 'second request within 30 s');
        }, seed: seed);
      }
      expect(delays.length, greaterThan(3), reason: 'jitter varies');
    });

    test('request to my name answered, to another name ignored', () => _run((h) {
          h.ready();
          h.drive(2);
          h.a.elapse(const Duration(seconds: 20));
          h.s.onFix(h.fix());
          h.rx(1, 'Sam: MT1 ? Bob');
          h.a.elapse(const Duration(seconds: 11));
          expect(h.positions(), 1);
          h.s.onFix(h.fix());
          h.rx(1, 'Sam: MT1 ? me');
          h.a.elapse(const Duration(seconds: 11));
          expect(h.positions(), 2);
        }));

    test('not sharing: toast event, no answer; answer setting off: no answer', () => _run((h) {
          h.ready(share: false);
          h.s.onFix(h.fix());
          h.rx(1, 'Sam: MT1 ?');
          h.a.elapse(const Duration(seconds: 11));
          expect(h.sent, isEmpty);
          expect(h.events.whereType<MtAskedWhileNotSharing>().single.name, 'Sam');
          h.s.setShare(1, true, duration: MtShareDuration.untilStopped);
          h.s.setAnswerRequests(false);
          h.a.elapse(const Duration(seconds: 1));
          final n = h.positions();
          h.a.elapse(const Duration(seconds: 30));
          h.s.onFix(h.fix());
          h.rx(1, 'Ann: MT1 ?');
          h.a.elapse(const Duration(seconds: 11));
          expect(h.positions(), n);
        }));

    test('asking: once per 60 s per group', () => _run((h) {
          h.ready(share: false);
          expect(h.s.askWhereAreYou(1), MtResult.ok);
          expect(h.s.askWhereAreYou(1, name: 'Sam'), MtResult.tooSoon);
          expect(h.s.state.group(1)!.askedUntil, isNotNull);
          expect(h.s.state.group(1)!.askedName, isNull, reason: 'asked everyone');
          h.a.elapse(const Duration(seconds: 61));
          expect(h.s.state.group(1)!.askedName, isNull);
          expect(h.s.askWhereAreYou(1, name: 'Sam'), MtResult.ok);
          expect(h.s.state.group(1)!.askedName, 'Sam', reason: 'only Sam\'s row says Asked');
          h.a.elapse(const Duration(seconds: 5));
          expect(h.texts(), ['MT1 ?', 'MT1 ? Sam']);
        }));
  });

  group('share switch: duration changes and off/on', () {
    test('changing the duration while sharing sends nothing extra and the later stop still goes', () => _run((h) {
          h.ready();
          h.drive(10);
          expect(h.positions(), 1);
          expect(h.s.setShare(1, true, duration: MtShareDuration.oneHour), MtResult.ok);
          expect(h.s.state.group(1)!.config.duration, MtShareDuration.oneHour);
          expect(h.s.state.group(1)!.config.shareUntil, isNotNull);
          h.s.setShare(1, true, duration: MtShareDuration.untilStopped);
          h.drive(5);
          expect(h.positions(), 1, reason: 'no new first send inside the 20 s floor');
          h.s.setShare(1, false);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1, reason: 'the session still owes its MT1 x');
        }));

    test('Share off then on at once (Undo) never beats the airtime floor', () => _run((h) {
          h.ready();
          h.drive(10); // first position at t = 0
          h.s.setShare(1, false);
          expect(h.s.setShare(1, true, duration: MtShareDuration.untilStopped), MtResult.ok);
          h.drive(15); // t = 25 s, floor 25.4 s
          expect(h.positions(), 1, reason: 'the floor counts from the last real send');
          h.drive(3);
          expect(h.positions(), 2, reason: 'then the new share sends at once');
          h.s.setShare(1, false);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 2);
        }));

    test('Undo of a stop held for the radio keeps the session (its stop is owed later)', () => _run((h) {
          h.ready();
          h.drive(3);
          h.s.setRadioConnected(false);
          h.s.setShare(1, false);
          h.s.setShare(1, true, duration: MtShareDuration.untilStopped);
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 0, reason: 'sharing again: no stop on reconnect');
          h.s.setShare(1, false);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1);
        }));

    test('a drive restart never beats the floor either', () => _run((h) {
          h.ready(d: MtShareDuration.untilStopped);
          h.s.driveStarted();
          h.drive(5);
          h.s.driveStopped();
          h.s.driveStarted();
          h.drive(5);
          expect(h.positions(), 1);
          h.drive(20);
          expect(h.positions(), 2);
        }));
  });

  group('stop message MT1 x, once per group on each stop cause', () {
    test('user turns Share off', () => _run((h) {
          h.ready(groups: [1, 2]);
          h.drive(10);
          h.s.setShare(1, false);
          h.s.setShare(1, false);
          h.a.elapse(const Duration(seconds: 10));
          expect(h.stops(1), 1);
          expect(h.stops(2), 0);
          expect(h.events.whereType<MtSharingStopped>().single.cause, MtStopCause.user);
        }));

    test('whenIdle: completes once the leave stop is on the air (Start fresh waits on it before the new key goes in)', () => _run((h) {
          h.ready();
          h.s.onFix(h.fix());
          h.a.flushMicrotasks();
          expect(h.positions(1), 1, reason: 'a position just went: the stop must wait the 3 s spacing');
          h.s.leaveGroup(1);
          var idle = false;
          h.s.whenIdle(1).then((_) => idle = true);
          h.a.elapse(const Duration(seconds: 2));
          expect(idle, isFalse, reason: 'MT1 x still queued');
          expect(h.stops(1), 0);
          h.a.elapse(const Duration(seconds: 2));
          expect(h.stops(1), 1);
          expect(idle, isTrue, reason: 'idle right after the stop went');
          var other = false;
          h.s.whenIdle(2).then((_) => other = true);
          h.a.flushMicrotasks();
          expect(other, isTrue, reason: 'nothing queued for that channel: at once');
        }));

    test('whenIdle gives up after its timeout (radio gone, nothing can go)', () => _run((h) {
          h.ready();
          h.s.onFix(h.fix());
          h.a.flushMicrotasks();
          h.s.askWhereAreYou(1);
          h.s.setRadioConnected(false);
          h.s.setShare(1, false);
          var idle = false;
          h.s.whenIdle(1, timeout: const Duration(seconds: 5)).then((_) => idle = true);
          h.a.elapse(const Duration(seconds: 4));
          expect(idle, isFalse);
          h.a.elapse(const Duration(seconds: 2));
          expect(idle, isTrue);
        }));

    test('This drive ends with the drive', () => _run((h) {
          h.ready(groups: [1, 2], d: MtShareDuration.thisDrive);
          h.s.driveStarted();
          h.drive(10);
          h.s.driveStopped();
          h.s.driveStopped();
          h.a.elapse(const Duration(seconds: 10));
          expect(h.stops(1), 1);
          expect(h.stops(2), 1);
          expect(h.s.state.sharing, isFalse);
        }));

    test('1 hour runs out', () => _run((h) {
          h.ready(d: MtShareDuration.oneHour);
          h.drive(10);
          h.a.elapse(const Duration(minutes: 61));
          expect(h.stops(1), 1);
          expect(h.s.state.sharing, isFalse);
          expect(h.events.whereType<MtSharingStopped>().single.cause, MtStopCause.durationEnded);
        }));

    test('radio gone 5 min: sharing off, stop sent on reconnect', () => _run((h) {
          h.ready();
          h.drive(10);
          h.s.setRadioConnected(false);
          h.a.elapse(const Duration(minutes: 4));
          expect(h.s.state.sharing, isTrue);
          h.a.elapse(const Duration(minutes: 2));
          expect(h.s.state.sharing, isFalse);
          expect(h.events.whereType<MtSharingStopped>().single.cause, MtStopCause.radioDisconnected);
          expect(h.stops(1), 0);
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1);
          h.s.setRadioConnected(false);
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1);
        }));

    test('a short disconnect does not stop sharing', () => _run((h) {
          h.ready();
          h.drive(3);
          h.s.setRadioConnected(false);
          h.a.elapse(const Duration(minutes: 2));
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(minutes: 10));
          expect(h.s.state.sharing, isTrue);
          expect(h.stops(1), 0);
        }));

    test('Leave group', () => _run((h) {
          h.ready();
          h.drive(10);
          final before = h.s.leaveGroup(1);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1);
          expect(h.s.state.groups, isEmpty);
          h.s.restoreGroup(before!);
          expect(h.s.state.group(1)!.config.share, isFalse);
        }));

    test('Leave while the radio is gone: the stop goes once on reconnect within 10 min', () => _run((h) {
          h.ready(groups: [1, 2]);
          h.drive(10);
          h.s.setRadioConnected(false);
          h.s.leaveGroup(1);
          h.a.elapse(const Duration(minutes: 3));
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1);
          h.s.setRadioConnected(false);
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(1), 1, reason: 'once');
          // Past 10 min: dropped.
          h.s.setRadioConnected(false);
          h.s.leaveGroup(2);
          h.a.elapse(const Duration(minutes: 11));
          h.s.setRadioConnected(true);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.stops(2), 0);
        }));

    test('Leave writes the last-known file at once (no 5 s delay)', () => _run((h) {
          h.ready(share: false);
          h.rx(1, 'Sam: MT1 @${PlusCode.encode(39.9, -82.9)} s40 c90');
          h.a.elapse(const Duration(seconds: 6));
          expect(h.store.data, contains('Sam'));
          h.s.leaveGroup(1);
          h.a.flushMicrotasks();
          expect(h.store.data, isNot(contains('Sam')));
        }));

    test('no position sent: no stop message', () => _run((h) {
          h.ready();
          h.s.setShare(1, false);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.sent, isEmpty);
        }));
  });

  group('receiving', () {
    test('consume decisions', () => _run((h) {
          h.ready(share: false);
          final code = PlusCode.encode(39.96121, -82.99881);
          expect(h.rx(1, 'Sam: MT1 @$code s34 c270'), isTrue);
          expect(h.rx(1, 'Sam: hello there'), isFalse);
          expect(h.rx(1, 'Sam: MT1 hi'), isFalse);
          expect(h.rx(1, 'Sam: MT2 @$code'), isFalse);
          expect(h.rx(9, 'Sam: MT1 @$code'), isFalse, reason: 'not a group');
          expect(h.rx(1, 'Bob: $code'), isFalse, reason: 'typed stays chat');
          expect(h.rx(1, 'Tim: #TEL:F9GYxM6HYvyAkAI'), isTrue);
          expect(h.rx(1, 'Me: MT1 @$code'), isTrue);
          final fs = h.s.state.group(1)!.friends;
          expect(fs.map((f) => f.name).toSet(), {'Sam', 'Bob', 'Tim'});
          final sam = fs.firstWhere((f) => f.name == 'Sam');
          expect(sam.speedKmh, 34);
          expect(sam.courseDeg, 270);
          expect(sam.snr, 7.5);
          expect(sam.pathLen, 2);
          expect(sam.lat, closeTo(39.96121, 0.0001));
          expect(fs.firstWhere((f) => f.name == 'Bob').typed, isTrue);
          expect(fs.firstWhere((f) => f.name == 'Tim').source, MtSource.team);
          expect(h.s.state.group(1)!.heardLast30Min, 3);
        }));

    test('chat tap adapter (ChannelTextTap): consume vs pass, backlog sender time', () => _run((h) {
          h.ready(share: false);
          ChannelTextEvent ev(String? name, String body, {int ch = 1, int? senderTs}) => ChannelTextEvent(
                radioId: 'r',
                channelId: ch,
                channelSlot: 2,
                channelKind: ChannelKind.private,
                convKey: 'c:$ch',
                senderName: name,
                body: body,
                senderTs: senderTs ?? h.now.millisecondsSinceEpoch ~/ 1000,
                snr: 4,
                pathLen: null,
                rssi: -90,
                receivedMs: h.now.millisecondsSinceEpoch,
                backlog: false,
              );
          final tap = h.s.channelTextTap;
          final code = PlusCode.encode(40, -83);
          expect(tap.onChannelText(ev('Sam', 'MT1 @$code')), TapVerdict.consume);
          expect(tap.onChannelText(ev('Sam', 'hi all')), TapVerdict.pass);
          expect(tap.onChannelText(ev('Sam', 'MT1 @$code', ch: 7)), TapVerdict.pass);
          expect(tap.onChannelText(ev(null, 'MT1 @$code')), TapVerdict.consume);
          final old = h.now.subtract(const Duration(hours: 1));
          tap.onChannelText(ev('Ann', 'MT1 @$code', senderTs: old.millisecondsSinceEpoch ~/ 1000));
          final ann = h.s.state.group(1)!.friends.firstWhere((f) => f.name == 'Ann');
          expect(ann.lastHeard, old);
          expect(ann.staleness, MtStaleness.grey);
        }));

    test('duplicates, meet pins, stop, See off', () => _run((h) {
          h.ready(share: false);
          final code = PlusCode.encode(39.5, -83.5);
          final ts = h.now.subtract(const Duration(minutes: 1));
          h.rx(1, 'Sam: MT1 !$code Gate 3', senderTs: ts);
          final meet = h.s.state.group(1)!.meet!;
          expect(meet.label, 'Gate 3');
          expect(meet.setBy, 'Sam');
          h.rx(1, 'Sam: MT1 !x');
          expect(h.s.state.group(1)!.meet, isNull);
          h.rx(1, 'Sam: MT1 !$code Gate 3', senderTs: ts); // duplicate receipt: dropped
          expect(h.s.state.group(1)!.meet, isNull);
          h.rx(1, 'Sam: MT1 @$code');
          h.a.elapse(const Duration(seconds: 6));
          h.rx(1, 'Sam: MT1 x');
          expect(h.s.state.group(1)!.friends.single.stopped, isTrue);
          h.s.setSee(1, false);
          expect(h.s.state.group(1)!.friends, isEmpty);
          h.rx(1, 'Ann: MT1 @$code');
          h.s.setSee(1, true);
          expect(h.s.state.group(1)!.friends, isEmpty);
        }));

    test('Meet here in Approximate goes at 8 digits; the fix accuracy widens the zone buffer', () => _run((h) {
          h.ready(share: false);
          h.s.setPositionMode(MtPositionMode.approximate);
          expect(h.s.meetHere(1, 39.5, -83.5), MtResult.ok);
          h.a.elapse(const Duration(seconds: 4));
          final code = h.texts().single.split(' ')[1].substring(1);
          expect(code, PlusCode.encode(39.5, -83.5, codeLength: kPlusCodeApproxDigits));
          expect(code.length, 9);
          h.zones = const PrivacyZones([PrivacyZone(lat: 40, lon: -83, radiusM: 300)]);
          final p = eastOf(_home.lat, _home.lon, 560); // 60 m outside the 200 m buffer
          expect(h.s.meetHere(1, p.lat, p.lon), MtResult.ok);
          expect(h.s.meetHere(1, p.lat, p.lon, accuracyM: 80), MtResult.privacyZone, reason: 'accuracy counts like for positions');
        }));

    test('my meet pin and clear go out', () => _run((h) {
          h.ready(share: false);
          expect(h.s.meetHere(1, 39.5, -83.5, label: 'Big oak'), MtResult.ok);
          expect(h.s.state.group(1)!.meet!.setBy, 'Me');
          h.a.elapse(const Duration(seconds: 4));
          expect(h.s.clearMeet(1), MtResult.ok);
          h.a.elapse(const Duration(seconds: 4));
          expect(h.texts(), ['MT1 !${PlusCode.encode(39.5, -83.5)} Big oak', 'MT1 !x']);
        }));

    test('a stale backlog position shows as list only', () => _run((h) {
          h.ready(share: false);
          h.rx(1, 'Sam: MT1 @${PlusCode.encode(40, -83)}', senderTs: h.now.subtract(const Duration(hours: 3)));
          final f = h.s.state.group(1)!.friends.single;
          expect(f.onMap, isFalse);
        }));
  });

  group('groups and persistence', () {
    test('loadGroups forces Share off; Share on every drive turns on at drive start', () => _run((h) {
          h.s.loadGroups(const [
            MtGroupConfig(channelId: 1, name: 'Family', share: true, duration: MtShareDuration.untilStopped),
            MtGroupConfig(channelId: 2, name: 'Club', shareEveryDrive: true),
          ]);
          expect(h.s.state.sharing, isFalse);
          expect(h.groupsOut.last.every((c) => !c.share), isTrue);
          h.s.driveStarted();
          expect(h.s.state.sharingNames, ['Club']);
          expect(h.s.state.group(2)!.config.duration, MtShareDuration.thisDrive);
        }));

    test('a group not on the radio stops sharing silently and cannot share', () => _run((h) {
          h.ready();
          h.drive(3);
          h.s.syncGroups(const [MtGroupConfig(channelId: 1, name: 'G1', share: true, onRadio: false)]);
          h.a.elapse(const Duration(seconds: 5));
          expect(h.s.state.sharing, isFalse);
          expect(h.stops(1), 0);
          expect(h.s.setShare(1, true), MtResult.notOnRadio);
        }));

    test('last-known file: written, restored within 24 h, cleared', () {
      final store = _Store();
      _run((h) {
        h.ready(share: false);
        h.rx(1, 'Sam: MT1 @${PlusCode.encode(40, -83)} s20 c10');
        h.a.elapse(const Duration(seconds: 6));
        expect(store.writes, greaterThan(0));
        expect(store.data, isNot(contains('trail')));
      }, store: store);
      _run((h) {
        h.s.syncGroups(const [MtGroupConfig(channelId: 1, name: 'G1')]);
        expect(h.s.state.group(1)!.friends.single.name, 'Sam');
      }, store: store);
      // restore before the group list arrives
      _run((h) {
        h.a.elapse(const Duration(seconds: 1));
        h.s.syncGroups(const [MtGroupConfig(channelId: 1, name: 'G1')]);
        expect(h.s.state.group(1)!.friends.single.speedKmh, 20);
        h.s.clearLastKnown();
        h.a.flushMicrotasks();
        expect(h.s.state.group(1)!.friends, isEmpty);
      }, store: store);
      expect(store.data, isNotNull); // dispose writes the (empty) state again
      expect(store.data, isNot(contains('Sam')));
    });

    test('a file older than 24 h is ignored', () {
      final store = _Store()
        ..data = '{"v":1,"savedAt":"2026-11-15T10:00:00.000Z","groups":{"1":{"friends":[{"name":"Sam","lat":40,"lon":-83,"acc":2,"at":"2026-11-15T10:00:00.000Z"}]}}}';
      _run((h) {
        h.s.syncGroups(const [MtGroupConfig(channelId: 1, name: 'G1')]);
        expect(h.s.state.group(1)!.friends, isEmpty);
      }, store: store);
    });
  });

  test('no coordinates, codes or names in any log line', () => _run((h) {
        h.zones = const PrivacyZones([PrivacyZone(lat: 40, lon: -83, radiusM: 300)]);
        h.ready(groups: [1, 2]);
        h.drive(200, kmh: 90);
        final z = eastOf(_home.lat, _home.lon, 50);
        h.s.onFix(h.fix(lat: z.lat, lon: z.lon));
        h.a.elapse(const Duration(seconds: 3));
        h.rx(1, 'Sam: MT1 @${PlusCode.encode(39.96, -82.99)} s34');
        h.rx(1, 'Sam: MT1 ?');
        h.a.elapse(const Duration(seconds: 12));
        h.s.sendMyPosition(1);
        h.s.meetHere(1, 39.2, -83.9, label: 'Gate');
        h.s.setShare(1, false);
        h.s.setRadioConnected(false);
        h.a.elapse(const Duration(minutes: 6));
        expect(h.logs, isNotEmpty);
        expect(h.logs.any((l) => l.startsWith('meshtrack: sent position, ') && l.endsWith(' bytes')), isTrue);
        final coord = RegExp(r'-?\d+\.\d+');
        final code = RegExp(r'[23456789CFGHJMPQRVWX]{4,}\+');
        for (final l in h.logs) {
          expect(coord.hasMatch(l), isFalse, reason: l);
          expect(code.hasMatch(l.toUpperCase()), isFalse, reason: l);
          expect(l.contains('Sam') || l.contains('Gate') || l.contains('G1'), isFalse, reason: l);
        }
      }));

  test('sent position reports 53 bytes for the spec example size class', () => _run((h) {
        h.ready();
        h.drive(2);
        // "Me: MT1 @<11-digit> s50 c90" = 29 text bytes -> 3 AES blocks -> 53-byte packet (plan section 3)
        expect(h.logs.where((l) => l.startsWith('meshtrack: sent position')).single, 'meshtrack: sent position, 53 bytes');
      }));
}
