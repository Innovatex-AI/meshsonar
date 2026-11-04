// Ping: "is this contact reachable, by which route, and how fast". A person is pinged with a path discovery (CMD 52, floods,
// the answer carries the fresh route out and back, spike S12); a repeater, room or sensor with a trace along the saved route
// (CMD 36, per-hop SNR). Every outcome is a [PingResult], never an exception. Pure Dart.
import 'dart:async';

import '../command_queue.dart';
import '../crypto.dart';
import '../path_tools.dart';
import '../protocol.dart';
import '../tx_arbiter.dart';
import 'tool_frames.dart';
import 'tools_radio.dart';
import 'trace_tool.dart';

enum PingMethod { discovery, trace, zeroHop }

enum PingStatus {
  ok,

  /// The radio sent it and nothing came back in time.
  noReply,

  /// The radio refused (does not hold the contact, busy, bad path).
  refused,

  /// The firmware does not know the command (ERR 1).
  unsupported,
  notConnected,

  /// Another ping or trace is running or ran a moment ago.
  tooSoon,

  /// Nothing to send (no route and not direct only).
  invalid,
}

class PingResult {
  final PingMethod kind;
  final PingStatus status;
  final DateTime at;

  /// Round trip in ms (discovery: SENT to push; trace: command to answer).
  final int? rttMs;

  /// Route out and back as the radio reported it (discovery) or as sent (trace: out only, back is its mirror).
  final PathRoute? outRoute;
  final PathRoute? backRoute;

  /// SNR at each hop (dB), then the final SNR at this radio.
  final List<double> hopSnrDb;
  final double? finalSnrDb;

  /// The hop names for a trace, in order (aligned with [hopSnrDb]).
  final List<String> hopNames;

  /// The wait the UI showed ("up to 12 s").
  final int? waitedMs;
  final String? detail;

  const PingResult({
    required this.kind,
    required this.status,
    required this.at,
    this.rttMs,
    this.outRoute,
    this.backRoute,
    this.hopSnrDb = const [],
    this.finalSnrDb,
    this.hopNames = const [],
    this.waitedMs,
    this.detail,
  });

  bool get ok => status == PingStatus.ok;

  /// Repeaters between us and them on the way out.
  int? get repeaters => outRoute?.length ?? (hopNames.isEmpty ? null : (hopNames.length - 1).clamp(0, 99));

  /// Short reason stored in `ping_results.fail_reason`; null when ok.
  String? get failReason => ok ? null : status.name;
}

/// Maps a trace outcome to a ping result. [targetIsLast]: the last trace stop is the contact itself.
PingResult pingFromTrace(TraceResult t, {required PingMethod kind, PathRoute? route, bool targetIsLast = true}) {
  PingStatus st = switch (t.status) {
    TraceStatus.ok => PingStatus.ok,
    TraceStatus.silent => PingStatus.noReply,
    TraceStatus.refused => PingStatus.refused,
    TraceStatus.notConnected => PingStatus.notConnected,
    TraceStatus.tooSoon => PingStatus.tooSoon,
    TraceStatus.invalid => PingStatus.invalid,
  };
  return PingResult(
    kind: kind,
    status: st,
    at: t.at,
    rttMs: st == PingStatus.ok ? t.elapsed?.inMilliseconds : null,
    outRoute: route,
    backRoute: route?.reversed,
    hopSnrDb: [for (final h in t.hops) if (h.snrDb != null) h.snrDb!],
    finalSnrDb: t.finalSnrDb,
    hopNames: [for (final h in t.hops) h.stop.name],
    waitedMs: t.estTimeoutMs,
    detail: t.detail,
  );
}

/// Maps a discovery push (or silence) to a ping result.
PingResult pingFromDiscovery(PathDiscoveryPush? p, {required DateTime at, int? rttMs, int? waitedMs}) {
  if (p == null) return PingResult(kind: PingMethod.discovery, status: PingStatus.noReply, at: at, waitedMs: waitedMs);
  return PingResult(
    kind: PingMethod.discovery,
    status: PingStatus.ok,
    at: at,
    rttMs: rttMs,
    outRoute: decodePath(p.outPathLen, p.outPath) ?? PathRoute(1, const []),
    backRoute: decodePath(p.inPathLen, p.inPath) ?? PathRoute(1, const []),
    waitedMs: waitedMs,
  );
}

class PingTool {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final TraceTool traceTool;
  final DateTime Function() _clock;
  final Duration waitSlack;
  final Duration minWait;
  final Duration maxWait;
  bool _running = false;

  PingTool(this.radio, this.arbiter, this.traceTool,
      {DateTime Function()? clock,
      this.waitSlack = const Duration(seconds: 4),
      this.minWait = const Duration(seconds: 8),
      this.maxWait = const Duration(seconds: 45)})
      : _clock = clock ?? DateTime.now;

  bool get running => _running;

  /// Path discovery to [keyHex] (a person). Floods, so it costs airtime: the UI says so the first time.
  Future<PingResult> discover(String keyHex) async {
    final now = _clock();
    PingResult fail(PingStatus s, [String? d]) => PingResult(kind: PingMethod.discovery, status: s, at: now, detail: d);
    if (!radio.isConnected) return fail(PingStatus.notConnected, 'No radio is connected.');
    if (_running) return fail(PingStatus.tooSoon, 'A ping is already running.');
    _running = true;
    final c = Completer<PathDiscoveryPush?>();
    final prefix = keyHex.toLowerCase().substring(0, 12);
    final sub = radio.pushes.listen((f) {
      final p = PathDiscoveryPush.tryParse(f);
      if (p != null && p.prefixHex == prefix && !c.isCompleted) c.complete(p);
    });
    Timer? timer;
    try {
      final sw = Stopwatch()..start();
      final Frame reply;
      try {
        reply = await radio.send(encodePathDiscoveryReq(fromHex(keyHex)), priority: CommandPriority.admin);
      } on TimeoutException {
        return fail(PingStatus.noReply, 'The radio did not answer the command.');
      } on StateError {
        return fail(PingStatus.notConnected, 'The radio disconnected.');
      }
      if (reply is ErrFrame) {
        if (reply.code == ErrCode.unsupportedCmd) return fail(PingStatus.unsupported, 'This radio\'s firmware cannot search for a route.');
        if (reply.code == ErrCode.notFound) return fail(PingStatus.refused, 'The radio does not have this contact.');
        return fail(PingStatus.refused, 'The radio refused.');
      }
      if (reply is! SentFrame) return fail(PingStatus.refused, 'The radio gave an unexpected answer.');
      arbiter.recordTx(TxPriority.admin, 300);
      final wait = Duration(milliseconds: (reply.estTimeoutMs + waitSlack.inMilliseconds).clamp(minWait.inMilliseconds, maxWait.inMilliseconds));
      timer = Timer(wait, () {
        if (!c.isCompleted) c.complete(null);
      });
      sw.reset();
      final p = await c.future;
      sw.stop();
      return pingFromDiscovery(p, at: now, rttMs: p == null ? null : sw.elapsedMilliseconds + 0, waitedMs: wait.inMilliseconds);
    } finally {
      timer?.cancel();
      unawaited(sub.cancel());
      _running = false;
    }
  }

  /// Trace to a node. [route] is the saved route (hops between us and the node); [directOnly] sends only the node's own hash
  /// (zero repeaters). [known] names the hashes. Hash size is the route's, folded into what a trace can carry (1, 2 or 4).
  Future<PingResult> trace({
    required String keyHex,
    required String name,
    PathRoute? route,
    bool directOnly = false,
    int hashSize = 1,
    Iterable<TraceStop> known = const [],
  }) async {
    final now = _clock();
    final kind = directOnly || route == null || route.isEmpty ? PingMethod.zeroHop : PingMethod.trace;
    final target = TraceStop(name: name, keyHex: keyHex);
    final stops = <TraceStop>[];
    var size = directOnly ? hashSize : (route == null || route.isEmpty ? hashSize : route.hashSize);
    if (!directOnly && route != null) {
      for (final h in route.hexHops) {
        final hit = known.where((k) => k.keyHex.toLowerCase().startsWith(h)).firstOrNull;
        stops.add(hit ?? TraceStop(name: 'Repeater $h', keyHex: h.padRight(64, '0')));
      }
    }
    stops.add(target);
    if (size == 3) size = stops.every((s) => !s.keyHex.endsWith('0' * 8)) ? 4 : 2;
    if (!traceHashSizes.contains(size)) size = 2;
    if (_running) return PingResult(kind: kind, status: PingStatus.tooSoon, at: now, detail: 'A ping is already running.');
    _running = true;
    try {
      final t = await traceTool.run(stops, hashSize: size, known: const []);
      return pingFromTrace(t, kind: kind, route: directOnly ? null : route);
    } finally {
      _running = false;
    }
  }
}
