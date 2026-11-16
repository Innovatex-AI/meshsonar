// MT-9 replay (meshtrack plan sections 4 and 9): a drive with pings every 30 s and MeshTrack sharing on, played into the
// stack as it ships (link + RadioSession + TxArbiter + engine) with two scripted friends on the group's private slot.
//   * zero MeshTrack sends inside a ping's listen window;
//   * ping detection within 1 point of the same world without MeshTrack (the ping_replay_test.dart stack);
//   * the send count over the route inside the band the smart rate gives at 47 km/h;
//   * a privacy zone fixture on the route: zero sends inside it (plus the 200 m buffer).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/meshtrack_wiring.dart' show MeshTrackWiring;
import 'package:meshsonar/core/meshtrack/meshtrack_service.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/radio/inbound.dart' show SendStatus;
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import '../support/replay_radio.dart';

const _slot = 2;
const _listen = Duration(seconds: 10);

/// ReplayLocation's route: north from 40.1262 at 13 m/s, from the replay's start.
double _routeLat(Duration sinceStart) => 40.1262 + sinceStart.inMilliseconds / 1000.0 * 13 / 111320.0;
const _routeLon = -82.9312;

class Rig {
  MeshTrackService? svc;
  final logs = <String>[];
}

/// The app stack of ping_replay_test.dart plus one MeshTrackService wired the way MeshTrackWiring wires it (silent channel
/// send through the arbiter's track door, its budget, the engine's listen window, the drive's GPS stream).
StackBuilder meshTrackStack(Rig rig, {PrivacyZones zones = const PrivacyZones([]), bool share = true}) => (link, gps, clock) async {
      final arbiter = TxArbiter(clock: clock);
      final session = LinkRadioSession(link, info: link.selfInfo, clock: clock, arbiter: arbiter);
      session.chatActive = true;
      session.setInboundPersister((m) async {});
      session.inbound.listen((_) {});
      final e = DefaultWardriveEngine(link: link, location: gps, clock: clock);
      e.pingGate = session.pingGate;
      final svc = MeshTrackService(
        sendChannelText: (_, text) async {
          final r = await arbiter.runTrackSend(utf8.encode(text).length, () => session.sendChannelMessage(_slot, text));
          return r.status != SendStatus.failed;
        },
        budget: (_, text) {
          final d = arbiter.requestTrack(utf8.encode(text).length);
          return !d.go && d.airtimeLimited ? MtBudget.airtimeLimit : MtBudget.ok;
        },
        zones: () => zones,
        selfName: () => link.selfInfo?.name,
        positionAirtime: () => meshTrackPositionAirtime(sf: 7, bwKhz: 62.5, cr: 5, nameBytes: 6),
        log: rig.logs.add,
        now: clock,
      );
      rig.svc = svc;
      unawaited(svc.start());
      svc.setRadioConnected(true);
      svc.addGroup(_slot, 'Saturday crew');
      if (share) svc.setShare(_slot, true);
      svc.driveStarted();
      e.status.listen((st) => svc.setPingWindow(MeshTrackWiring.pingWindowOf(st)));
      gps.fixes.listen((f) => svc.onFix(MeshTrackWiring.mtFixOf(f)));
      return e;
    };

StackBuilder plainStack() => (link, gps, clock) async {
      final session = LinkRadioSession(link, info: link.selfInfo, clock: clock, arbiter: TxArbiter(clock: clock));
      session.chatActive = true;
      session.setInboundPersister((m) async {});
      session.inbound.listen((_) {});
      final e = DefaultWardriveEngine(link: link, location: gps, clock: clock);
      e.pingGate = session.pingGate;
      return e;
    };

List<({DateTime at, String text})> _positions(ReplayResult r) => [for (final t in r.radio.trackSent) if (t.text.startsWith('MT1 @')) t];

void main() {
  test('pings every 30 s with sharing on: no MeshTrack send in a listen window; detection unchanged; send count in band', () {
    final rig = Rig();
    final base = runReplay(build: plainStack(), seed: 3, driveSeconds: 1800, intervalSec: 30, listenWindow: _listen, backgroundEverySec: 4);
    final mt = runReplay(
        build: meshTrackStack(rig),
        seed: 3,
        driveSeconds: 1800,
        intervalSec: 30,
        listenWindow: _listen,
        backgroundEverySec: 4,
        friends: (t0) => FriendScript.westerville(t0, slot: _slot));
    final sends = _positions(mt);
    // ignore: avoid_print
    print('REPLAY meshtrack: pings=${mt.pingsSent} (base ${base.pingsSent}) detect=${(mt.detection() * 100).toStringAsFixed(1)}% '
        '(base ${(base.detection() * 100).toStringAsFixed(1)}%) track=${mt.radio.trackSent.length} positions=${sends.length} '
        'friends=${mt.radio.friendSent.length}');

    expect(mt.radio.friendSent, isNotEmpty, reason: 'the friends really were on the air');
    expect(sends, isNotEmpty);
    for (final t in mt.radio.trackSent) {
      for (final p in mt.radio.sent) {
        final inWindow = !t.at.isBefore(p.at) && t.at.isBefore(p.at.add(_listen));
        expect(inWindow, isFalse, reason: 'MeshTrack send at ${t.at} inside the listen window of the ping at ${p.at}');
      }
    }
    expect((mt.detection() - base.detection()).abs() * 100, lessThanOrEqualTo(1.0), reason: 'ping detection within 1 point');
    expect((mt.pingsSent - base.pingsSent).abs(), lessThanOrEqualTo(1), reason: 'the ping cadence is unchanged');
    expect(mt.engine.skippedPings, isEmpty);
    // 13 m/s = 46.8 km/h: one position about every 60 s x 80 / 46.8 = 103 s on a straight road, plus the first one:
    // 1800 s -> about 18. The band allows for waits behind listen windows and the start.
    expect(sends.length, inInclusiveRange(12, 22));
    final gaps = [for (var i = 1; i < sends.length; i++) sends[i].at.difference(sends[i - 1].at).inSeconds];
    expect(gaps.every((g) => g >= 25), isTrue, reason: 'never closer than the airtime floor (SF7: 25.5 s): $gaps');
    expect(rig.logs.join('\n'), isNot(contains('MT1 @')), reason: 'positions are never logged');
    unawaited(rig.svc!.dispose());
  });

  test('a privacy zone on the route: zero sends inside it or its 200 m buffer, sends before and after', () {
    final rig = Rig();
    final t0 = DateTime.utc(2026, 11, 1, 12);
    // The car is at the zone centre 900 s into the drive; 1 km radius.
    final centreLat = _routeLat(const Duration(seconds: 900));
    final zones = PrivacyZones([PrivacyZone(lat: centreLat, lon: _routeLon, radiusM: 1000)]);
    final mt = runReplay(
        build: meshTrackStack(rig, zones: zones),
        seed: 3,
        driveSeconds: 1800,
        intervalSec: 30,
        listenWindow: _listen,
        friends: (t) => FriendScript.westerville(t, slot: _slot));
    final sends = _positions(mt);
    expect(sends, isNotEmpty);
    var inside = 0, before = 0, after = 0;
    for (final s in sends) {
      final lat = _routeLat(s.at.difference(t0));
      final d = distanceM(lat, _routeLon, centreLat, _routeLon);
      if (d <= 1000 + kMtZoneBufferM) inside++;
      if (lat < centreLat - 0.02) before++;
      if (lat > centreLat + 0.02) after++;
    }
    expect(inside, 0, reason: 'nothing sent inside the zone or its buffer');
    expect(before, greaterThan(0));
    expect(after, greaterThan(0), reason: 'sharing carries on after leaving the zone');
    expect(rig.logs, contains('meshtrack: skipped: zone'));
    unawaited(rig.svc!.dispose());
  });

  test('zones not loaded: nothing at all is sent (fail closed)', () {
    final rig = Rig();
    final mt = runReplay(build: meshTrackStack(rig, zones: PrivacyZones.notLoaded), seed: 3, driveSeconds: 300, intervalSec: 30, listenWindow: _listen);
    expect(_positions(mt), isEmpty);
    expect(mt.pingsSent, greaterThan(5), reason: 'the drive itself goes on');
    unawaited(rig.svc!.dispose());
  });
}
