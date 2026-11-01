// Where drive-health facts go. The engine, the GPS monitor and (for the map) the UI report what they observe while a drive runs; the app
// implements this by writing each record to the drive's local `trace.jsonl` (never uploaded, never part of the Drive Format).
//
// FOR THE MAP AGENT: to log UI frame lateness (or anything else that would explain a late ping), call
//   app.driveHealthSink.record('frame', {'late_ms': 140, 'worst_ms': 210, 'n': 12});
// at most a few times a second (a sink already drops anything above 4 records/s per kind). `kind` is a short snake_case name, `data` is a
// flat JSON-ready map. Never block, never await: recording is fire-and-forget and swallows its own errors. Kinds the app itself writes:
//   `gps` (health changes), `fix_drop` (cached/poor fixes refused), `timing` (the end-of-drive summary), plus the engine's per-ping records.
abstract class DriveHealthSink {
  void record(String kind, Map<String, Object?> data);
}

/// Drops everything. The default when no drive is recording.
class NullDriveHealthSink implements DriveHealthSink {
  const NullDriveHealthSink();
  @override
  void record(String kind, Map<String, Object?> data) {}
}

/// Writes each record as `{v:1, health:<kind>, at:<UTC ISO>, ...data}` through [write] (the trace writer), at most [perSecond] per kind.
class TraceDriveHealthSink implements DriveHealthSink {
  final void Function(Map<String, Object?> record) write;
  final DateTime Function() clock;
  final int perSecond;
  TraceDriveHealthSink(this.write, {DateTime Function()? clock, this.perSecond = 4}) : clock = clock ?? DateTime.now;

  final Map<String, ({int secondEpoch, int n})> _recent = {};

  @override
  void record(String kind, Map<String, Object?> data) {
    try {
      final now = clock();
      final sec = now.millisecondsSinceEpoch ~/ 1000;
      final prev = _recent[kind];
      final n = prev != null && prev.secondEpoch == sec ? prev.n + 1 : 1;
      _recent[kind] = (secondEpoch: sec, n: n);
      if (n > perSecond) return;
      write({'v': 1, 'health': kind, 'at': now.toUtc().toIso8601String(), ...data});
    } catch (_) {
      // a failing trace must never touch a drive
    }
  }
}
