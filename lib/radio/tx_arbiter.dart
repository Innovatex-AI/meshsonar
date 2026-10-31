// TxArbiter: decides who may transmit on the one radio, and keeps the airtime ledger. Rules: design doc C section 7 and
// doc B section 8 (meshsonar-infra/docs/planning/).
//
//   P0 user message   never delayed by anything here, not even the budgets (at the region cap the caller is only warned)
//   P1 ack / login / status / trace / sync
//   P2 self advert
//   P3 wardrive ping
//   P4 discovery
//
// The command queue (command_queue.dart) orders waiting commands by these classes; this class answers the question the
// queue cannot: "may a ping go out at all right now". A ping is issued only if
//   - the radio's own outbound queue is empty (GET_STATS core queue_len == 0, MyMesh.cpp 1914-1923),
//   - no user message was sent in the last 2 s (let its repeats be heard first),
//   - ping airtime in the rolling 10 minutes stays under 2% of wall time,
//   - all own transmit time in the rolling hour stays under the region cap (unknown region: 1%, the CLI doc's
//     "strictest EU requirement", docs/cli_commands.md:574),
//   - and the engine's own distance/time rule is met (the engine checks that itself).
// Otherwise the ping is SKIPPED with a reason; it is never queued for later.
//
// "Arbiter idle" (nobody chatting) = [chatActive] false: then the radio-queue probe and the two budgets are off and every
// ping is a go, exactly the behaviour before sessions existed. The 2 s rule has nothing to act on without user sends.
// The caps are policy defaults, not legal advice.
import 'dart:async';
import 'dart:collection';

import 'airtime.dart';
import 'command_queue.dart';
import 'ping_gate.dart';

/// The five transmit classes (value = [CommandPriority]).
enum TxPriority {
  user(CommandPriority.user),
  admin(CommandPriority.admin),
  advert(CommandPriority.advert),
  ping(CommandPriority.ping),
  discovery(CommandPriority.discovery);

  final int value;
  const TxPriority(this.value);
}

/// The numbers behind the rules. Defaults are design doc C section 7.
class TxPolicy {
  /// Ping airtime allowed in [pingWindow], as a fraction of wall time.
  final double pingBudgetFraction;
  final Duration pingWindow;

  /// All own transmit time allowed in [capWindow], as a fraction of wall time (the region cap).
  final double capFraction;
  final Duration capWindow;

  /// No ping this soon after a user send.
  final Duration userSendGap;

  /// How long the queue_len probe may take before the ping goes anyway (a lost reply is not a busy radio).
  final Duration probeTimeout;

  const TxPolicy({
    this.pingBudgetFraction = 0.02,
    this.pingWindow = const Duration(minutes: 10),
    this.capFraction = 0.01,
    this.capWindow = const Duration(hours: 1),
    this.userSendGap = const Duration(seconds: 2),
    this.probeTimeout = const Duration(seconds: 3),
  });

  TxPolicy copyWith({double? capFraction}) => TxPolicy(
        pingBudgetFraction: pingBudgetFraction,
        pingWindow: pingWindow,
        capFraction: capFraction ?? this.capFraction,
        capWindow: capWindow,
        userSendGap: userSendGap,
        probeTimeout: probeTimeout,
      );
}

/// LoRa settings of the connected radio (SELF_INFO), for airtime estimates.
class RadioAirParams {
  final int sf;
  final double bwKhz;
  final int cr;
  const RadioAirParams(this.sf, this.bwKhz, this.cr);

  double airtimeMs(int payloadBytes) => loraAirtimeMs(payloadBytes: payloadBytes, sf: sf, bwKhz: bwKhz, cr: cr);
}

class _Entry {
  final DateTime at;
  final TxPriority cls;
  final double ms;
  _Entry(this.at, this.cls, this.ms);
}

/// What the ledger holds now (for the Drive screen's budget readout and the debug screen).
class TxLedgerSnapshot {
  /// Ping airtime in the last [TxPolicy.pingWindow], ms.
  final double pingMsInWindow;

  /// All own transmit time in the last [TxPolicy.capWindow], ms.
  final double totalMsInCapWindow;

  /// Pings the arbiter refused, by reason, since the session started.
  final Map<PingSkipReason, int> skipped;
  final int pingsSent;
  final int userSends;
  const TxLedgerSnapshot(this.pingMsInWindow, this.totalMsInCapWindow, this.skipped, this.pingsSent, this.userSends);
}

class TxArbiter implements PingGate {
  final DateTime Function() _clock;
  TxPolicy policy;

  /// Radio queue probe: the radio's outbound queue length, or null when it could not be read. Set by the session.
  Future<int?> Function()? queueProbe;

  /// LoRa settings, for estimates; null = unknown (a conservative estimate is used).
  RadioAirParams? Function()? airParams;

  /// Bytes of the radio's name (the ping text on air is "name: MS:xxxxxxxxxx").
  int Function()? senderNameBytes;

  /// The chat layer is in use: probe the radio queue and enforce the budgets. Off = wardrive-only behaviour.
  bool chatActive = false;

  final Queue<_Entry> _ledger = Queue();
  DateTime? _lastUserSend;
  final Map<PingSkipReason, int> _skipped = {};
  int _pings = 0;
  int _users = 0;

  TxArbiter({DateTime Function()? clock, this.policy = const TxPolicy(), this.queueProbe, this.airParams, this.senderNameBytes})
      : _clock = clock ?? DateTime.now;

  /// "MS:" + 10 characters (wardrive_engine.dart formatPingText).
  static const int pingTextBytes = 13;

  /// Estimated time on air of one ping, ms. Without known radio settings: 500 ms, above SF8/BW62.5 (386 ms with MeshCore's
  /// 32-symbol preamble) and below SF11/BW250, rounded up so an unknown radio is budgeted cautiously.
  double estimatePingMs() {
    final p = airParams?.call();
    if (p == null) return 500;
    final name = senderNameBytes?.call() ?? 8;
    return p.airtimeMs(groupTextPacketBytes(name + 2 + pingTextBytes));
  }

  /// Estimated time on air of a user channel message with [textBytes] bytes of text, ms.
  double estimateChannelMs(int textBytes) {
    final p = airParams?.call();
    if (p == null) return 500;
    final name = senderNameBytes?.call() ?? 8;
    return p.airtimeMs(groupTextPacketBytes(name + 2 + textBytes));
  }

  /// Estimated time on air of a direct message, ms.
  double estimateDirectMs(int textBytes) {
    final p = airParams?.call();
    if (p == null) return 500;
    return p.airtimeMs(directTextPacketBytes(textBytes));
  }

  void _prune(DateTime now) {
    final horizon = now.subtract(policy.capWindow > policy.pingWindow ? policy.capWindow : policy.pingWindow);
    while (_ledger.isNotEmpty && _ledger.first.at.isBefore(horizon)) {
      _ledger.removeFirst();
    }
  }

  /// Records a transmission of class [cls] that took [ms] on air.
  void recordTx(TxPriority cls, double ms, {DateTime? at}) {
    final now = at ?? _clock();
    _prune(now);
    _ledger.addLast(_Entry(now, cls, ms));
  }

  /// A user message goes out now. Never refused and never delayed: it is only recorded. Returns true when it pushes the
  /// hour over the region cap, so the UI can warn (the radio's own duty-cycle limiter still applies).
  bool admitUserSend(double airtimeMs) {
    final now = _clock();
    _lastUserSend = now;
    _users++;
    recordTx(TxPriority.user, airtimeMs, at: now);
    return _msInWindow(now, policy.capWindow, null) > policy.capFraction * policy.capWindow.inMilliseconds;
  }

  double _msInWindow(DateTime now, Duration window, TxPriority? cls) {
    final from = now.subtract(window);
    var sum = 0.0;
    for (final e in _ledger) {
      if (e.at.isBefore(from)) continue;
      if (cls != null && e.cls != cls) continue;
      sum += e.ms;
    }
    return sum;
  }

  TxLedgerSnapshot snapshot() {
    final now = _clock();
    return TxLedgerSnapshot(_msInWindow(now, policy.pingWindow, TxPriority.ping), _msInWindow(now, policy.capWindow, null),
        Map.unmodifiable(_skipped), _pings, _users);
  }

  PingSkipReason? _lastSkip;
  DateTime? _lastSkipAt;

  /// The most recent reason a ping was refused, until a ping goes out again (null if none since). For the System
  /// channel row: "paused by the airtime budget".
  PingSkipReason? get lastSkipReason => _lastSkip;
  DateTime? get lastSkipAt => _lastSkipAt;

  /// True while the airtime budget (not a busy radio) is what is holding pings back: the last decision was a budget or
  /// cap skip within [within] and no ping has gone out since.
  bool pausedByBudget({Duration within = const Duration(minutes: 2)}) {
    final r = _lastSkip, at = _lastSkipAt;
    if (r == null || at == null) return false;
    return (r == PingSkipReason.pingBudget || r == PingSkipReason.hourlyCap) && _clock().difference(at) <= within;
  }

  PingDecision _skip(PingSkipReason r, String message) {
    _lastSkip = r;
    _lastSkipAt = _clock();
    _skipped[r] = (_skipped[r] ?? 0) + 1;
    return PingDecision.skip(r, message);
  }

  @override
  FutureOr<PingDecision> requestPing({bool manual = false, int? airtimeMs}) async {
    final now = _clock();
    final last = _lastUserSend;
    if (last != null && now.difference(last) < policy.userSendGap) {
      return _skip(PingSkipReason.userSendRecent, 'Ping skipped: a message was just sent');
    }
    if (!chatActive) return const PingDecision.go();

    final probe = queueProbe;
    if (probe != null) {
      int? q;
      try {
        q = await probe().timeout(policy.probeTimeout);
      } catch (_) {
        q = null; // a lost or late reply is not evidence of a busy radio
      }
      if (q != null && q > 0) return _skip(PingSkipReason.radioQueueBusy, 'Ping skipped: the radio is busy sending');
      // Time moved while we waited for the radio; a user message may have been sent meanwhile.
      final again = _lastUserSend;
      if (again != null && _clock().difference(again) < policy.userSendGap) {
        return _skip(PingSkipReason.userSendRecent, 'Ping skipped: a message was just sent');
      }
    }

    if (manual) return const PingDecision.go();
    final t = _clock();
    _prune(t);
    final est = airtimeMs?.toDouble() ?? estimatePingMs();
    final pingUsed = _msInWindow(t, policy.pingWindow, TxPriority.ping);
    if (pingUsed + est > policy.pingBudgetFraction * policy.pingWindow.inMilliseconds) {
      return _skip(PingSkipReason.pingBudget, 'Ping skipped: ping airtime budget used up for now');
    }
    final total = _msInWindow(t, policy.capWindow, null);
    if (total + est > policy.capFraction * policy.capWindow.inMilliseconds) {
      return _skip(PingSkipReason.hourlyCap, 'Ping skipped: transmit-time cap for this hour reached');
    }
    return const PingDecision.go();
  }

  @override
  void pingSent({int? airtimeMs}) {
    _pings++;
    _lastSkip = null;
    _lastSkipAt = null;
    recordTx(TxPriority.ping, airtimeMs?.toDouble() ?? estimatePingMs());
  }
}
