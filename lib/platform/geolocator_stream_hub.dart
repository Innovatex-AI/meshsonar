// ONE owner of the geolocator position stream.
//
// Why this exists (found by reading geolocator_apple 2.3.15 / geolocator_android 5.1.1, Nov 1 2026): `Geolocator.getPositionStream`
// memoises the stream. While ANY listener is attached, every later call returns the SAME stream and its `locationSettings`
// argument is ignored; the platform side was started with the settings of whoever listened first. The idle region watcher listens
// in the foreground with `LocationAccuracy.low`, a 500 m distance filter, auto-pause on and no background updates. Starting a drive
// while it was still listening therefore got THE IDLE STREAM: Wi-Fi/cell-grade fixes (35-46 m, Andy's whole day), one fix per
// 500 m, iOS free to pause updates, no background session. The "bestForNavigation / automotiveNavigation / distanceFilter 0"
// settings in GeolocatorLocationSource were never applied. That is the "pings hang, the dot does not follow me" bug.
//
// The hub is the only caller of `Geolocator.getPositionStream`. Consumers ask for a profile; the hub runs the underlying stream with
// the settings of the most demanding profile any consumer needs and RESTARTS it (cancel, then listen again so the plugin's memo is
// cleared) whenever that changes. A drive therefore always gets drive settings, whatever was listening before it, and after the
// drive the idle consumer is moved back to its cheap settings. Pure plumbing: no policy.
import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// What a consumer needs. Higher index wins.
enum HubProfile { idle, drive }

class _Consumer {
  final HubProfile profile;
  final LocationSettings settings;
  final String key;
  final StreamController<Position> out;
  _Consumer(this.profile, this.settings, this.key, this.out);
}

class GeolocatorStreamHub {
  GeolocatorStreamHub({
    Stream<Position> Function(LocationSettings settings)? open,
  }) : _open =
           open ?? ((s) => Geolocator.getPositionStream(locationSettings: s));

  /// The app-wide hub.
  static final GeolocatorStreamHub shared = GeolocatorStreamHub();

  final Stream<Position> Function(LocationSettings settings) _open;
  final List<_Consumer> _consumers = [];
  StreamSubscription<Position>? _sub;
  String? _activeKey;
  int _generation = 0;
  Future<void> _chain = Future.value();

  /// How many times the underlying platform stream was (re)started; for tests and diagnostics.
  int starts = 0;

  /// The key of the settings the underlying stream runs with now; null when it is not running.
  String? get activeKey => _activeKey;

  /// A broadcast stream of positions for [profile]. [key] names the exact settings (two consumers with the same key share one
  /// platform stream). Listening starts the platform stream (or restarts it with more demanding settings); the last cancel stops it.
  Stream<Position> stream(
    HubProfile profile,
    LocationSettings settings, {
    required String key,
  }) {
    late _Consumer c;
    final out = StreamController<Position>.broadcast(
      onListen: () {
        _consumers.add(c);
        _reconcile();
      },
      onCancel: () {
        _consumers.remove(c);
        _reconcile();
      },
    );
    c = _Consumer(profile, settings, key, out);
    return out.stream;
  }

  _Consumer? _wanted() {
    _Consumer? best;
    for (final c in _consumers) {
      if (best == null || c.profile.index > best.profile.index) best = c;
    }
    return best;
  }

  void _reconcile() {
    final gen = ++_generation;
    _chain = _chain.then((_) => _apply(gen)).catchError((Object _) {});
  }

  Future<void> _apply(int gen) async {
    if (gen != _generation) return; // a newer change supersedes this one
    final want = _wanted();
    if (want == null) {
      await _stop();
      return;
    }
    if (_sub != null && _activeKey == want.key) return;
    await _stop();
    if (gen != _generation) return;
    starts++;
    _activeKey = want.key;
    // Cancelling the previous listener cleared the plugin's memo, so this call really starts a new platform stream.
    _sub = _open(want.settings)
        .listen(_fan, onError: _fanError, cancelOnError: false);
  }

  Future<void> _stop() async {
    final s = _sub;
    _sub = null;
    _activeKey = null;
    if (s != null) await s.cancel();
  }

  void _fan(Position p) {
    for (final c in List.of(_consumers)) {
      if (!c.out.isClosed) c.out.add(p);
    }
  }

  void _fanError(Object e, StackTrace st) {
    for (final c in List.of(_consumers)) {
      if (!c.out.isClosed) c.out.addError(e, st);
    }
  }
}
