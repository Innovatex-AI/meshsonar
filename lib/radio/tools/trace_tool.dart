// Trace Path: send CMD_SEND_TRACE_PATH along a hand-built chain of repeaters and report each hop's SNR.
//
// What the radio does (MyMesh.cpp 1813-1832, 855-890; VERIFIED on hardware, research doc 2026-11-01 section B):
//  - The chain is a list of the first N bytes of each node's public key (N = 1, 2 or 4). The packet is DIRECT-routed along
//    exactly that list; each node on it appends the SNR it heard the packet at.
//  - The answer (PUSH_CODE_TRACE_DATA) comes back to this radio only when it HEARS the last hop retransmit. So the last
//    node must be one this radio can hear directly.
//  - A hop that does not exist, or is out of range, gives NO push at all: silence is the failure signal. The SENT reply
//    carries est_timeout_ms (2.5-3.8 s measured); the tool waits that long plus two seconds, then calls it "no answer".
//  - 1-byte hashes can match more than one repeater. The tool flags a hop whose hash another known node shares.
// Pure Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/heard.dart' show haversineM;
import '../command_queue.dart';
import '../crypto.dart';
import '../inbound.dart';
import '../protocol.dart';
import '../tx_arbiter.dart';
import 'tool_frames.dart';
import 'tool_state.dart';
import 'tools_radio.dart';

/// One repeater (or room) on a trace path.
class TraceStop {
  final String name;
  final String keyHex;
  final int type;
  final double? lat, lon;
  const TraceStop({required this.name, required this.keyHex, this.type = AdvType.repeater, this.lat, this.lon});

  bool get hasPosition => lat != null && lon != null;
  String hashHex(int hashSize) => keyHex.substring(0, hashSize * 2);

  static TraceStop fromContact(RadioContact c) =>
      TraceStop(name: c.name.isEmpty ? 'Node ${c.publicKeyHex.substring(0, 8)}' : c.name, keyHex: c.publicKeyHex, type: c.type, lat: c.lat, lon: c.lon);

  Map<String, dynamic> toJson() => {'name': name, 'key': keyHex, 'type': type, 'lat': lat, 'lon': lon};
  static TraceStop fromJson(Map<String, dynamic> j) => TraceStop(
      name: j['name'] as String? ?? '',
      keyHex: j['key'] as String,
      type: (j['type'] as num?)?.toInt() ?? AdvType.repeater,
      lat: (j['lat'] as num?)?.toDouble(),
      lon: (j['lon'] as num?)?.toDouble());
}

/// A hop whose hash another known node also has, so the hop may not be the node the person picked.
class AmbiguousHop {
  final int index;
  final TraceStop stop;
  final List<String> otherNames;
  const AmbiguousHop(this.index, this.stop, this.otherNames);
}

/// Hops of [stops] whose first [hashSize] bytes another node in [known] shares.
List<AmbiguousHop> findAmbiguousHops(List<TraceStop> stops, int hashSize, Iterable<RadioContact> known) {
  final out = <AmbiguousHop>[];
  for (var i = 0; i < stops.length; i++) {
    final h = stops[i].hashHex(hashSize);
    final others = <String>[
      for (final c in known)
        if (c.publicKeyHex != stops[i].keyHex &&
            (c.type == AdvType.repeater || c.type == AdvType.room) &&
            c.publicKeyHex.startsWith(h))
          c.name.isEmpty ? c.publicKeyHex.substring(0, 8) : c.name,
    ];
    if (others.isNotEmpty) out.add(AmbiguousHop(i, stops[i], others));
  }
  return out;
}

enum TraceStatus {
  /// The radio sent the trace and the answer came back.
  ok,

  /// The radio took the trace and nothing came back (a missing or out-of-range hop, or the last hop is not heard here).
  silent,

  /// The radio refused the path (ERR).
  refused,

  /// No radio.
  notConnected,

  /// A trace ran a moment ago; wait.
  tooSoon,

  /// The chain cannot be sent (empty, too long).
  invalid,
}

class TraceHopResult {
  final TraceStop stop;
  final String hashHex;

  /// SNR at which THIS hop heard the packet.
  final double? snrDb;

  /// Distance from the previous point (this phone/radio for the first hop), km; null when a position is missing.
  final double? distanceKm;
  final bool ambiguous;
  const TraceHopResult({required this.stop, required this.hashHex, this.snrDb, this.distanceKm, this.ambiguous = false});

  Map<String, dynamic> toJson() => {'stop': stop.toJson(), 'hash': hashHex, 'snr': snrDb, 'km': distanceKm, 'amb': ambiguous};
  static TraceHopResult fromJson(Map<String, dynamic> j) => TraceHopResult(
      stop: TraceStop.fromJson((j['stop'] as Map).cast<String, dynamic>()),
      hashHex: j['hash'] as String,
      snrDb: (j['snr'] as num?)?.toDouble(),
      distanceKm: (j['km'] as num?)?.toDouble(),
      ambiguous: j['amb'] == true);
}

class TraceResult {
  final String id;
  final DateTime at;
  final TraceStatus status;
  final String? detail;
  final int hashSize;
  final List<TraceHopResult> hops;

  /// SNR at which this radio heard the packet coming back from the last hop.
  final double? finalSnrDb;
  final int? estTimeoutMs;
  final Duration? elapsed;

  /// Where the chain started (phone or radio position), if known.
  final double? originLat, originLon;
  const TraceResult({
    required this.id,
    required this.at,
    required this.status,
    this.detail,
    required this.hashSize,
    this.hops = const [],
    this.finalSnrDb,
    this.estTimeoutMs,
    this.elapsed,
    this.originLat,
    this.originLon,
  });

  bool get ok => status == TraceStatus.ok;
  List<TraceStop> get stops => [for (final h in hops) h.stop];

  /// Sum of the hop distances that are known, km. Null when none is known.
  double? get totalKm {
    final known = [for (final h in hops) if (h.distanceKm != null) h.distanceKm!];
    return known.isEmpty ? null : known.fold<double>(0, (a, b) => a + b);
  }

  /// Some hops have no position, so [totalKm] covers only part of the chain.
  bool get distancePartial => hops.any((h) => h.distanceKm == null) && totalKm != null;

  bool get hasAmbiguousHop => hops.any((h) => h.ambiguous);

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toUtc().toIso8601String(),
        'status': status.name,
        'detail': detail,
        'hashSize': hashSize,
        'hops': [for (final h in hops) h.toJson()],
        'final': finalSnrDb,
        'est': estTimeoutMs,
        'ms': elapsed?.inMilliseconds,
        'oLat': originLat,
        'oLon': originLon,
      };
  static TraceResult fromJson(Map<String, dynamic> j) => TraceResult(
        id: j['id'] as String,
        at: DateTime.parse(j['at'] as String),
        status: TraceStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => TraceStatus.silent),
        detail: j['detail'] as String?,
        hashSize: (j['hashSize'] as num?)?.toInt() ?? 2,
        hops: [for (final h in (j['hops'] as List? ?? const [])) TraceHopResult.fromJson((h as Map).cast<String, dynamic>())],
        finalSnrDb: (j['final'] as num?)?.toDouble(),
        estTimeoutMs: (j['est'] as num?)?.toInt(),
        elapsed: j['ms'] == null ? null : Duration(milliseconds: (j['ms'] as num).toInt()),
        originLat: (j['oLat'] as num?)?.toDouble(),
        originLon: (j['oLon'] as num?)?.toDouble(),
      );
}

/// Saved traces, newest first, at most [max]. Memory by default; [FileTraceStore] keeps them on disk.
class TraceStore {
  final int max;
  final List<TraceResult> _items;
  TraceStore({this.max = 40, List<TraceResult>? initial}) : _items = [...?initial];

  List<TraceResult> get items => List.unmodifiable(_items);

  bool contains(String id) => _items.any((t) => t.id == id);

  Future<void> save(TraceResult t) async {
    _items.removeWhere((x) => x.id == t.id);
    _items.insert(0, t);
    while (_items.length > max) {
      _items.removeLast();
    }
    await persist();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((x) => x.id == id);
    await persist();
  }

  Future<void> persist() async {}
}

class FileTraceStore extends TraceStore {
  final File file;
  FileTraceStore(this.file, {super.max, super.initial});

  /// Synchronous load for the app's start (a small file); a damaged file only costs the saved traces.
  static FileTraceStore openSync(File file, {int max = 40}) {
    final items = <TraceResult>[];
    try {
      if (file.existsSync()) {
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is List) {
          for (final e in raw) {
            try {
              items.add(TraceResult.fromJson((e as Map).cast<String, dynamic>()));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return FileTraceStore(file, max: max, initial: items);
  }

  /// Loads the file; a damaged file only costs the saved traces.
  static Future<FileTraceStore> open(File file, {int max = 40}) async {
    final items = <TraceResult>[];
    try {
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is List) {
          for (final e in raw) {
            try {
              items.add(TraceResult.fromJson((e as Map).cast<String, dynamic>()));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return FileTraceStore(file, max: max, initial: items);
  }

  @override
  Future<void> persist() async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode([for (final t in _items) t.toJson()]), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // A full disk loses the saved traces, never the screen.
    }
  }
}

/// Hop-by-hop difference between two traces over the same chain.
class TraceComparison {
  final TraceResult a, b;
  final List<({String name, double? snrA, double? snrB})> rows;
  final double? finalA, finalB;
  const TraceComparison(this.a, this.b, this.rows, this.finalA, this.finalB);

  bool get sameChain => a.stops.length == b.stops.length && [for (var i = 0; i < a.stops.length; i++) a.stops[i].keyHex == b.stops[i].keyHex].every((x) => x);

  /// Changes in dB (b minus a) per hop; null where either side has no SNR.
  List<double?> get deltas => [for (final r in rows) r.snrA == null || r.snrB == null ? null : r.snrB! - r.snrA!];
}

TraceComparison compareTraces(TraceResult a, TraceResult b) {
  // Rows by node, in b's order, so a chain with one hop added still lines up.
  final rows = <({String name, double? snrA, double? snrB})>[];
  for (final h in b.hops) {
    final match = a.hops.where((x) => x.stop.keyHex == h.stop.keyHex).firstOrNull;
    rows.add((name: h.stop.name, snrA: match?.snrDb, snrB: h.snrDb));
  }
  return TraceComparison(a, b, rows, a.finalSnrDb, b.finalSnrDb);
}

class TraceTool with ToolChanges {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final DateTime Function() _clock;
  final math.Random _rng;
  final TraceStore store;

  /// Shortest gap between two traces from this app.
  final Duration minGap;

  /// The wait for the answer is the radio's est_timeout plus [waitSlack], at least [minWait], at most 20 s. Tests shorten them.
  final Duration waitSlack;
  final Duration minWait;
  final Duration maxWait;

  TraceResult? _last;
  bool _running = false;
  DateTime? _lastRunAt;

  TraceTool(this.radio, this.arbiter, {DateTime Function()? clock, math.Random? rng, TraceStore? store,
      this.minGap = const Duration(seconds: 4),
      this.waitSlack = const Duration(seconds: 2),
      this.minWait = const Duration(seconds: 4),
      this.maxWait = const Duration(seconds: 20)})
      : _clock = clock ?? DateTime.now,
        _rng = rng ?? math.Random.secure(),
        store = store ?? TraceStore();

  TraceResult? get last => _last;
  bool get running => _running;

  /// How long until another trace may go out; null when one may go now.
  Duration? cooldown() {
    final at = _lastRunAt;
    if (at == null) return null;
    final left = minGap - _clock().difference(at);
    return left > Duration.zero ? left : null;
  }

  /// Airtime estimate for a trace of [hops] hops of [hashSize] bytes: the packet is a direct packet of about
  /// 12 + path bytes (header, path_len, tag, auth, flags, path).
  double estimateAirtimeMs(int hops, int hashSize) {
    final p = arbiter.airParams?.call();
    final bytes = 12 + hops * hashSize;
    return p == null ? 300 : p.airtimeMs(bytes);
  }

  /// Runs the trace. Never throws: every outcome is a [TraceResult].
  Future<TraceResult> run(List<TraceStop> stops, {int hashSize = 2, ({double lat, double lon})? origin, Iterable<RadioContact> known = const []}) async {
    final now = _clock();
    final id = now.microsecondsSinceEpoch.toString();
    TraceResult fail(TraceStatus s, String detail) =>
        TraceResult(id: id, at: now, status: s, detail: detail, hashSize: hashSize, originLat: origin?.lat, originLon: origin?.lon);

    if (!radio.isConnected) return _done(fail(TraceStatus.notConnected, 'No radio is connected.'));
    if (stops.isEmpty) return _done(fail(TraceStatus.invalid, 'Pick at least one repeater for the path.'));
    if (stops.length > maxTraceHops) return _done(fail(TraceStatus.invalid, 'A path can have at most $maxTraceHops hops.'));
    if (!traceHashSizes.contains(hashSize)) return _done(fail(TraceStatus.invalid, 'Hash size must be 1, 2 or 4 bytes.'));
    if (_running) return fail(TraceStatus.tooSoon, 'A trace is already running.');
    final wait = cooldown();
    if (wait != null) return fail(TraceStatus.tooSoon, 'Wait ${wait.inSeconds + 1} s before the next trace.');

    _running = true;
    _lastRunAt = now;
    notifyChanged();
    final sw = Stopwatch()..start();
    final tag = _rng.nextInt(0xFFFFFFFF) + 1;
    final path = <int>[for (final s in stops) ...fromHex(s.hashHex(hashSize))];
    final ambiguous = {for (final a in findAmbiguousHops(stops, hashSize, known)) a.index};
    final waiter = _TraceWaiter(radio.pushes, tag);
    try {
      final Frame reply;
      try {
        reply = await radio.send(encodeSendTracePath(tag, path, hashSize: hashSize), priority: CommandPriority.admin);
      } on TimeoutException {
        return _done(fail(TraceStatus.silent, 'The radio did not answer the command.'));
      } on StateError {
        return _done(fail(TraceStatus.notConnected, 'The radio disconnected.'));
      }
      if (reply is ErrFrame) {
        return _done(fail(TraceStatus.refused, reply.code == ErrCode.tableFull ? 'The radio is too busy to send a trace now.' : 'The radio refused this path.'));
      }
      if (reply is! SentFrame) return _done(fail(TraceStatus.refused, 'The radio gave an unexpected answer.'));
      arbiter.recordTx(TxPriority.admin, estimateAirtimeMs(stops.length, hashSize));
      final wait = Duration(milliseconds: (reply.estTimeoutMs + waitSlack.inMilliseconds).clamp(minWait.inMilliseconds, maxWait.inMilliseconds));
      final data = await waiter.wait(wait);
      sw.stop();
      if (data == null) {
        return _done(TraceResult(
            id: id,
            at: now,
            status: TraceStatus.silent,
            detail: 'No answer in ${(wait.inMilliseconds / 1000).toStringAsFixed(0)} s. A hop on the path may not exist or may be out of range, '
                'or the last hop is not one this radio can hear directly.',
            hashSize: hashSize,
            estTimeoutMs: reply.estTimeoutMs,
            elapsed: sw.elapsed,
            originLat: origin?.lat,
            originLon: origin?.lon));
      }
      return _done(_build(id, now, stops, hashSize, data, ambiguous, origin, reply.estTimeoutMs, sw.elapsed));
    } finally {
      waiter.cancel();
      _running = false;
      notifyChanged();
    }
  }

  TraceResult _build(String id, DateTime at, List<TraceStop> stops, int hashSize, TraceData data, Set<int> ambiguous,
      ({double lat, double lon})? origin, int est, Duration elapsed) {
    final hops = <TraceHopResult>[];
    double? prevLat = origin?.lat, prevLon = origin?.lon;
    for (var i = 0; i < stops.length; i++) {
      final s = stops[i];
      double? km;
      if (prevLat != null && prevLon != null && s.hasPosition) km = haversineM(prevLat, prevLon, s.lat!, s.lon!) / 1000;
      hops.add(TraceHopResult(
        stop: s,
        hashHex: s.hashHex(hashSize),
        snrDb: i < data.hopSnrDb.length ? data.hopSnrDb[i] : null,
        distanceKm: km,
        ambiguous: ambiguous.contains(i),
      ));
      prevLat = s.lat;
      prevLon = s.lon;
    }
    final echoed = data.hops == stops.length;
    return TraceResult(
        id: id,
        at: at,
        status: TraceStatus.ok,
        detail: echoed ? null : 'The radio reported ${data.hops} hops for a path of ${stops.length}.',
        hashSize: hashSize,
        hops: hops,
        finalSnrDb: data.finalSnrDb,
        estTimeoutMs: est,
        elapsed: elapsed,
        originLat: origin?.lat,
        originLon: origin?.lon);
  }

  TraceResult _done(TraceResult r) {
    _last = r;
    _running = false;
    notifyChanged();
    return r;
  }

  Future<void> saveLast() async {
    final t = _last;
    if (t != null && t.ok) {
      await store.save(t);
      notifyChanged();
    }
  }

  void dispose() => disposeChanges();
}

/// Waits for the trace answer with [tag]. Subscribes first so an answer that races the SENT reply is not lost.
class _TraceWaiter {
  final Completer<TraceData?> _c = Completer();
  late final StreamSubscription<Uint8List> _sub;
  Timer? _timer;
  _TraceWaiter(Stream<Uint8List> pushes, int tag) {
    _sub = pushes.listen((f) {
      final d = TraceData.tryParse(f);
      if (d != null && d.tag == tag && !_c.isCompleted) _c.complete(d);
    });
  }

  Future<TraceData?> wait(Duration timeout) {
    _timer = Timer(timeout, () {
      if (!_c.isCompleted) _c.complete(null);
    });
    return _c.future;
  }

  void cancel() {
    _timer?.cancel();
    _sub.cancel();
  }
}
