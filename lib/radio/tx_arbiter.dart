// TxArbiter: decides who may transmit on the one radio, and keeps the airtime ledger. Rules: design doc C section 7 and
// doc B section 8 (meshsonar-infra/docs/planning/).
//
//   P0 user message   never delayed by anything here, not even the budgets (at the region cap the caller is only warned)
//   P1 ack / login / status / trace / sync
//   P2 self advert
//   P3 wardrive ping, and MeshTrack position messages (TxPriority.track: same class value, its own ledger rows and budget)
//   P4 discovery
//
// The command queue (command_queue.dart) orders waiting commands by these classes; this class answers the question the
// queue cannot: "may a ping go out at all right now". A ping is issued only if
//   - the radio's own outbound queue is empty (GET_STATS core queue_len == 0, MyMesh.cpp 1914-1923),
//   - no user message was sent in the last 2 s (let its repeats be heard first),
//   - ping airtime in the rolling 10 minutes stays under 2% of wall time,
//   - all own transmit time in the rolling hour stays under the region cap, WHEN the region's cap is known (unknown region:
//     no cap holds pings back; the 1% figure only warns after a user message. Oct 31 2026: the old 1% default skipped a
//     third of a 15 s drive and left 15-minute holes),
//   - and the engine's own distance/time rule is met (the engine checks that itself).
// Otherwise the ping is SKIPPED with a reason; it is never queued for later.
//
// MeshTrack (meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md section 4): a track message may go only if
//   - no user message and no ping went out in the last 2 s (gap),
//   - track airtime in the rolling 10 minutes stays at or under 1% of wall time (budget), checked always, chat or not,
//   - all own transmit time in the rolling hour stays under the region cap, WHEN known (same rule as pings).
// A refused track send is SKIPPED, never queued: the MeshTrack service re-asks at the next fix. Pings get the same 2 s
// gap after a track send that they get after a user send. [TxArbiter.requestTrack] asks without side effects on the
// ledger; [TxArbiter.runTrackSend] wraps the actual send so the session's own airtime record counts it as track, not user.
//
// "Arbiter idle" (nobody chatting) = no user message in the last [TxPolicy.chatWindow] (or [chatActive] false): then the
// radio-queue probe and the budgets are off and every ping is a go, exactly the behaviour before sessions existed. Binding
// the chat layer to the radio is not chatting. The 2 s rule has nothing to act on without user sends.
// The caps are policy defaults, not legal advice.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'airtime.dart';
import 'command_queue.dart';
import 'ping_gate.dart';

/// The five transmit classes (value = [CommandPriority]).
enum TxPriority {
  user(CommandPriority.user),
  admin(CommandPriority.admin),
  advert(CommandPriority.advert),
  ping(CommandPriority.ping),

  /// MeshTrack position / request / meet-up / stop messages: queued like a ping, budgeted on their own ledger rows.
  track(CommandPriority.ping),
  discovery(CommandPriority.discovery);

  final int value;
  const TxPriority(this.value);
}

/// The numbers behind the rules. Defaults are design doc C section 7.
class TxPolicy {
  /// Ping airtime allowed in [pingWindow], as a fraction of wall time.
  final double pingBudgetFraction;
  final Duration pingWindow;

  /// All own transmit time allowed in [capWindow], as a fraction of wall time (the region cap). Only a cap that is KNOWN
  /// for the region holds pings back; the default 1.0 (= 100%) means "no cap known", so a wardrive is never throttled by
  /// a guess (Oct 31 2026 field report: the old unknown-region 1% skipped a third of a 15 s drive's pings).
  final double capFraction;

  /// The share of the hour to show "own airtime" against: the region cap when one is known, else the 1% warning level.
  double get shownCapFraction => capFraction < 1.0 ? capFraction : userWarnFraction;

  /// A user message that takes the hour past this share of wall time only earns the caller a warning (never a refusal).
  final double userWarnFraction;
  final Duration capWindow;

  /// No ping this soon after a user send.
  final Duration userSendGap;

  /// After a user message the ping rules above (radio queue probe, 2% budget) stay on this long; with no chat sent for
  /// this long a drive is a plain drive and pings follow the driver's cadence alone.
  final Duration chatWindow;

  /// How long the queue_len probe may take before the ping goes anyway (a lost reply is not a busy radio).
  final Duration probeTimeout;

  /// MeshTrack airtime allowed in [pingWindow] (the rolling 10 minutes), as a fraction of wall time. Inclusive limit.
  final double trackBudgetFraction;

  const TxPolicy({
    this.pingBudgetFraction = 0.02,
    this.pingWindow = const Duration(minutes: 10),
    this.capFraction = 1.0,
    this.userWarnFraction = 0.01,
    this.capWindow = const Duration(hours: 1),
    this.userSendGap = const Duration(seconds: 2),
    this.chatWindow = const Duration(minutes: 10),
    this.probeTimeout = const Duration(seconds: 3),
    this.trackBudgetFraction = 0.01,
  });

  TxPolicy copyWith({double? capFraction, Duration? chatWindow}) => TxPolicy(
        pingBudgetFraction: pingBudgetFraction,
        pingWindow: pingWindow,
        capFraction: capFraction ?? this.capFraction,
        userWarnFraction: userWarnFraction,
        capWindow: capWindow,
        userSendGap: userSendGap,
        chatWindow: chatWindow ?? this.chatWindow,
        probeTimeout: probeTimeout,
        trackBudgetFraction: trackBudgetFraction,
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

  /// MeshTrack airtime in the last [TxPolicy.pingWindow], ms.
  final double trackMsInWindow;

  /// MeshTrack sends recorded, and the ones the arbiter refused by reason, since the session started.
  final int trackSent;
  final Map<TrackSkipReason, int> trackSkipped;
  const TxLedgerSnapshot(this.pingMsInWindow, this.totalMsInCapWindow, this.skipped, this.pingsSent, this.userSends,
      {this.trackMsInWindow = 0, this.trackSent = 0, this.trackSkipped = const {}});
}

/// Why a MeshTrack send was refused. The send is skipped, never queued; the service re-asks at the next fix.
enum TrackSkipReason {
  /// MeshTrack airtime in the rolling 10 minutes would pass 1% of wall time.
  budget,

  /// Own transmit time in the rolling hour would pass the region's known cap.
  regionCap,

  /// A user message or a ping went out less than 2 s ago: let its repeats be heard first.
  gap,
}

/// The arbiter's answer to "may I send a MeshTrack message of N bytes now?".
class TrackDecision {
  final bool go;
  final TrackSkipReason? reason;

  /// One plain line for diagnostics or the Group sheet ("Sharing slower: airtime limit"); empty on go.
  final String message;

  /// The estimated time on air of the asked-for message, ms.
  final double estimateMs;
  const TrackDecision.go(this.estimateMs)
      : go = true,
        reason = null,
        message = '';
  const TrackDecision.skip(TrackSkipReason this.reason, this.message, this.estimateMs) : go = false;

  /// True when the airtime budget or the region cap (not a short gap) refused it: the Group sheet's "Sharing slower".
  bool get airtimeLimited => reason == TrackSkipReason.budget || reason == TrackSkipReason.regionCap;

  @override
  String toString() => go ? 'TrackDecision.go' : 'TrackDecision.skip(${reason!.name})';
}

/// What the chat layer needs from the arbiter to send a MeshTrack message without a chat bubble.
abstract interface class TrackTxGate {
  /// May a MeshTrack message with [textBytes] bytes of body go now? Never queues; a refusal is counted.
  TrackDecision requestTrack(int textBytes);

  /// Runs [send] (the actual radio send of [textBytes] body bytes) as a track transmission and records it on the ledger.
  Future<T> runTrackSend<T>(int textBytes, Future<T> Function() send);
}

/// Zone marker for [TxArbiter.runTrackSend]: the session's admitUserSend inside it records a track send.
class _TrackScope {
  final TxArbiter owner;
  bool recorded = false;
  _TrackScope(this.owner);
}

class TxArbiter implements PingGate, TrackTxGate {
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
  DateTime? _lastPingSend;
  DateTime? _lastTrackSend;
  final Map<PingSkipReason, int> _skipped = {};
  final Map<TrackSkipReason, int> _trackSkipped = {};
  int _pings = 0;
  int _users = 0;
  int _tracks = 0;

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

  /// Estimated time on air of a MeshTrack message with [textBytes] bytes of body (the firmware adds "name: "), ms. Same
  /// packet as any channel text (GRP_TXT).
  double estimateTrackMs(int textBytes) => estimateChannelMs(textBytes);

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
  ///
  /// Inside [runTrackSend] (the MeshTrack silent send goes through the same session call as a user message) the send is
  /// recorded as [TxPriority.track] instead, never as a user message, and no warning is returned.
  bool admitUserSend(double airtimeMs) {
    final scope = Zone.current[_TrackScope];
    if (scope is _TrackScope && identical(scope.owner, this) && !scope.recorded) {
      scope.recorded = true;
      trackSent(airtimeMs);
      return false;
    }
    final now = _clock();
    _lastUserSend = now;
    _users++;
    recordTx(TxPriority.user, airtimeMs, at: now);
    return _msInWindow(now, policy.capWindow, null) > policy.userWarnFraction * policy.capWindow.inMilliseconds;
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
        Map.unmodifiable(_skipped), _pings, _users,
        trackMsInWindow: _msInWindow(now, policy.pingWindow, TxPriority.track), trackSent: _tracks, trackSkipped: Map.unmodifiable(_trackSkipped));
  }

  // ------------------------------------------------------------------ MeshTrack

  TrackSkipReason? _lastTrackSkip;
  DateTime? _lastTrackSkipAt;

  /// The most recent reason a MeshTrack send was refused, until one goes out again (null if none since).
  TrackSkipReason? get lastTrackSkipReason => _lastTrackSkip;
  DateTime? get lastTrackSkipAt => _lastTrackSkipAt;

  /// True while the airtime budget or the region cap is what holds MeshTrack back: the last decision was such a skip within
  /// [within] and no track message has gone out since. The Group sheet shows "Sharing slower: airtime limit".
  bool trackSlowedByBudget({Duration within = const Duration(minutes: 10)}) {
    final r = _lastTrackSkip, at = _lastTrackSkipAt;
    if (r == null || at == null) return false;
    return (r == TrackSkipReason.budget || r == TrackSkipReason.regionCap) && _clock().difference(at) <= within;
  }

  TrackDecision _trackSkip(TrackSkipReason r, String message, double est) {
    _lastTrackSkip = r;
    _lastTrackSkipAt = _clock();
    _trackSkipped[r] = (_trackSkipped[r] ?? 0) + 1;
    return TrackDecision.skip(r, message, est);
  }

  /// "May I send a MeshTrack message with [textBytes] bytes of body now?" Synchronous, never queues, never waits; the only
  /// side effect is the skip counter. Rules in the header comment.
  @override
  TrackDecision requestTrack(int textBytes) {
    final now = _clock();
    final est = estimateTrackMs(textBytes);
    final u = _lastUserSend, p = _lastPingSend;
    if ((u != null && now.difference(u) < policy.userSendGap) || (p != null && now.difference(p) < policy.userSendGap)) {
      return _trackSkip(TrackSkipReason.gap, 'Position waits: the radio just sent', est);
    }
    _prune(now);
    final used = _msInWindow(now, policy.pingWindow, TxPriority.track);
    if (used + est > policy.trackBudgetFraction * policy.pingWindow.inMilliseconds) {
      return _trackSkip(TrackSkipReason.budget, 'Sharing slower: airtime limit', est);
    }
    final total = _msInWindow(now, policy.capWindow, null);
    if (total + est > policy.capFraction * policy.capWindow.inMilliseconds) {
      return _trackSkip(TrackSkipReason.regionCap, 'Sharing slower: airtime limit', est);
    }
    return TrackDecision.go(est);
  }

  /// Same as [requestTrack] for a body given as text (its UTF-8 bytes).
  TrackDecision requestTrackText(String body) => requestTrack(utf8.encode(body).length);

  /// Records a MeshTrack transmission that took [ms] on air (estimate).
  void trackSent(double ms) {
    _tracks++;
    _lastTrackSend = _clock();
    _lastTrackSkip = null;
    _lastTrackSkipAt = null;
    recordTx(TxPriority.track, ms);
  }

  /// Runs [send] as a MeshTrack transmission of [textBytes] body bytes. A session send inside it that calls
  /// [admitUserSend] is recorded as track (not as a user message); if nothing inside recorded it and [send] completed, the
  /// estimate is recorded here. A send that throws before anything was recorded leaves the ledger alone.
  @override
  Future<T> runTrackSend<T>(int textBytes, Future<T> Function() send) async {
    final scope = _TrackScope(this);
    final r = await runZoned(send, zoneValues: {_TrackScope: scope});
    if (!scope.recorded) {
      scope.recorded = true;
      trackSent(estimateTrackMs(textBytes));
    }
    return r;
  }

  /// True while the person is chatting: [chatActive] AND (no message sent yet, or the last one is younger than
  /// [TxPolicy.chatWindow]). Merely having the chat layer bound to the radio is not chatting.
  bool _chatInUse(DateTime now) {
    if (!chatActive) return false;
    final last = _lastUserSend;
    return last != null && now.difference(last) < policy.chatWindow;
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
    final track = _lastTrackSend;
    if (track != null && now.difference(track) < policy.userSendGap) {
      return _skip(PingSkipReason.userSendRecent, 'Ping skipped: a position was just shared');
    }
    if (!_chatInUse(now)) return const PingDecision.go();

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
      final trackAgain = _lastTrackSend;
      if (trackAgain != null && _clock().difference(trackAgain) < policy.userSendGap) {
        return _skip(PingSkipReason.userSendRecent, 'Ping skipped: a position was just shared');
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
    _lastPingSend = _clock();
    _lastSkip = null;
    _lastSkipAt = null;
    recordTx(TxPriority.ping, airtimeMs?.toDouble() ?? estimatePingMs());
  }
}
