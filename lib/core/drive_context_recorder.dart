// DriveContextRecorder (stream 7 WP2): records a running drive's context beside it (lib/core/drive_context.dart),
// honouring the per-category switches (lib/core/data_categories.dart) at EVERY write, so switching a category off
// takes effect at the very next sample or ping.
//
// One recorder per drive. The drive flow feeds it: GPS fixes ([onFix]), finished pings ([recordPing]), radio samples
// from RadioHealthPoller and phone samples ([recordSample]), and the session snapshot once at start
// ([recordSession]). It never touches the drive itself (pings.jsonl / session.json) and never throws into the
// caller: context is secondary to the save-first ping, so a failed context write is counted and dropped.
//
// Pure Dart: no Flutter imports.
import '../radio/radio_api.dart';
import 'data_categories.dart';
import 'drive_context.dart';
import 'model.dart';

class DriveContextRecorder {
  final DriveContextLedger ledger;
  final String sessionId;

  /// Whether the category with this id is on right now (settings + disclosure seen). Read at every write.
  final bool Function(String categoryId) isOn;

  /// A fix further than this from a ping's time is not used for its context.
  final Duration fixMatchWindow;

  /// A radio/phone sample older than this (relative to the ping) is not copied into the ping's context.
  final Duration sampleMaxAge;

  final List<GeoFix> _fixes = [];
  DriveSample? _lastRadio;
  DriveSample? _lastPhone;
  SessionContext? _session;
  int _failedWrites = 0;
  bool _closed = false;

  DriveContextRecorder({
    required this.ledger,
    required this.sessionId,
    required this.isOn,
    this.fixMatchWindow = const Duration(seconds: 10),
    this.sampleMaxAge = const Duration(minutes: 5),
  });

  /// Writes that failed (e.g. the drive was deleted while recording). For diagnostics only.
  int get failedWrites => _failedWrites;

  /// Categories switched off right now.
  Set<String> offCategories() => {
        for (final c in dataCategories)
          if (!isOn(c.id)) c.id,
      };

  /// Stops recording; later calls do nothing.
  void close() => _closed = true;

  /// Remembers a GPS fix so the ping made from it can get its altitude/course (the last 32 fixes are kept).
  void onFix(GeoFix fix) {
    if (_closed) return;
    _fixes.add(fix);
    if (_fixes.length > 32) _fixes.removeAt(0);
  }

  GeoFix? _fixFor(DateTime at) {
    GeoFix? best;
    Duration? bestGap;
    for (final f in _fixes) {
      final gap = f.at.difference(at).abs();
      if (gap > fixMatchWindow) continue;
      if (bestGap == null || gap < bestGap) {
        best = f;
        bestGap = gap;
      }
    }
    return best;
  }

  bool _fresh(DriveSample? s, DateTime at) => s != null && s.ts.difference(at).abs() <= sampleMaxAge;

  /// The context for a ping at [at] from what the recorder has seen, with switched-off categories removed.
  PingContext contextAt(DateTime at) {
    final fix = _fixFor(at);
    final phone = _fresh(_lastPhone, at) ? _lastPhone : null;
    final radio = _fresh(_lastRadio, at) ? _lastRadio : null;
    return PingContext(
      altM: fix?.altitudeM,
      altAccM: fix?.altitudeAccuracyM,
      courseDeg: fix?.courseDeg,
      courseAccDeg: fix?.courseAccuracyDeg,
      speedAccMps: fix?.speedAccuracyMps,
      pressureHpa: phone?.pressureHpa,
      phoneBattPct: phone?.battPct,
      radioBattMv: radio?.battMv,
    ).without(offCategories());
  }

  /// Records the context of a finished ping. Returns what was written, or null when nothing was (all off, nothing
  /// measured, closed, or the write failed).
  Future<PingContext?> recordPing(DrivePing ping) async {
    if (_closed) return null;
    final ctx = contextAt(ping.ts);
    if (ctx.isEmpty) return null;
    try {
      await ledger.appendPingContext(sessionId, ping.id, ctx);
      return ctx;
    } catch (_) {
      _failedWrites++;
      return null;
    }
  }

  /// Records one radio or phone sample (switched-off categories stripped first). Returns what was written, or null.
  Future<DriveSample?> recordSample(DriveSample sample) async {
    if (_closed) return null;
    final kept = sample.without(offCategories());
    if (sample.src == SampleSource.radio) {
      _lastRadio = kept;
    } else {
      _lastPhone = kept;
    }
    if (kept.isEmpty) return null;
    try {
      await ledger.appendSamples(sessionId, [kept]);
      return kept;
    } catch (_) {
      _failedWrites++;
      return null;
    }
  }

  /// Records the session snapshot (phone/app details, radio identity): once at drive start and again when either
  /// changes (e.g. a reconnect to another radio). A part passed as null keeps what this recorder recorded before.
  /// Returns what was written, or null.
  Future<SessionContext?> recordSession({DeviceDetails? device, CompanionDetails? companion}) async {
    if (_closed) return null;
    final ctx = SessionContext(device: device ?? _session?.device, companionExt: companion ?? _session?.companionExt)
        .without(offCategories());
    if (ctx.isEmpty) return null;
    try {
      await ledger.writeSessionContext(sessionId, ctx);
      _session = ctx;
      return ctx;
    } catch (_) {
      _failedWrites++;
      return null;
    }
  }
}
