// "Map and GPS health": hard numbers from a real drive, one line per 10 seconds, so a map that still feels wrong can be
// diagnosed from the file instead of from memory. Pure Dart.
//
// The recorder is passive: the map calls [onFrame] with each frame's timings and [maybeSample] whenever it has a moment (every
// GPS fix, every puck frame); a sample is written when [interval] has passed. No timers, so nothing stays pending after a
// screen is gone. Samples go through a [MapHealthSink], an interface the ping engine can write to as well (give it records with
// its own `kind`), and are stored by the drive store as `map_health.jsonl` beside the drive (local only, size-capped).
//
// A sample (`kind: map_health`):
//   t, window_s,
//   frames   {frames, p50_ms, p95_ms, p99_ms, worst_ms, build_p95_ms, raster_p95_ms, janky_16, janky_8, stalls_50}
//   puck     {puck_updates_hz, fixes, fixes_rejected, max_fix_gap_s, weak_frames, compass_readings}
//   camera   {mode: follow|paused|off, heading_up, zoom, drives}
//   tiles    {source, cache_hit, network_ok, stale_served, failed, offline_empty, cancelled, pack_covered_skipped, pack_hit,
//             pack_miss}
//   layers   {cell_paints}
//   loop     {max_lag_ms}  longest stretch the UI isolate went without a chance to run in the window (event-loop probe)
import 'dart:async';

import 'drive_store.dart' show MapHealthStore;
import 'frame_stats.dart';

abstract interface class MapHealthSink {
  /// Stores one record. Must not throw; failures are the sink's to swallow.
  void write(Map<String, Object?> record);
}

/// Keeps records in memory (tests, the on-screen overlay).
class MemoryHealthSink implements MapHealthSink {
  final List<Map<String, Object?>> records = [];
  @override
  void write(Map<String, Object?> record) => records.add(record);
}

typedef HealthProvider = Map<String, Object?> Function(double windowS);

class MapHealthRecorder {
  final MapHealthSink sink;
  final Duration interval;
  final DateTime Function() clock;

  /// Name -> a function returning that section of the sample. Each provider also resets its own counters.
  final Map<String, HealthProvider> providers = {};

  MapHealthRecorder({required this.sink, this.interval = const Duration(seconds: 10), DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  final FrameStatsWindow _frames = FrameStatsWindow();
  DateTime? _windowStart;
  bool _running = false;
  int samples = 0;

  /// The newest sample (the on-screen overlay shows it).
  Map<String, Object?>? last;

  /// Called after each sample is written (the overlay refreshes).
  void Function(Map<String, Object?> sample)? onSample;

  bool get running => _running;

  void start() {
    _running = true;
    _windowStart = clock();
    _frames.reset();
  }

  void stop({bool flush = true}) {
    if (_running && flush) maybeSample(clock(), force: true);
    _running = false;
  }

  void onFrame(FrameSample s) {
    if (_running) _frames.add(s);
  }

  /// Writes a sample when the window is full (or [force]). Returns true when it wrote one.
  bool maybeSample(DateTime now, {bool force = false}) {
    if (!_running) return false;
    final start = _windowStart ??= now;
    final span = now.difference(start);
    if (!force && span < interval) return false;
    if (span.inMilliseconds < 500) return false; // nothing worth writing
    final windowS = span.inMicroseconds / 1e6;
    final rec = <String, Object?>{
      'kind': 'map_health',
      't': now.toUtc().toIso8601String(),
      'window_s': double.parse(windowS.toStringAsFixed(1)),
      'frames': _frames.snapshot().toJson(),
    };
    for (final e in providers.entries) {
      try {
        rec[e.key] = e.value(windowS);
      } catch (_) {
        rec[e.key] = {'error': true};
      }
    }
    _frames.reset();
    _windowStart = now;
    samples++;
    last = rec;
    try {
      sink.write(rec);
    } catch (_) {}
    onSample?.call(rec);
    return true;
  }
}

/// Writes records into the current drive's folder through [store]. [sessionId] says which drive is recording (null: nothing
/// is written, e.g. the map is open but no drive is running).
class DriveStoreHealthSink implements MapHealthSink {
  final MapHealthStore store;
  final String? Function() sessionId;
  DriveStoreHealthSink(this.store, this.sessionId);

  @override
  void write(Map<String, Object?> record) {
    final id = sessionId();
    if (id == null) return;
    unawaited(store.appendMapHealth(id, record).catchError((Object _) {}));
  }
}

/// What the map tells the recorder about its camera (written by the map each frame it drives, read at each sample).
class CameraTelemetry {
  /// follow, paused or off (a map that is not following a puck).
  String mode = 'off';
  bool headingUp = false;
  double zoom = 0;

  /// Frames in which the camera was moved by the follower, and cell-layer pictures painted, since the last sample.
  int drives = 0;
  int cellPaints = 0;

  Map<String, Object?> cameraJson(double windowS) {
    final out = <String, Object?>{'mode': mode, 'heading_up': headingUp, 'zoom': double.parse(zoom.toStringAsFixed(2)), 'drives': drives};
    drives = 0;
    return out;
  }

  Map<String, Object?> layersJson(double windowS) {
    final out = <String, Object?>{'cell_paints': cellPaints};
    cellPaints = 0;
    return out;
  }
}
