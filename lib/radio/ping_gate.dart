// What the wardrive engine asks before it transmits a ping. The TxArbiter (tx_arbiter.dart) answers; tests and
// non-session setups use [AlwaysGoPingGate] (= today's behaviour: the engine's own interval/distance rule only).
import 'dart:async';

/// Why a ping was not sent. Shown to the driver as "Ping skipped: ..." and counted; a skipped ping is NEVER queued late
/// (a ping that goes out 20 s after its place on the road is at the wrong place).
enum PingSkipReason {
  /// The radio's outbound packet queue is not empty (GET_STATS core queue_len > 0).
  radioQueueBusy,

  /// The user sent a message less than 2 s ago: let its repeats be heard first.
  userSendRecent,

  /// Ping airtime over the rolling 10 minutes would pass 2% of wall time.
  pingBudget,

  /// Own transmit time over the rolling hour would pass the region cap.
  hourlyCap,
}

class PingDecision {
  final bool go;
  final PingSkipReason? reason;

  /// One plain sentence for the status line ("Ping skipped: the radio is busy sending a message").
  final String message;
  const PingDecision.go() : go = true, reason = null, message = '';
  const PingDecision.skip(PingSkipReason this.reason, this.message) : go = false;

  @override
  String toString() => go ? 'PingDecision.go' : 'PingDecision.skip(${reason!.name})';
}

abstract class PingGate {
  /// May the engine transmit a ping now? [manual] is a ping the driver asked for with the button: it still waits for a
  /// busy radio and a just-sent user message, but is not held back by the airtime budgets (the driver chose it).
  /// [airtimeMs] is the ping's estimated time on air, or null to let the gate estimate it.
  FutureOr<PingDecision> requestPing({bool manual = false, int? airtimeMs});

  /// The engine sent a ping that took [airtimeMs] on air (estimate), for the ledger.
  void pingSent({int? airtimeMs});
}

class AlwaysGoPingGate implements PingGate {
  const AlwaysGoPingGate();
  @override
  FutureOr<PingDecision> requestPing({bool manual = false, int? airtimeMs}) => const PingDecision.go();
  @override
  void pingSent({int? airtimeMs}) {}
}

/// Thrown by a manual ping the gate refused (the driver pressed Ping while the radio was busy sending a message).
class PingSkippedException implements Exception {
  final PingDecision decision;
  PingSkippedException(this.decision);
  @override
  String toString() => decision.message;
}
