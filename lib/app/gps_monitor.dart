// Owns the GPS stream for the length of a drive and turns it into the three things the rest of the app wants, none of which may slow a ping:
//
//  1. the stream stays OPEN (the keepalive that stops iOS ending the background location session when the Drive tab or the engine stops
//     listening; this replaces AppState's old no-op subscription);
//  2. `onFix`: EVERY fix, as it arrives, with speed and course filled in when the OS reported none (derived from the last seconds of fixes,
//     lib/core/fix_window.dart). The map agent animates the puck from this (AppState.rawFixes); the handler does a list insert and one
//     callback, nothing else;
//  3. `onHealth`: a GpsHealth (lib/core/gps_health.dart) recomputed once a second but delivered only when it CHANGED, so the UI is told
//     a few times a minute, not on every fix.
//
// Time runs on a monotonic reading ([mono]); the wall clock is used only to spot a cached position on arrival.
import 'dart:async';

import '../core/drive_health_sink.dart';
import '../core/fix_window.dart';
import '../core/gps_health.dart';
import '../core/startup_location.dart' show LocationAccess;
import '../radio/radio_api.dart';

class GpsMonitor {
  final LocationSource location;
  final void Function(GeoFix fix)? onFix;
  final void Function(GpsHealth health)? onHealth;
  final DriveHealthSink sink;
  final DateTime Function() clock;
  final Duration Function() mono;

  /// Reads the permission state (precise / approximate / denied); polled, never per fix. Null = assume granted.
  final Future<LocationAccess> Function()? access;

  /// Reads While Using vs Always. Null = not applicable.
  final Future<BackgroundLocation> Function()? background;

  /// True while the drive has not sent its first ping (the stricter first-fix rule applies, see [firstPingAccuracyM]).
  final bool Function() firstPingPending;

  /// Formats an accuracy in the person's units ("47 m" / "154 ft"); null = metres.
  final String Function(double metres)? distance;

  /// How often health is recomputed, and the shortest gap between two UI notifications for the same kind of state.
  final Duration period;
  final Duration minNotifyGap;

  GpsMonitor({
    required this.location,
    this.onFix,
    this.onHealth,
    this.sink = const NullDriveHealthSink(),
    DateTime Function()? clock,
    Duration Function()? mono,
    this.access,
    this.background,
    this.firstPingPending = _never,
    this.distance,
    this.period = const Duration(seconds: 1),
    this.minNotifyGap = const Duration(milliseconds: 1500),
  })  : clock = clock ?? DateTime.now,
        mono = mono ?? _stopwatchMono();

  static bool _never() => false;

  static Duration Function() _stopwatchMono() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  final FixWindow _window = FixWindow();
  final StaleFixGuard _guard = StaleFixGuard();
  StreamSubscription<GeoFix>? _sub;
  Timer? _timer;
  Duration? _startedAt;
  Duration? _usableSince; // first time the policy had a usable fix
  LocationAccess _access = LocationAccess.unknown;
  BackgroundLocation _background = BackgroundLocation.notApplicable;
  Duration? _lastAccessCheck;
  bool _checkingAccess = false;
  GpsHealth _health = GpsHealth.idle;
  Duration? _lastNotified;
  bool _disposed = false;

  /// The current health.
  GpsHealth get health => _health;

  /// Fixes the stream delivered / refused as cached, this drive.
  int fixes = 0, cachedRefused = 0;

  bool get running => _sub != null;

  /// Starts watching. Opening the stream here is what keeps it alive.
  void start() {
    if (_sub != null || _disposed) return;
    _startedAt = mono();
    _usableSince = null;
    _window.clear();
    _guard.reset();
    _access = LocationAccess.unknown;
    try {
      _sub = location.fixes.listen(_onFix, onError: (Object _) {});
    } catch (_) {
      _sub = null;
    }
    _timer = Timer.periodic(period, (_) => _tick());
    unawaited(_refreshAccess());
    _tick(force: true);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final s = _sub;
    _sub = null;
    _publish(GpsHealth.idle, force: true);
    if (s != null) await s.cancel();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }

  void _onFix(GeoFix f) {
    if (_disposed) return;
    final now = mono();
    final stale = _guard.isStale(f.at, clock());
    final e = _window.add(f, now, stale: stale);
    if (e == null) {
      cachedRefused++;
      sink.record('fix_drop', {'why': 'cached', 'acc': f.accuracyM});
      return;
    }
    fixes++;
    final cb = onFix;
    if (cb != null) {
      try {
        cb(e);
      } catch (_) {
        // a listener's failure must not touch the GPS
      }
    }
  }

  Future<void> _refreshAccess() async {
    if (_checkingAccess || _disposed) return;
    _checkingAccess = true;
    try {
      final a = access;
      if (a != null) _access = await a();
      final b = background;
      if (b != null) _background = await b();
      _lastAccessCheck = mono();
    } catch (_) {
      // keep the last known state
    } finally {
      _checkingAccess = false;
    }
  }

  void _tick({bool force = false}) {
    if (_disposed || _sub == null) return;
    final now = mono();
    // Re-read the permission now and then, and sooner while there is no fix (the person may have just changed it in Settings).
    final newest = _window.newest;
    final since = _lastAccessCheck;
    final noFix = newest == null || now - newest.arrived >= gpsNoFixAfter;
    if (since == null || now - since >= (noFix ? const Duration(seconds: 5) : const Duration(seconds: 30))) {
      unawaited(_refreshAccess());
    }
    final started = _startedAt ?? now;
    final pick = _window.pick(now, first: firstPingPending(), waited: now - started);
    if (pick != null) _usableSince ??= now;
    final health = computeGpsHealth(
      sinceStart: now - started,
      fixAge: newest == null ? null : now - newest.arrived,
      accuracyM: newest?.fix.accuracyM,
      haveUsableFix: _usableSince != null,
      access: _access,
      background: _background,
      distance: distance,
    );
    _publish(health, force: force);
  }

  void _publish(GpsHealth h, {bool force = false}) {
    final prev = _health;
    if (!force && h == prev) {
      return;
    }
    final now = mono();
    final last = _lastNotified;
    // A change of KIND (good -> no fix) is told at once; the same kind with new words (the seconds counting up) at most every
    // [minNotifyGap], so the UI is not rebuilt every second for a ticking number.
    final sameKind = h.kind == prev.kind;
    if (!force && sameKind && last != null && now - last < minNotifyGap) return;
    _health = h;
    _lastNotified = now;
    if (!sameKind) {
      sink.record('gps', {'kind': h.kind.name, 'line': h.line, 'acc': h.accuracyM, 'age_ms': h.fixAge?.inMilliseconds});
    }
    final cb = onHealth;
    if (cb != null) {
      try {
        cb(h);
      } catch (_) {}
    }
  }
}
