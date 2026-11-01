// Replay-based measurement of the ping + detection pipeline: the SAME scripted world (test/support/replay_radio.dart) played
// into the app stack as it ships (link + RadioSession + TxArbiter + chat message sync). Prints detection and cadence numbers.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import '../support/replay_radio.dart';

/// The stack the app builds when chat is in use: session + arbiter wired to the engine, inbound persister listening.
StackBuilder appStack({bool chat = true}) => (link, gps, clock) async {
      final session = LinkRadioSession(link, info: link.selfInfo, clock: clock, arbiter: TxArbiter(clock: clock));
      if (chat) {
        session.chatActive = true;
        session.setInboundPersister((m) async {});
        session.inbound.listen((_) {});
      }
      final e = DefaultWardriveEngine(link: link, location: gps, clock: clock);
      e.pingGate = session.pingGate;
      return e;
    };

void report(String name, ReplayResult r) {
  final gaps = r.sendGaps()..sort();
  double q(double p) => gaps.isEmpty ? 0 : gaps[((gaps.length - 1) * p).round()];
  // ignore: avoid_print
  print('REPLAY $name: sent=${r.pingsSent} recorded=${r.pings.length} detectWin=${(r.detection() * 100).toStringAsFixed(1)}% '
      'detectAll=${(r.detection(withinMs: 13000) * 100).toStringAsFixed(1)}% late=${r.lateEchoes} '
      'gap median=${q(.5).toStringAsFixed(1)}s p95=${q(.95).toStringAsFixed(1)}s max=${q(1).toStringAsFixed(1)}s '
      'skips=${r.engine.skippedPings.map((k, v) => MapEntry(k.name, v))} cmds=${r.radio.commands} sync=${r.radio.syncCommands}');
}

void main() {
  // Measured Nov 1 2026 on this timeline (seed 3), same world played into three stacks:
  //   stack                         2 h / 15 s / SF7 pings   1 h / 10 s / SF8 pings   cadence (15 s / 10 s)
  //   pre-session engine c7b3add         451 / 480               328 / 360              16.0 s / 11.0 s
  //   shipped 0.24.x+ (before fix)       336 / 480 (-30%)         93 / 360 (-74%)       16.0 s, holes to 931 s / 272 s
  //   this fix                           481 / 480               361 / 360              15.0 s / 10.0 s exactly
  // The "before fix" row is what the 1% unknown-region cap did to a wardrive with chat bound to the radio.
  test('2 h at 15 s cadence with chat bound and a busy channel: every ping goes out, exactly on time', () {
    final r = runReplay(build: appStack(), seed: 3, driveSeconds: 7200, backgroundEverySec: 2, bleLatencyMs: 120);
    report('app/2h/sf7/chat', r);
    expect(r.engine.skippedPings, isEmpty, reason: 'chat bound to the radio is not chatting: no budget skips');
    expect(r.pingsSent, inInclusiveRange(478, 481), reason: '7200 s / 15 s = 480');
    final gaps = r.sendGaps();
    expect(gaps.reduce((a, b) => a > b ? a : b), lessThan(15.5), reason: 'no hole in the cadence');
    expect(gaps.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(14.7),
        reason: 'never early beyond the radio\'s own command queueing (a send that waited behind a message sync)');
    expect(r.pings.length, r.pingsSent, reason: 'every ping sent is recorded');
  });

  test('1 h at 10 s on SF8 (a ping is 386 ms on air): the 2% / 1% budgets no longer starve it', () {
    final r = runReplay(build: appStack(), seed: 3, driveSeconds: 3600, intervalSec: 10, backgroundEverySec: 2, bleLatencyMs: 120, sf: 8);
    report('app/1h/10s/sf8/chat', r);
    expect(r.engine.skippedPings, isEmpty);
    expect(r.pingsSent, inInclusiveRange(358, 361));
    expect(r.sendGaps().reduce((a, b) => a > b ? a : b), lessThan(10.3), reason: 'the 10 s window must not stretch a 10 s interval');
  });

  test('detection: every repeater that answers inside the 10 s window is recorded, and a longer listen catches repeats still arriving', () {
    final r = runReplay(build: appStack(), seed: 3, driveSeconds: 7200, backgroundEverySec: 4);
    report('app/busy/chat-2h', r);
    expect(r.detection(), 1.0, reason: 'nothing the radio reported inside the window is lost, busy channel or not');
    expect(r.lateEchoes, greaterThan(0), reason: 'repeats that arrive after 7 s while others were still coming are kept');
    // The world also holds repeats up to 12 s after the send; those that came in a burst are caught, isolated stragglers
    // are not (a hard ceiling keeps the next ping on time). The share is a floor, not a promise:
    expect(r.detection(withinMs: 13000), greaterThan(0.9));
  });

  test('a quiet channel and a busy one record the same pings (the message sync does not starve or delay them)', () {
    final quiet = runReplay(build: appStack(chat: false), seed: 3);
    final busy = runReplay(build: appStack(), seed: 3, backgroundEverySec: 1.5, bleLatencyMs: 200);
    report('app/quiet', quiet);
    report('app/busy-200ms', busy);
    expect(busy.pingsSent, quiet.pingsSent);
    expect(busy.detection(), quiet.detection());
    expect(busy.sendGaps().reduce((a, b) => a > b ? a : b), lessThan(15.6));
    expect(busy.radio.syncCommands, greaterThan(500), reason: 'the busy case really drained a lot of messages');
  });

  test('a ping is not early or late when the radio answers slowly (350 ms per command)', () {
    final r = runReplay(build: appStack(), seed: 5, driveSeconds: 900, bleLatencyMs: 350, backgroundEverySec: 3);
    final g = r.sendGaps();
    expect(g.reduce((a, b) => a > b ? a : b), lessThan(15.8));
    expect(g.reduce((a, b) => a < b ? a : b), greaterThan(14.3));
  });

  test('a phone whose "current position" call stalls 12 s does not stretch the cadence (4 s timeout, then the stream\'s fix)', () {
    final r = runReplay(build: appStack(), seed: 5, driveSeconds: 900, currentDelay: const Duration(seconds: 12));
    report('app/slow-current-position', r);
    expect(r.pingsSent, inInclusiveRange(59, 61), reason: '900 s / 15 s, and the first goes out at once (it used to wait out the 4 s platform timeout)');
    expect(r.sendGaps().reduce((a, b) => a > b ? a : b), lessThan(15.6));
  });
}
