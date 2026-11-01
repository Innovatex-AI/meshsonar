// Andy's real GPS, as a deterministic fake (Nov 1 2026 drives, app 0.25.x): a 1 Hz stream whose accuracy sits at 35-46 m
// most of the time, with the odd good fix (3-18 m) and 3-8 s excursions to 52-70 m; no speed (the iPhone reported none, so
// `speedMps` is null); a STALE, coarse FIRST fix (a cached position from 2 minutes and 1.2 km ago, as the 1,220 m jump from
// ping 1 to ping 2 showed); and an iOS-like `current()` that takes a while while the stream runs.
//
// The source is wrapped in the app's own FilteredLocationSource, exactly as lib/app/wiring.dart builds it, so the engine sees what
// it sees on the phone. Everything runs on the harness's fake clock (test/support/replay_radio.dart).
import 'dart:async';
import 'dart:math' as math;

import 'package:meshsonar/core/position_filter.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'replay_radio.dart';

const double _lat0 = 40.1262, _lon0 = -82.9312;

class AndyProfile {
  /// Car speed, m/s (constant: the distance rule is always met).
  final double speedMps;

  /// Share of fixes that are good (3-18 m).
  final double goodShare;

  /// Excursions above 50 m: start every [dipEveryS] (+-40%), last [dipMinS]..[dipMaxS] s, 52..70 m.
  final int dipEveryS, dipMinS, dipMaxS;

  /// When true the dips are dropouts: no fix at all for their length (a tunnel, an overpass).
  final bool dropouts;

  /// A stale coarse first fix before the real ones.
  final bool staleFirstFix;

  /// Platform `current()` latency: usually [currentMs], one in [currentSlowOneIn] takes [currentSlowMs] (>= the engine's wait).
  final int currentMs, currentSlowMs, currentSlowOneIn;

  /// Whether the OS reports speed (Andy's phone: no).
  final bool reportsSpeed;
  const AndyProfile({
    this.speedMps = 10,
    this.goodShare = 0.15,
    this.dipEveryS = 60,
    this.dipMinS = 3,
    this.dipMaxS = 8,
    this.dropouts = false,
    this.staleFirstFix = true,
    this.currentMs = 1500,
    this.currentSlowMs = 6000,
    this.currentSlowOneIn = 4,
    this.reportsSpeed = false,
  });
}

class _RawAndy implements LocationSource {
  final DateTime Function() clock;
  final AndyProfile p;
  final math.Random rng;
  late final DateTime start = clock();
  final _c = StreamController<GeoFix>.broadcast();
  Timer? _t;
  final List<({int from, int to})> dips = [];
  int _sec = 0;
  GeoFix? latest;
  bool inDropout = false;
  DateTime? runAt;

  _RawAndy(this.clock, this.p, int seed) : rng = math.Random(seed) {
    var t = 20 + rng.nextInt(20);
    while (t < 4000) {
      final len = p.dipMinS + rng.nextInt(p.dipMaxS - p.dipMinS + 1);
      dips.add((from: t, to: t + len));
      t += len + (p.dipEveryS * (0.6 + rng.nextDouble() * 0.8)).round();
    }
  }

  double _truthLat(double secondsSinceStart) => _lat0 + secondsSinceStart * p.speedMps / 111320.0;

  GeoFix _make(int sec) {
    // The car moves with the clock (a stalled isolate does not stop it): truth is clock-based, the script (dips) counts ticks.
    final t = runAt == null ? sec.toDouble() : clock().difference(runAt!).inMilliseconds / 1000.0;
    final dip = dips.any((d) => sec >= d.from && sec < d.to);
    final acc = dip
        ? 52 + rng.nextInt(19).toDouble()
        : (rng.nextDouble() < p.goodShare ? 3 + rng.nextInt(16).toDouble() : 35 + rng.nextInt(12).toDouble());
    // The reported position wanders inside the accuracy circle.
    final err = acc * 0.7 * rng.nextDouble();
    final ang = rng.nextDouble() * 2 * math.pi;
    return GeoFix(
      lat: _truthLat(t) + err * math.cos(ang) / 111320.0,
      lon: _lon0 + err * math.sin(ang) / (111320.0 * math.cos(_lat0 * math.pi / 180)),
      accuracyM: acc,
      speedMps: p.reportsSpeed ? p.speedMps : null,
      courseDeg: p.reportsSpeed ? 0 : null,
      at: clock(),
    );
  }

  void run() {
    _sec = 0;
    runAt = clock();
    if (p.staleFirstFix) {
      // The first thing the stream (and `current()`) hands over: where the car was 2 minutes ago, 1.2 km back.
      final stale = GeoFix(lat: _truthLat(-120), lon: _lon0, accuracyM: 30, at: clock().subtract(const Duration(seconds: 120)));
      latest = stale;
      Timer(const Duration(seconds: 1), () => _c.add(stale));
    }
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      _sec++;
      if (p.staleFirstFix && _sec == 1) return; // that second belongs to the cached fix
      final dip = dips.any((d) => _sec >= d.from && _sec < d.to);
      inDropout = p.dropouts && dip;
      if (inDropout) return;
      final f = _make(_sec);
      latest = f;
      _c.add(f);
    });
  }

  void stop() => _t?.cancel();

  @override
  Stream<GeoFix> get fixes => _c.stream;

  @override
  Future<GeoFix?> current() async {
    final slow = p.currentSlowOneIn > 0 && rng.nextInt(p.currentSlowOneIn) == 0;
    if (inDropout) {
      await Future<void>.delayed(const Duration(seconds: 15));
      return null;
    }
    await Future<void>.delayed(Duration(milliseconds: slow ? p.currentSlowMs : p.currentMs));
    final l = latest;
    if (l == null) return null;
    // The OS hands back its newest position; the platform plugin re-stamps nothing.
    return l;
  }

  @override
  Future<bool> ensurePermission() async => true;
}

/// Andy's GPS behind the app's FilteredLocationSource.
class AndyGps implements RunnableLocation {
  final _RawAndy _raw;
  late final FilteredLocationSource filtered;
  AndyGps(DateTime Function() clock, {AndyProfile profile = const AndyProfile(), int seed = 1}) : _raw = _RawAndy(clock, profile, seed) {
    filtered = FilteredLocationSource(_raw, clock: clock);
  }

  /// Where the car really is, [secondsSinceRun] after `run()`.
  double truthLat(double secondsSinceRun) => _raw._truthLat(secondsSinceRun);

  /// Seconds after `run()` that [t] is.
  double secondsSinceRun(DateTime t) => t.difference(_raw.runAt ?? _raw.start).inMilliseconds / 1000.0;

  /// Along-track error in metres of a ping at [lat] sent at [t] (the car's real position minus the one recorded).
  /// Cached fixes the app's own filter refused on arrival.
  int get staleDropped => filtered.staleDropped;

  double positionErrorM(double lat, DateTime t) => (truthMetresAt(truthLat(secondsSinceRun(t))) - truthMetresAt(lat)).abs();

  /// Metres between two positions on the truth path.
  double truthMetresAt(double lat) => (lat - _lat0) * 111320.0;

  @override
  void run() => _raw.run();
  @override
  void stop() => _raw.stop();
  @override
  Stream<GeoFix> get fixes => filtered.fixes;
  @override
  Future<GeoFix?> current() => filtered.current();
  @override
  Future<bool> ensurePermission() => filtered.ensurePermission();
}

/// A GPS that follows a script: [at] is called once a second (seconds since `run()`) and returns the fix to emit, or null for nothing.
/// `current()` answers with the newest fix after [currentDelay], or null (a stalled platform call) when [currentStalls].
class ScriptGps implements RunnableLocation {
  final DateTime Function() clock;
  final GeoFix? Function(int sec, DateTime now) at;
  final Duration currentDelay;
  final bool currentStalls;
  final _c = StreamController<GeoFix>.broadcast();
  Timer? _t;
  int _sec = 0;
  GeoFix? latest;
  ScriptGps(this.clock, this.at, {this.currentDelay = Duration.zero, this.currentStalls = false});

  @override
  void run() {
    _sec = 0;
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      _sec++;
      final f = at(_sec, clock());
      if (f == null) return;
      latest = f;
      _c.add(f);
    });
  }

  @override
  void stop() => _t?.cancel();
  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async {
    if (currentStalls) {
      await Future<void>.delayed(const Duration(seconds: 15));
      return null;
    }
    if (currentDelay > Duration.zero) await Future<void>.delayed(currentDelay);
    return latest;
  }

  @override
  Future<bool> ensurePermission() async => true;
}

/// A fix at [metres] north of the start, stamped [now], with the given accuracy and (optional) speed.
GeoFix scriptFix(DateTime now, double metresNorth, double acc, {double? speed, DateTime? stamped}) =>
    GeoFix(lat: _lat0 + metresNorth / 111320.0, lon: _lon0, accuracyM: acc, speedMps: speed, at: stamped ?? now);
