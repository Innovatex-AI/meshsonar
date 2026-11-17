// Drive report: the "Battery: 82% → 61% (−21% in 1 h 40 min, −12.6%/h), mode Balanced" headline (build 70, battery
// plan §3). Computed from the phone battery series the drive context already records (category phone_battery,
// DriveContextReport.phoneBatteryPct / DriveSample.battPct). The battery mode at drive start is kept in a small local
// file beside the drive (sessions/<id>/power_mode.txt): it is never uploaded or exported, so the website wire format
// (docs/MESHSONAR_DRIVE_FORMAT.md) is unchanged.
//
// Pure Dart: no Flutter imports.
import 'dart:io';

import 'drive_context.dart';
import 'drive_stats.dart' show formatDuration;
import 'power_profile.dart';

/// The name a person sees for each battery mode (Settings > Battery and the drive report use the same words).
String batteryModeLabel(BatteryMode m) => switch (m) {
      BatteryMode.maxData => 'Max data',
      BatteryMode.balanced => 'Balanced',
      BatteryMode.saver => 'Saver',
      BatteryMode.custom => 'Custom',
    };

/// Shortest drive span for which a per-hour rate is shown (a 2-minute drive would give a silly %/h).
const Duration batteryRateMinSpan = Duration(minutes: 10);

/// Phone battery from the first to the last sample of a drive.
class BatteryUse {
  final DateTime from, to;
  final double startPct, endPct;
  const BatteryUse({required this.from, required this.to, required this.startPct, required this.endPct});

  Duration get span => to.difference(from);

  /// End minus start, percentage points (negative = used).
  double get changePct => endPct - startPct;

  /// Change per hour; null for spans shorter than [batteryRateMinSpan].
  double? get perHour => span < batteryRateMinSpan ? null : changePct / (span.inSeconds / 3600);
}

/// The battery use of a series of (time, %) samples, in time order or not. Null with fewer than 2 samples or when all
/// samples share one time.
BatteryUse? batteryUseOf(List<(DateTime, double)> samples) {
  if (samples.length < 2) return null;
  final s = [...samples]..sort((a, b) => a.$1.compareTo(b.$1));
  if (!s.last.$1.isAfter(s.first.$1)) return null;
  return BatteryUse(from: s.first.$1, to: s.last.$1, startPct: s.first.$2, endPct: s.last.$2);
}

String _signed(double v, int digits) {
  final r = double.parse(v.abs().toStringAsFixed(digits));
  if (r == 0) return '0';
  final txt = digits == 0 ? r.round().toString() : r.toStringAsFixed(digits);
  return v < 0 ? '−$txt' : '+$txt';
}

/// "Battery: 82% → 61% (−21% in 1 h 40 min, −12.6%/h), mode Balanced". [mode] is left out when unknown (drives from
/// before build 70).
String batteryLine(BatteryUse b, {BatteryMode? mode}) {
  final rate = b.perHour;
  final inner = '${_signed(b.changePct, 0)}% in ${formatDuration(b.span)}${rate == null ? '' : ', ${_signed(rate, 1)}%/h'}';
  return 'Battery: ${b.startPct.round()}% → ${b.endPct.round()}% ($inner)'
      '${mode == null ? '' : ', mode ${batteryModeLabel(mode)}'}';
}

/// The battery line of a drive from its stored samples, or null when there are fewer than 2 battery samples.
String? batteryLineFromSamples(List<DriveSample> samples, {BatteryMode? mode}) {
  final use = batteryUseOf([for (final s in samples) if (s.battPct != null) (s.ts, s.battPct!.toDouble())]);
  return use == null ? null : batteryLine(use, mode: mode);
}

// ---------------------------------------------------------------- the mode at drive start (local only)

const String drivePowerModeFile = 'power_mode.txt';

File _modeFile(Directory storeRoot, String sessionId) =>
    File('${storeRoot.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}$sessionId'
        '${Platform.pathSeparator}$drivePowerModeFile');

/// Records [mode] for drive [sessionId] once: the first call (drive start) wins, a later one (a reconnect mid-drive)
/// keeps it. Best effort: a missing session folder or a write error records nothing.
Future<void> recordDrivePowerMode(Directory storeRoot, String sessionId, BatteryMode mode) async {
  try {
    final f = _modeFile(storeRoot, sessionId);
    if (!await f.parent.exists() || await f.exists()) return;
    await f.writeAsString(mode.name, flush: true);
  } catch (_) {}
}

/// The battery mode recorded at the start of drive [sessionId]; null when none was recorded.
Future<BatteryMode?> readDrivePowerMode(Directory storeRoot, String sessionId) async {
  try {
    final f = _modeFile(storeRoot, sessionId);
    if (!await f.exists()) return null;
    final v = (await f.readAsString()).trim();
    for (final m in BatteryMode.values) {
      if (m.name == v) return m;
    }
  } catch (_) {}
  return null;
}

/// The battery line of drive [sessionId] from its stored context and the mode recorded at its start; null when the
/// drive has fewer than 2 battery samples (or no context storage). Never throws.
Future<String?> loadDriveBatteryLine(DriveContextLedger? ledger, Directory? storeRoot, String sessionId) async {
  if (ledger == null) return null;
  try {
    final samples = await ledger.samples(sessionId);
    final mode = storeRoot == null ? null : await readDrivePowerMode(storeRoot, sessionId);
    return batteryLineFromSamples(samples, mode: mode);
  } catch (_) {
    return null;
  }
}
