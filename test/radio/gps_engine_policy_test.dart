// Engine-level rules of the GPS policy that the Andy replay does not isolate: the cadence runs on a monotonic clock (a wall clock that
// steps does nothing) and a manual ping takes a fix from the window.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import '../support/andy_gps.dart';
import '../support/replay_radio.dart';

void main() {
  test('wall-clock steps (NTP, a manual change) do not move the cadence: it runs on the monotonic clock', () {
    final jumps = {300: const Duration(hours: -1), 600: const Duration(minutes: 30), 700: const Duration(seconds: -20)};
    late DefaultWardriveEngine engine;
    final r = runReplay(
      build: (link, gps, clock) async {
        final session = LinkRadioSession(link, info: link.selfInfo, clock: clock, arbiter: TxArbiter(clock: clock));
        engine = DefaultWardriveEngine(link: link, location: gps, clock: clock, monotonic: ReplayClocks.mono);
        engine.pingGate = session.pingGate;
        return engine;
      },
      driveSeconds: 1200,
      intervalSec: 15,
      makeGps: (clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, 20)),
      jank: (s) => jumps[s] ?? Duration.zero,
    );
    final t = r.engine.timingSummary();
    expect(r.pingsSent, inInclusiveRange(79, 81), reason: 'exactly one ping per 15 s of real (monotonic) time');
    expect(t.gapMaxS, lessThanOrEqualTo(15.01));
    expect(t.gapP50S, 15);
  });

  test('a manual ping takes a fix from the stream window even when the platform call never answers, and re-anchors the cadence', () {
    final manual = <DrivePing>[];
    final r = runReplay(
      build: (link, gps, clock) async => DefaultWardriveEngine(link: link, location: gps, clock: clock),
      driveSeconds: 200,
      intervalSec: 30,
      makeGps: (clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, 20), currentStalls: true),
      onSecond: (s, e) {
        if (s == 100) unawaited(e.pingNow().then(manual.add));
      },
    );
    expect(manual.length, 1);
    final sent = r.radio.sent.map((p) => p.at.difference(r.engineStartedAt!).inSeconds).toList();
    final m = manual.single.ts.difference(r.engineStartedAt!.toUtc()).inSeconds;
    expect(r.pings.any((p) => (p.gpsAccuracyM ?? 0) == 20), isTrue);
    // Auto pings at ~2, 32, 62, 92; the manual one at 101; the next auto 30 s after it (131), not at the old grid (122).
    expect(sent.where((t) => (t - m).abs() <= 1), hasLength(1), reason: 'the manual ping went out at once');
    final next = sent.firstWhere((t) => t > m + 3);
    expect(next - m, inInclusiveRange(29, 31), reason: 'a manual ping resets the interval');
  });
}

