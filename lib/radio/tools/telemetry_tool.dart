// Telemetry: ask a contact (or this radio) for its sensor readings and decode them.
//
// Contact: CMD_SEND_TELEMETRY_REQ with the key -> SENT (est timeout), then PUSH_CODE_TELEMETRY_RESPONSE with Cayenne LPP,
// BIG endian (VERIFIED on hardware: 0.63-0.72 s, battery 3.86 V and MCU temperature 45.0 C from a repeater; a guest login
// gets base telemetry only). Silence is the failure signal, so the wait comes from est_timeout. Self: the 4-byte form.
// A position in the readings (LPP type 136) is shown to the person who asked and never uploaded or stored.
// Pure Dart.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../command_queue.dart';
import '../crypto.dart';
import '../inbound.dart';
import '../protocol.dart';
import '../remote_request_queue.dart';
import '../tx_arbiter.dart';
import 'lpp.dart';
import 'tool_frames.dart';
import 'tool_state.dart';
import 'tools_radio.dart';

enum TelemetryStatus { ok, empty, silent, noContact, refused, notConnected, tooSoon }

class TelemetryResult {
  final TelemetryStatus status;
  final String who;
  final String? keyHex;
  final bool isSelf;
  final DateTime at;
  final List<LppReading> readings;
  final String? detail;
  const TelemetryResult(this.status, this.who, this.at, {this.keyHex, this.isSelf = false, this.readings = const [], this.detail});

  bool get ok => status == TelemetryStatus.ok;
  LppReading? reading(LppKind k) => readings.where((r) => r.kind == k).firstOrNull;
  LppReading? get battery => reading(LppKind.voltage);
  LppReading? get temperature => reading(LppKind.temperature);
  LppReading? get position => reading(LppKind.gps);

  /// What came back, sorted into the groups the Stats sheet shows (see [TelemetrySummary]).
  TelemetrySummary summary() => TelemetrySummary.of(this);
}

/// A telemetry answer sorted for people: what the contact shares and (for a person) what their radio withheld. The firmware
/// answers only what the contact's telemetry permission bits allow (base = battery, location, environment; V S1), so a
/// missing group means "not shared", never "unknown". Pure.
class TelemetrySummary {
  final LppReading? battery;
  final LppReading? position;
  final List<LppReading> environment;
  final List<LppReading> other;

  /// Plain sentences, one per group the contact's radio did not send ("Maya's radio doesn't share location.").
  final List<String> withheld;
  const TelemetrySummary(this.battery, this.position, this.environment, this.other, this.withheld);

  bool get isEmpty => battery == null && position == null && environment.isEmpty && other.isEmpty;

  /// [person]: a companion (chat user). Only a person gets "withheld" sentences; a repeater or sensor simply has what it has.
  static TelemetrySummary of(TelemetryResult r, {bool person = true}) {
    final env = <LppReading>[];
    final other = <LppReading>[];
    for (final x in r.readings) {
      switch (x.kind) {
        case LppKind.voltage || LppKind.gps:
          break;
        case LppKind.temperature || LppKind.humidity || LppKind.pressure || LppKind.luminosity || LppKind.altitude:
          env.add(x);
        default:
          other.add(x);
      }
    }
    final first = r.who.split(' ').first;
    final owner = first.isEmpty ? 'This radio' : "$first's radio";
    final w = <String>[];
    if (person && r.ok) {
      final b = r.battery, p = r.position;
      if (b == null && p == null && env.isEmpty) {
        w.add("$owner doesn't share anything at all.");
      } else {
        if (b == null) w.add("$owner doesn't share battery.");
        if (p == null) w.add("$owner doesn't share location.");
        if (env.isEmpty) w.add("$owner doesn't share sensor readings.");
      }
    }
    return TelemetrySummary(r.battery, r.position, env, other, w);
  }
}

/// Distance in km between two points (haversine). For "2.4 km away" next to a shared position.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0088;
  double rad(double d) => d * 3.141592653589793 / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

/// The numeric series of [kind] (channel [channel] when given) across [history], oldest first. For the sparkline.
List<double> seriesOf(Iterable<TelemetryResult> history, LppKind kind, {int? channel}) => [
      for (final h in history)
        if (h.ok)
          for (final x in h.readings)
            if (x.kind == kind && x.value != null && (channel == null || x.channel == channel)) x.value!
    ];

class TelemetryTool with ToolChanges {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final DateTime Function() _clock;
  final Duration minGap;
  final Duration waitSlack;
  final Duration minWait;
  final Duration maxWait;
  final Map<String, TelemetryResult> _latest = {};
  final Map<String, List<TelemetryResult>> _history = {};

  /// Keep this many answers per contact for the sparkline (in memory; a session's worth).
  static const historyLimit = 60;

  /// The radio's shared remote-request queue (one remote request in flight at a time). Set by the session; null in tests
  /// that do not need it, where [requestContactQueued] runs the request directly.
  RemoteRequestQueue? queue;
  DateTime? _lastAt;
  bool _busy = false;

  TelemetryTool(this.radio, this.arbiter, {DateTime Function()? clock,
      this.minGap = const Duration(seconds: 10),
      this.waitSlack = const Duration(seconds: 3),
      this.minWait = const Duration(seconds: 5),
      this.maxWait = const Duration(seconds: 20)}) : _clock = clock ?? DateTime.now;

  bool get busy => _busy;

  /// Latest result per contact key (and 'self').
  Map<String, TelemetryResult> get latest => Map.unmodifiable(_latest);

  /// Good answers for [key], oldest first.
  List<TelemetryResult> historyFor(String key) => List.unmodifiable(_history[key] ?? const []);

  void _remember(String key, TelemetryResult r) {
    _latest[key] = r;
    if (!r.ok) return;
    final h = _history.putIfAbsent(key, () => []);
    h.add(r);
    if (h.length > historyLimit) h.removeRange(0, h.length - historyLimit);
  }

  /// [requestContact] through the shared queue so it never overlaps a login or a repeater refresh. A user tap runs at admin
  /// priority; [background] (auto refresh) is dropped when anything else is going on. Silence comes back as `silent` and the
  /// queue entry ends as noReply.
  Future<TelemetryResult> requestContactQueued(RadioContact c, {bool background = false}) async {
    final q = queue;
    if (q == null) return requestContact(c);
    TelemetryResult? out;
    final req = q.enqueue<TelemetryResult>(
      kind: RemoteKind.telemetry,
      target: c.name.isEmpty ? c.publicKeyHex.substring(0, 8) : c.name,
      priority: background ? CommandPriority.background : CommandPriority.admin,
      run: (ctx) async {
        final r = await requestContact(c);
        out = r;
        if (r.status == TelemetryStatus.silent) throw RemoteNoReply(r.detail ?? 'No reply');
        return r;
      },
    );
    final res = await req.result;
    final now = _clock();
    final who = c.name.isEmpty ? c.publicKeyHex.substring(0, 8) : c.name;
    return switch (res) {
      RemoteDone<TelemetryResult>(:final value) => value,
      RemoteNoReplyResult<TelemetryResult>() => out ?? TelemetryResult(TelemetryStatus.silent, who, now, keyHex: c.publicKeyHex, detail: '$who did not answer.'),
      RemoteDroppedResult<TelemetryResult>() => TelemetryResult(TelemetryStatus.tooSoon, who, now, keyHex: c.publicKeyHex, detail: 'The radio is busy with another request.'),
      RemoteCancelledResult<TelemetryResult>() => TelemetryResult(TelemetryStatus.tooSoon, who, now, keyHex: c.publicKeyHex, detail: 'Cancelled.'),
      RemoteRefusedResult<TelemetryResult>() => TelemetryResult(TelemetryStatus.refused, who, now, keyHex: c.publicKeyHex, detail: 'The request was refused.'),
      RemoteFailedResult<TelemetryResult>() => TelemetryResult(TelemetryStatus.refused, who, now, keyHex: c.publicKeyHex, detail: 'The request failed.'),
    };
  }

  Duration? cooldown() {
    final at = _lastAt;
    if (at == null) return null;
    final left = minGap - _clock().difference(at);
    return left > Duration.zero ? left : null;
  }

  /// Airtime of one request (a small direct or flood packet).
  double estimateAirtimeMs() => arbiter.airParams?.call()?.airtimeMs(40) ?? 200;

  Future<TelemetryResult> requestSelf() async {
    final now = _clock();
    if (!radio.isConnected) return TelemetryResult(TelemetryStatus.notConnected, 'This radio', now, isSelf: true, detail: 'No radio is connected.');
    if (_busy) return TelemetryResult(TelemetryStatus.tooSoon, 'This radio', now, isSelf: true, detail: 'A telemetry request is already running.');
    _busy = true;
    notifyChanged();
    try {
      final raw = await radio.selfTelemetryFrame();
      final t = raw == null ? null : TelemetryPush.tryParse(raw);
      final r = t == null
          ? TelemetryResult(TelemetryStatus.empty, 'This radio', now, isSelf: true, detail: 'This radio did not report any sensor readings.')
          : _fromLpp('This radio', null, true, now, t.lpp);
      _remember('self', r);
      return r;
    } finally {
      _busy = false;
      notifyChanged();
    }
  }

  Future<TelemetryResult> requestContact(RadioContact c) async {
    final now = _clock();
    final who = c.name.isEmpty ? c.publicKeyHex.substring(0, 8) : c.name;
    TelemetryResult fail(TelemetryStatus s, String d) => TelemetryResult(s, who, now, keyHex: c.publicKeyHex, detail: d);
    if (!radio.isConnected) return fail(TelemetryStatus.notConnected, 'No radio is connected.');
    if (_busy) return fail(TelemetryStatus.tooSoon, 'A telemetry request is already running.');
    final wait = cooldown();
    if (wait != null) return fail(TelemetryStatus.tooSoon, 'Wait ${wait.inSeconds + 1} s before asking again.');
    _busy = true;
    _lastAt = now;
    notifyChanged();
    final key = fromHex(c.publicKeyHex);
    final waiter = _PushWaiter(radio.pushes, (f) {
      final t = TelemetryPush.tryParse(f);
      return t != null && t.prefixHex == c.publicKeyHex.substring(0, 12);
    });
    try {
      final Frame reply;
      try {
        reply = await radio.send(encodeTelemetryReqFor(key), priority: CommandPriority.admin);
      } on TimeoutException {
        return fail(TelemetryStatus.silent, 'The radio did not answer the command.');
      } on StateError {
        return fail(TelemetryStatus.notConnected, 'The radio disconnected.');
      }
      if (reply is ErrFrame) {
        return reply.code == ErrCode.notFound
            ? fail(TelemetryStatus.noContact, 'This radio does not have $who as a contact yet. Add it first.')
            : fail(TelemetryStatus.refused, 'The radio refused the request.');
      }
      if (reply is! SentFrame) return fail(TelemetryStatus.refused, 'The radio gave an unexpected answer.');
      arbiter.recordTx(TxPriority.admin, estimateAirtimeMs());
      final wait = Duration(milliseconds: (reply.estTimeoutMs + waitSlack.inMilliseconds).clamp(minWait.inMilliseconds, maxWait.inMilliseconds));
      final f = await waiter.wait(wait);
      if (f == null) {
        return fail(TelemetryStatus.silent, '$who did not answer in ${wait.inSeconds} s. It may be out of range or asleep.');
      }
      final t = TelemetryPush.tryParse(f)!;
      final r = _fromLpp(who, c.publicKeyHex, false, _clock(), t.lpp);
      _remember(c.publicKeyHex, r);
      return r;
    } finally {
      waiter.cancel();
      _busy = false;
      notifyChanged();
    }
  }

  TelemetryResult _fromLpp(String who, String? key, bool self, DateTime at, Uint8List lpp) {
    final readings = decodeLpp(lpp);
    return TelemetryResult(readings.isEmpty ? TelemetryStatus.empty : TelemetryStatus.ok, who, at,
        keyHex: key,
        isSelf: self,
        readings: readings,
        detail: readings.isEmpty ? '$who answered but reported no sensor readings.' : null);
  }

  void dispose() => disposeChanges();
}

class _PushWaiter {
  final Completer<Uint8List?> _c = Completer();
  late final StreamSubscription<Uint8List> _sub;
  Timer? _timer;
  _PushWaiter(Stream<Uint8List> pushes, bool Function(Uint8List) test) {
    _sub = pushes.listen((f) {
      if (!_c.isCompleted && test(f)) _c.complete(f);
    });
  }
  Future<Uint8List?> wait(Duration t) {
    _timer = Timer(t, () {
      if (!_c.isCompleted) _c.complete(null);
    });
    return _c.future;
  }

  void cancel() {
    _timer?.cancel();
    _sub.cancel();
  }
}
