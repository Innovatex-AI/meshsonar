// Telemetry: ask a contact (or this radio) for its sensor readings and decode them.
//
// Contact: CMD_SEND_TELEMETRY_REQ with the key -> SENT (est timeout), then PUSH_CODE_TELEMETRY_RESPONSE with Cayenne LPP,
// BIG endian (VERIFIED on hardware: 0.63-0.72 s, battery 3.86 V and MCU temperature 45.0 C from a repeater; a guest login
// gets base telemetry only). Silence is the failure signal, so the wait comes from est_timeout. Self: the 4-byte form.
// A position in the readings (LPP type 136) is shown to the person who asked and never uploaded or stored.
// Pure Dart.
import 'dart:async';
import 'dart:typed_data';

import '../command_queue.dart';
import '../crypto.dart';
import '../inbound.dart';
import '../protocol.dart';
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
}

class TelemetryTool with ToolChanges {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final DateTime Function() _clock;
  final Duration minGap;
  final Duration waitSlack;
  final Duration minWait;
  final Duration maxWait;
  final Map<String, TelemetryResult> _latest = {};
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
      _latest['self'] = r;
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
      _latest[c.publicKeyHex] = r;
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
