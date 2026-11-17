// The phone observer's status calls (contract meshsonar-infra docs/planning/phone-observer-contract-v2-2026-11-08.md
// section 8.3 and 4.1): every phone with a connected radio that shares with MeshSonar is an observer, whatever it is doing
// (Andy, Nov 15 2026, observer-everywhere plan D3: the Home observer is gone, a phone sitting still next to its radio just
// observes). This file keeps the two calls that serve every observer:
//
//  * `POST /api/cmh/observer/heartbeat`  {"id", "mode", "radio"} once at connect and every 5 min while a radio is connected
//    and sharing is on (the server measures uptime by it)
//  * `GET  /api/cmh/observer/me`         this driver's phone observers (packets heard in 24 h, last packet, last heartbeat)
//
// Both with `x-driver-key`. The server's `observer/home` endpoints stay for builds 61-63 until a later server cleanup; this
// app no longer calls them.
//
// Pure Dart.
import 'dart:async';
import 'dart:convert';

/// One answer from the server; a network failure is a thrown exception instead.
class ObserverHttpResult {
  final int status;
  final Map<String, dynamic>? body;
  const ObserverHttpResult(this.status, {this.body});
  bool get ok => status >= 200 && status < 300;
}

/// The HTTP side, implemented by HttpCmatClient (lib/core/cmat_client.dart).
abstract class ObserverStatusTransport {
  /// `POST /api/cmh/observer/heartbeat` [body] = {"id", "mode", "radio"} (contract section 8.3).
  Future<ObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body);

  /// `GET /api/cmh/observer/me`.
  Future<ObserverHttpResult> me(String driverKey);
}

/// One of the driver's phone observers, from `GET /observer/me`. [kind] is what the server says (`mobile`; older builds
/// may still have registered a `fixed` one).
class PhoneObserverInfo {
  final String? id;
  final String? key;
  final String kind;
  final DateTime? lastPacketAt;
  final DateTime? lastHeartbeatAt;
  final int? packets24h;
  final int? rawPackets24h;
  const PhoneObserverInfo({
    this.id,
    this.key,
    required this.kind,
    this.lastPacketAt,
    this.lastHeartbeatAt,
    this.packets24h,
    this.rawPackets24h,
  });

  static PhoneObserverInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final last = j['last_packet_at'];
    final pk = j['packets_24h'] ?? j['packets24h'];
    final rawPk = j['raw_packets_24h'];
    final hb = j['last_heartbeat_at'];
    return PhoneObserverInfo(
      id: j['id'] is String ? j['id'] as String : null,
      key: j['key'] is String ? (j['key'] as String).toLowerCase() : (j['public_key'] is String ? (j['public_key'] as String).toLowerCase() : null),
      kind: j['kind'] is String ? j['kind'] as String : 'mobile',
      lastPacketAt: last is String ? DateTime.tryParse(last)?.toUtc() : null,
      lastHeartbeatAt: hb is String ? DateTime.tryParse(hb)?.toUtc() : null,
      packets24h: pk is num ? pk.toInt() : null,
      rawPackets24h: rawPk is num ? rawPk.toInt() : null,
    );
  }
}

/// Reads `GET /observer/me`: `{"observers": [...]}` (contract section 4.1), or a bare list.
List<PhoneObserverInfo> parsePhoneObservers(Object? body) {
  final list = body is Map ? body['observers'] : body;
  if (list is! List) return const [];
  return list.map(PhoneObserverInfo.fromJson).whereType<PhoneObserverInfo>().toList();
}

/// Picks this phone's entry: by the observer id, else by the key the server gave for this phone, else the only one.
PhoneObserverInfo? thisPhoneObserver(List<PhoneObserverInfo> all, {String? id, String? key}) {
  for (final o in all) {
    if (id != null && o.id == id) return o;
  }
  for (final o in all) {
    if (key != null && o.key == key.toLowerCase()) return o;
  }
  return all.length == 1 ? all.first : null;
}

/// What a call came to, in words a screen can show.
enum ObserverCallOutcome { ok, noKey, notOnServer, keyRefused, rateLimited, offline, failed }

String observerCallText(ObserverCallOutcome o) => switch (o) {
      ObserverCallOutcome.ok => 'Done.',
      ObserverCallOutcome.noKey => 'This phone needs a confirmed driver key first (Settings > Account).',
      ObserverCallOutcome.notOnServer => 'Your server does not report observer status yet.',
      ObserverCallOutcome.keyRefused => 'The server did not accept this phone\'s driver key.',
      ObserverCallOutcome.rateLimited => 'The server asked to slow down. It is tried again shortly.',
      ObserverCallOutcome.offline => 'No connection to the server. It is tried again when there is one.',
      ObserverCallOutcome.failed => 'The server could not do that right now. It is tried again shortly.',
    };

ObserverCallOutcome _outcome(ObserverHttpResult r) {
  if (r.ok) return ObserverCallOutcome.ok;
  if (r.status == 404 || r.status == 405 || r.status == 501) return ObserverCallOutcome.notOnServer;
  if (r.status == 401 || r.status == 403) return ObserverCallOutcome.keyRefused;
  if (r.status == 429) return ObserverCallOutcome.rateLimited;
  return ObserverCallOutcome.failed;
}

/// Keeps the 5-minute heartbeat while sharing is on and the radio is connected, and reads this phone's status.
class ObserverStatusService {
  final ObserverStatusTransport? Function() transport;
  final String? Function() driverKey;
  final Future<String> Function() observerId;

  /// A heartbeat may go: sharing is on (and a real radio).
  final bool Function() active;

  /// The observer mode right now (`background` / `drive`) and the radio block (same as a batch's), for the body.
  final String Function()? mode;
  final Map<String, dynamic> Function()? radio;

  /// The radio is connected (no heartbeat without it: the server measures uptime by it).
  final bool Function() connected;
  final Duration heartbeatEvery;

  /// Start the periodic heartbeat timer by itself. Tests switch it off and call [heartbeatNow].
  final bool autoTimer;

  ObserverStatusService({
    required this.transport,
    required this.driverKey,
    required this.observerId,
    required this.active,
    required this.connected,
    this.mode,
    this.radio,
    this.heartbeatEvery = const Duration(minutes: 5),
    this.autoTimer = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _lastBeatAt;

  /// Heartbeats that went with a telemetry batch instead of on their own timer wake (battery plan A6).
  int heartbeatsCoalesced = 0;

  /// Battery plan A6, "send the heartbeat with the telemetry batch": a heartbeat rides with a batch once 80 % of
  /// [heartbeatEvery] passed since the last one (4 of 5 min), and the timer, re-armed after every heartbeat, waits 120 %
  /// (6 min), so a phone uploading every 5 min (Balanced, locked) beats with its batches and the timer never wakes the
  /// network alone. Without batches it beats every 6 min; either way well inside the server's 10 min "online" window
  /// (greatest(last_heartbeat_at, last_packet_at), meshcore-insights migration 0116).
  bool get _rideDue {
    final at = _lastBeatAt;
    return at == null || _clock().difference(at) >= heartbeatEvery * 0.8;
  }

  /// A telemetry batch the server took just went (the phone's network is awake anyway).
  void rideAlong() {
    if (!_started || !_rideDue) return;
    heartbeatsCoalesced++;
    unawaited(heartbeatNow());
    _arm();
  }

  void _arm() {
    if (!_started || !autoTimer) return;
    _timer?.cancel();
    _timer = Timer(heartbeatEvery * 1.2, () {
      _timer = null;
      unawaited(heartbeatNow());
      _arm();
    });
  }

  Timer? _timer;
  int heartbeatsSent = 0;
  ObserverCallOutcome? lastOutcome;

  /// The server's key for this phone's observer, from the last `{observer: {key, kind}}` answer.
  String? lastKey;

  /// The last status read from the server for this phone (null before the first read or when the server has none).
  PhoneObserverInfo? status;
  DateTime? statusAt;

  bool get heartbeatRunning => _started;

  Future<ObserverCallOutcome> _call(Future<ObserverHttpResult> Function(ObserverStatusTransport tx, String key) f) async {
    final key = driverKey();
    final tx = transport();
    if (key == null || key.isEmpty || tx == null) return lastOutcome = ObserverCallOutcome.noKey;
    try {
      final r = await f(tx, key);
      final o = r.body?['observer'];
      if (o is Map && o['key'] is String) lastKey = (o['key'] as String).toLowerCase();
      return lastOutcome = _outcome(r);
    } catch (_) {
      return lastOutcome = ObserverCallOutcome.offline;
    }
  }

  /// The heartbeat body (contract section 8.3).
  Map<String, dynamic> heartbeatBody(String id) {
    final r = radio?.call() ?? const <String, dynamic>{};
    return {'id': id, 'mode': mode?.call() ?? 'background', if (r.isNotEmpty) 'radio': r};
  }

  /// One heartbeat, only while sharing is on and the radio is connected. Returns null when it was not due.
  Future<ObserverCallOutcome?> heartbeatNow() async {
    if (!active() || !connected()) return null;
    _lastBeatAt = _clock();
    final id = await observerId();
    final o = await _call((tx, key) => tx.heartbeat(key, heartbeatBody(id)));
    if (o == ObserverCallOutcome.ok) heartbeatsSent++;
    return o;
  }

  /// Starts (or keeps) the heartbeat: one now, then with the telemetry batches or by the timer ([rideAlong]). Each beat
  /// checks sharing and the radio.
  ///
  /// Without [autoTimer] (tests) only the one heartbeat at start goes.
  bool _started = false;
  void startHeartbeat() {
    if (_started) return;
    _started = true;
    unawaited(heartbeatNow());
    _arm();
  }

  void stopHeartbeat() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  /// `GET /observer/me`, then picks this phone's entry ([key]).
  Future<ObserverCallOutcome> refreshStatus({String? key, DateTime? now}) async {
    final id = await observerId();
    ObserverHttpResult? res;
    final o = await _call((tx, k) async => res = await tx.me(k));
    if (o == ObserverCallOutcome.ok && res != null) {
      status = thisPhoneObserver(parsePhoneObservers(res!.body), id: id, key: key);
      statusAt = now ?? DateTime.now().toUtc();
    }
    return o;
  }

  void dispose() => stopHeartbeat();
}

/// The JSON body bytes for a request (kept here so the transport and the tests encode the same way).
List<int> observerJson(Map<String, dynamic> body) => utf8.encode(jsonEncode(body));
