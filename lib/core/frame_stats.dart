// Frame-time statistics for the map jank benchmark and the "Map and GPS health" recorder. Pure Dart.
//
// A frame costs the UI thread its build time and the raster thread its raster time; the two overlap in a pipeline, so the
// number that decides whether a frame made its deadline is the larger of them (Flutter's own jank rule). [FrameSample.costMs]
// is that number. [FrameSample.spanMs] is vsync start to raster finish (what the person waits for).
import 'dart:math' as math;

class FrameSample {
  final double buildMs;
  final double rasterMs;
  final double spanMs;
  const FrameSample(this.buildMs, this.rasterMs, this.spanMs);
  double get costMs => math.max(buildMs, rasterMs);
}

class FrameStatsSnapshot {
  final int frames;
  final double p50Ms, p95Ms, p99Ms, worstMs;
  final double buildP95Ms, rasterP95Ms;

  /// Frames whose cost went over 16.7 ms / 8.3 ms (the 60 Hz and 120 Hz budgets).
  final int janky60, janky120;

  /// Frames over 50 ms (a visible stall).
  final int stalls;
  const FrameStatsSnapshot({
    required this.frames,
    required this.p50Ms,
    required this.p95Ms,
    required this.p99Ms,
    required this.worstMs,
    required this.buildP95Ms,
    required this.rasterP95Ms,
    required this.janky60,
    required this.janky120,
    required this.stalls,
  });

  static const FrameStatsSnapshot empty = FrameStatsSnapshot(
    frames: 0,
    p50Ms: 0,
    p95Ms: 0,
    p99Ms: 0,
    worstMs: 0,
    buildP95Ms: 0,
    rasterP95Ms: 0,
    janky60: 0,
    janky120: 0,
    stalls: 0,
  );

  Map<String, Object?> toJson() => {
    'frames': frames,
    'p50_ms': _r(p50Ms),
    'p95_ms': _r(p95Ms),
    'p99_ms': _r(p99Ms),
    'worst_ms': _r(worstMs),
    'build_p95_ms': _r(buildP95Ms),
    'raster_p95_ms': _r(rasterP95Ms),
    'janky_16': janky60,
    'janky_8': janky120,
    'stalls_50': stalls,
  };

  @override
  String toString() =>
      'frames=$frames p50=${_r(p50Ms)} p95=${_r(p95Ms)} p99=${_r(p99Ms)} worst=${_r(worstMs)} (build p95 ${_r(buildP95Ms)}, raster p95 ${_r(rasterP95Ms)}) '
      'janky>16.7=$janky60 janky>8.3=$janky120 stalls>50=$stalls';
}

double _r(double v) => (v * 100).round() / 100;

/// Collects frames; [snapshot] summarises them, [reset] starts a new window.
class FrameStatsWindow {
  final List<FrameSample> _frames = [];

  /// Never keeps more than this many samples (a runaway window cannot grow without bound).
  final int maxFrames;
  FrameStatsWindow({this.maxFrames = 20000});

  int get length => _frames.length;
  List<FrameSample> get samples => List.unmodifiable(_frames);

  void add(FrameSample s) {
    if (_frames.length < maxFrames) _frames.add(s);
  }

  void reset() => _frames.clear();

  FrameStatsSnapshot snapshot() => summariseFrames(_frames);
}

double _pct(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final i = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[i];
}

FrameStatsSnapshot summariseFrames(List<FrameSample> frames) {
  if (frames.isEmpty) return FrameStatsSnapshot.empty;
  final cost = [for (final f in frames) f.costMs]..sort();
  final build = [for (final f in frames) f.buildMs]..sort();
  final raster = [for (final f in frames) f.rasterMs]..sort();
  return FrameStatsSnapshot(
    frames: frames.length,
    p50Ms: _pct(cost, 0.5),
    p95Ms: _pct(cost, 0.95),
    p99Ms: _pct(cost, 0.99),
    worstMs: cost.last,
    buildP95Ms: _pct(build, 0.95),
    rasterP95Ms: _pct(raster, 0.95),
    janky60: cost.where((c) => c > 16.7).length,
    janky120: cost.where((c) => c > 8.3).length,
    stalls: cost.where((c) => c > 50).length,
  );
}
