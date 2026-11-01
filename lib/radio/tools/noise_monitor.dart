// Noise floor and radio health, live. Samples GET_STATS (radio: noise floor, last RSSI/SNR, tx/rx air seconds) at a low
// priority (command class "discovery", P4) so a message, an ack or a ping always goes first, never while a ping is in
// flight (the [busy] callback), and only while a screen is watching ([start]/[stop]). Every sixth sample also reads the core
// and packet counters (queue length, error flags, receive errors).
//
// Thresholds are the website's, in lib/core/rf_thresholds.dart (meshcore-insights analysis-rf.ts): above -100 dBm is
// interference ("noisy"), above -110 is raised, otherwise quiet. A noise floor of 0 is "not measured yet", not 0 dBm
// (RadioLibWrappers starts it at 0). Layouts VERIFIED on hardware (stats radio 14 B, core 11 B, packets 30 B).
// Pure Dart.
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../../core/rf_thresholds.dart';
import '../command_queue.dart';
import '../tx_arbiter.dart';
import 'tool_state.dart';
import 'tools_radio.dart';

class NoiseSample {
  final DateTime at;
  final int? noiseDbm;
  final int? lastRssiDbm;
  final double? lastSnrDb;
  final int? txAirSecs, rxAirSecs;
  const NoiseSample(this.at, {this.noiseDbm, this.lastRssiDbm, this.lastSnrDb, this.txAirSecs, this.rxAirSecs});
}

class NoiseStats {
  final int count;
  final double min, avg, max;
  const NoiseStats(this.count, this.min, this.avg, this.max);
}

/// What MeshSonar itself has put on the air.
class OwnAirtime {
  /// Own transmit time in the last hour (the cap window), ms, from the arbiter ledger.
  final double lastHourMs;

  /// The region cap for that hour, ms (1% of an hour by default).
  final double capMs;

  /// Ping airtime in the last 10 minutes, ms.
  final double pingsLast10MinMs;
  final int pingsSent;
  final int userSends;
  const OwnAirtime(this.lastHourMs, this.capMs, this.pingsLast10MinMs, this.pingsSent, this.userSends);

  double get fractionOfCap => capMs <= 0 ? 0 : lastHourMs / capMs;
}

class CoreHealth {
  final int? queueLen;
  final int? errFlags;
  final int? recvErrors;
  const CoreHealth({this.queueLen, this.errFlags, this.recvErrors});
}

class NoiseMonitor with ToolChanges {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final DateTime Function() _clock;
  final int capacity;
  Duration interval;

  /// True while a wardrive ping is in flight: the sample is skipped.
  final bool Function()? busy;

  final Queue<NoiseSample> _ring = Queue();
  Timer? _timer;
  bool _reading = false;
  int _tick = 0;
  CoreHealth _core = const CoreHealth();
  bool _unsupported = false;

  NoiseMonitor(this.radio, this.arbiter, {DateTime Function()? clock, this.capacity = 360, this.interval = const Duration(seconds: 10), this.busy})
      : _clock = clock ?? DateTime.now;

  bool get running => _timer != null;

  /// The radio says it cannot report stats (firmware older than 8).
  bool get unsupported => _unsupported;
  List<NoiseSample> get samples => _ring.toList();
  CoreHealth get core => _core;
  NoiseSample? get latest => _ring.isEmpty ? null : _ring.last;

  void start() {
    if (_timer != null) return;
    unawaited(sampleNow());
    _timer = Timer.periodic(interval, (_) => unawaited(sampleNow()));
    notifyChanged();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    notifyChanged();
  }

  void setInterval(Duration d) {
    interval = d;
    if (_timer != null) {
      stop();
      start();
    }
  }

  void clear() {
    _ring.clear();
    notifyChanged();
  }

  /// Reads the radio once. Skipped (returns null) while a ping is in flight, a read is already running, or no radio.
  Future<NoiseSample?> sampleNow() async {
    if (_reading || !radio.isConnected || _unsupported) return null;
    if (busy?.call() ?? false) return null;
    _reading = true;
    try {
      final r = await radio.radioStats(priority: CommandPriority.discovery);
      if (r == null) {
        // Null means timeout or unsupported; after three in a row with nothing ever read, say so.
        if (_ring.isEmpty && ++_misses >= 3) _unsupported = true;
        notifyChanged();
        return null;
      }
      _misses = 0;
      final heard = r.lastRssiDbm != 0;
      final s = NoiseSample(_clock(),
          noiseDbm: r.noiseFloorDbm == 0 ? null : r.noiseFloorDbm,
          lastRssiDbm: heard ? r.lastRssiDbm : null,
          lastSnrDb: heard ? r.lastSnrDb : null,
          txAirSecs: r.txAirSecs,
          rxAirSecs: r.rxAirSecs);
      _ring.addLast(s);
      while (_ring.length > capacity) {
        _ring.removeFirst();
      }
      if (_tick++ % 6 == 0) await _readCore();
      notifyChanged();
      return s;
    } catch (_) {
      return null;
    } finally {
      _reading = false;
    }
  }

  int _misses = 0;

  Future<void> _readCore() async {
    try {
      final c = await radio.coreStats(priority: CommandPriority.discovery);
      final p = await radio.packetStats(priority: CommandPriority.discovery);
      _core = CoreHealth(queueLen: c?.queueLen, errFlags: c?.errFlags, recvErrors: p?.recvErrors);
    } catch (_) {}
  }

  /// Min / mean / max of the noise floor over the samples held; null when none was measured.
  NoiseStats? get stats {
    final v = [for (final s in _ring) if (s.noiseDbm != null) s.noiseDbm!.toDouble()];
    if (v.isEmpty) return null;
    return NoiseStats(v.length, v.reduce(math.min), v.reduce((a, b) => a + b) / v.length, v.reduce(math.max));
  }

  /// Samples that jump at least [jumpDb] above the typical level (the median), or cross above the interference line.
  List<NoiseSample> spikes({double jumpDb = 6}) {
    final vals = [for (final s in _ring) if (s.noiseDbm != null) s.noiseDbm!.toDouble()]..sort();
    if (vals.length < 8) return const [];
    final median = vals[vals.length ~/ 2];
    final out = <NoiseSample>[];
    int? prev;
    for (final s in _ring) {
      final n = s.noiseDbm;
      if (n == null) continue;
      final crossed = prev != null && prev <= noiseFloorInterferenceDbm && n > noiseFloorInterferenceDbm;
      if (n >= median + jumpDb || crossed) out.add(s);
      prev = n;
    }
    return out;
  }

  /// The verdict for the typical (mean) level; null with no measurement.
  NoiseVerdict? get verdict => noiseVerdict(stats?.avg);

  /// "Quiet", "Raised", "Noisy" — or null with no measurement.
  String? get verdictWord => switch (verdict) {
        NoiseVerdict.normal => 'Quiet',
        NoiseVerdict.elevated => 'Raised',
        NoiseVerdict.interference => 'Noisy',
        null => null,
      };

  /// The website's wording for the verdict.
  String? get interpretation {
    final v = verdict;
    return v == null ? null : noiseVerdictText(v);
  }

  /// Seconds the radio itself reports it transmitted / received since the first sample held.
  ({int? txSecs, int? rxSecs}) get radioAirSinceFirst {
    if (_ring.length < 2) return (txSecs: null, rxSecs: null);
    final a = _ring.first, b = _ring.last;
    int? d(int? x, int? y) => x == null || y == null || y < x ? null : y - x;
    return (txSecs: d(a.txAirSecs, b.txAirSecs), rxSecs: d(a.rxAirSecs, b.rxAirSecs));
  }

  OwnAirtime get ownAirtime {
    final snap = arbiter.snapshot();
    final cap = arbiter.policy.shownCapFraction * arbiter.policy.capWindow.inMilliseconds;
    return OwnAirtime(snap.totalMsInCapWindow, cap, snap.pingMsInWindow, snap.pingsSent, snap.userSends);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    disposeChanges();
  }
}
