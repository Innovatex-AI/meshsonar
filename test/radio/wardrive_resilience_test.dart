// What the engine says when the world misbehaves mid-drive: GPS gone (permission revoked, Location Services off) and a
// phone clock that disagrees with GPS time.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/platform/geolocator_location.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

/// A GPS the test drives by hand.
class HandGps implements LocationSource {
  final _c = StreamController<GeoFix>.broadcast();
  GeoFix? now;
  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async => now;
  @override
  Future<bool> ensurePermission() async => true;
  void emit(GeoFix f) {
    now = f;
    _c.add(f);
  }
}

GeoFix fix(DateTime at) => GeoFix(lat: 40.1, lon: -82.9, at: at, accuracyM: 5, speedMps: 10);

void main() {
  echoTests();
  test('GPS gone mid-drive: the status starts as "waiting", then tells the driver where to look', () async {
    var t = DateTime.utc(2026, 10, 30, 12);
    final gps = HandGps()..now = fix(t);
    final radio = SimulatedTransport(location: SimulatedLocationSource(speedMps: 0), seed: 1, timeScale: 40);
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
    await link.start();
    final engine = DefaultWardriveEngine(
        link: link, location: gps, clock: () => t, tick: const Duration(milliseconds: 20));
    await engine.start(const WardriveConfig(intervalSec: 10, minDistanceM: 15, listenWindow: Duration(milliseconds: 100)));
    await Future<void>.delayed(const Duration(milliseconds: 400)); // first ping
    gps.now = null; // permission revoked / Location Services off
    t = t.add(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.current.waitingFor, PingWait.gps);
    expect(engine.current.message, 'No GPS fix: waiting to ping');
    t = t.add(const Duration(seconds: 25));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.current.message, contains('Location is on and allowed'));
    // Location comes back: the drive carries on by itself.
    gps.now = fix(t);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(engine.current.waitingFor, isNot(PingWait.gps));
    await engine.stop();
  });

  test('a steady clock difference over several fixes is reported, a stale cached fix is not', () async {
    var t = DateTime.utc(2026, 10, 30, 12);
    final gps = HandGps()..now = fix(t);
    final radio = SimulatedTransport(location: SimulatedLocationSource(speedMps: 0), seed: 1, timeScale: 40);
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
    await link.start();
    final engine = DefaultWardriveEngine(link: link, location: gps, clock: () => t, tick: const Duration(seconds: 1));
    await engine.start(const WardriveConfig(intervalSec: 10, minDistanceM: 15, listenWindow: Duration(milliseconds: 100)));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // A cached fix 10 minutes old, then a fresh one: the lateness changes, so no warning.
    gps.emit(fix(t.subtract(const Duration(minutes: 10))));
    gps.emit(fix(t.subtract(const Duration(minutes: 9))));
    gps.emit(fix(t));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(engine.current.clockSkew, isNull);
    // The phone says it is 3 hours earlier than GPS, fix after fix.
    for (var i = 0; i < 4; i++) {
      gps.emit(fix(t.add(const Duration(hours: 3))));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(engine.current.clockSkew, const Duration(hours: 3));
    // The clock is corrected.
    gps.emit(fix(t));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(engine.current.clockSkew, isNull);
    await engine.stop();
  });

  test('describeClockSkew reads naturally', () {
    expect(AppState.describeClockSkew(const Duration(minutes: 7)), '7 min behind');
    expect(AppState.describeClockSkew(const Duration(hours: -3)), '3 h ahead of');
    expect(AppState.describeClockSkew(const Duration(days: -400)), '400 days ahead of');
  });

  test('a remembered GPS fix older than half a minute is never used for a ping', () {
    final now = DateTime.utc(2026, 10, 30, 12);
    expect(lastKnownIsFresh(now.subtract(const Duration(seconds: 10)), now), isTrue);
    expect(lastKnownIsFresh(now.subtract(const Duration(minutes: 5)), now), isFalse);
    expect(lastKnownIsFresh(now.subtract(const Duration(hours: 3)), now), isFalse);
    expect(lastKnownIsFresh(now.add(const Duration(hours: 3)), now), isFalse);
  });
}

// Mutation-check gaps from docs/TESTING.md: de-dup prefers the copy that came most directly; out-of-range readings
// become null instead of reaching the server (which rejects the whole ping for them).
void echoTests() {
  final secret = hashtagChannelSecret('#wardriving');
  const text = 'MS:abcdefghij';
  const ts = 1767225600;
  final sentAt = DateTime.utc(2026, 10, 30, 12);

  RxPacket heardVia(List<String> path, {double snr = 5, double rssi = -90}) {
    final pkt = MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.grpTxt),
      pathLenByte: path.length,
      path: [for (final h in path) fromHex(h)],
      payload: buildGroupTextPayload(secret, ts, 'Car', text),
    );
    return RxPacket(at: sentAt, raw: pkt.toBytes(), snrDb: snr, rssiDbm: rssi);
  }

  List<Echo> build(List<RxPacket> rx) =>
      DefaultWardriveEngine.echoesFor([for (final r in rx) (r, sentAt.add(const Duration(milliseconds: 500)))], secret, text, ts, sentAt);

  test('the same repeater heard twice: the copy with fewer hops wins even with a worse SNR', () {
    final e = build([
      heardVia(['df', '4e'], snr: 11), // came via a second repeater: not a direct link
      heardVia(['df'], snr: 3), // direct
    ]);
    expect(e, hasLength(1));
    expect(e.single.repeater, 'df');
    expect(e.single.hops, 1);
    expect(e.single.snrDb, 3);
  });

  test('equal hops: the best SNR wins; different repeaters are kept apart', () {
    final e = build([heardVia(['df'], snr: 3), heardVia(['df'], snr: 9), heardVia(['a1'], snr: -2)]);
    expect(e.map((x) => x.repeater), ['df', 'a1']);
    expect(e.first.snrDb, 9);
  });

  test('SNR outside -40..40 and RSSI outside -160..0 become null, in-range readings pass through', () {
    final e = build([heardVia(['df'], snr: 55, rssi: 12), heardVia(['a1'], snr: -41, rssi: -161), heardVia(['b2'], snr: 12.75, rssi: -71)]);
    expect(e[0].snrDb, isNull);
    expect(e[0].rssiDbm, isNull);
    expect(e[1].snrDb, isNull);
    expect(e[1].rssiDbm, isNull);
    expect(e[2].snrDb, 12.75);
    expect(e[2].rssiDbm, -71);
    expect(DefaultWardriveEngine.inRangeForTest(double.nan, -40, 40), isNull);
    expect(DefaultWardriveEngine.inRangeForTest(-40, -40, 40), -40);
    expect(DefaultWardriveEngine.inRangeForTest(40, -40, 40), 40);
  });
}
