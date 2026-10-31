// Idle region detection (parity spec WP-R4): while the person is NOT driving, a low-power foreground location stream
// feeds the region tracker so the Region tab / switcher follows where the phone actually is, not just where it was when
// the app opened. Pure Dart; the platform stream sits behind [IdleLocationSource].
//
// Battery rules: coarse accuracy and a big distance filter (the source's job), at most one fix per [minGap] reaches the
// app, and the stream is cancelled whenever it cannot matter: during a drive (the engine's own stream feeds the
// tracker then) and while the app is in the background (never a background stream between drives, even with
// "Always" location granted: Always is for recording drives).
// It never touches the radio: a different radio preset is only ever a prompt (AppState._onRegionChanged).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../radio/radio_api.dart';

abstract class IdleLocationSource {
  /// A low-power fix stream. [background] = it must keep delivering while the app is not in front (only asked for when
  /// "Always" location is granted).
  Stream<GeoFix> fixes({required bool background});

  /// True when the platform granted "Always" location (iOS); false elsewhere or when unknown.
  Future<bool> hasAlways();

  /// True when location may be used at all. Does not prompt: the idle watcher never asks for permission on its own.
  Future<bool> permitted();
}

/// The last place the phone was seen, kept on disk so the Region tab can show the right region at the next launch
/// before the first GPS fix arrives.
class LastKnownStore {
  final File file;
  LastKnownStore(this.file);

  Future<GeoFix?> load() async {
    try {
      if (!await file.exists()) return null;
      final j = jsonDecode(await file.readAsString());
      if (j is! Map) return null;
      final lat = j['lat'], lon = j['lon'], at = DateTime.tryParse('${j['at']}');
      if (lat is! num || lon is! num || at == null) return null;
      return GeoFix(lat: lat.toDouble(), lon: lon.toDouble(), at: at.toUtc());
    } catch (_) {
      return null;
    }
  }

  Future<void> save(GeoFix fix) async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({'lat': fix.lat, 'lon': fix.lon, 'at': fix.at.toUtc().toIso8601String()}), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // A read-only disk only costs the launch-time guess.
    }
  }
}

class IdleRegionWatcher {
  final IdleLocationSource source;
  final void Function(GeoFix fix) onFix;
  final LastKnownStore? store;

  /// Fixes closer together than this are dropped (the distance filter already thins them; this is the backstop).
  final Duration minGap;

  IdleRegionWatcher({required this.source, required this.onFix, this.store, this.minGap = const Duration(seconds: 20)});

  bool _started = false;
  bool _driving = false;
  bool _foreground = true;
  StreamSubscription<GeoFix>? _sub;
  int _gen = 0;
  DateTime? _lastAccepted;

  /// True while a location subscription is open (tests).
  bool get listening => _sub != null;

  Future<void> start() {
    _started = true;
    return _reconcile();
  }

  Future<void> stop() {
    _started = false;
    return _reconcile();
  }

  Future<void> setDriving(bool driving) {
    _driving = driving;
    return _reconcile();
  }

  Future<void> setForeground(bool foreground) {
    _foreground = foreground;
    return _reconcile();
  }

  Future<void> dispose() => stop();

  Future<void> _reconcile() async {
    final gen = ++_gen;
    if (!_started || _driving) return _cancel();
    // App Review (2.5.4 / 5.1.1): background location is for recording a drive only. Between drives this stream
    // runs in the foreground and nowhere else, whatever permission is granted; the app re-reads the position when it
    // comes back to the front.
    if (!_foreground) return _cancel();
    if (_sub != null) return;
    final ok = await _safe(source.permitted);
    if (gen != _gen || _sub != null) return;
    if (!ok) return;
    _sub = source.fixes(background: false).listen(_handle, onError: (_) {});
  }

  Future<void> _cancel() async {
    final s = _sub;
    _sub = null;
    await s?.cancel();
  }

  static Future<bool> _safe(Future<bool> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return false;
    }
  }

  void _handle(GeoFix fix) {
    final last = _lastAccepted;
    if (last != null) {
      final d = fix.at.difference(last); // by the fix's own time; a clock jump backwards is accepted
      if (d >= Duration.zero && d < minGap) return;
    }
    _lastAccepted = fix.at;
    final s = store;
    if (s != null) s.save(fix);
    onFix(fix);
  }
}
