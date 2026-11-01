// "How is the GPS doing" as one value the drive screen can show: a kind, a plain-English line and, when the person can fix it, an action.
// Pure Dart: [computeGpsHealth] takes plain numbers, so every state is a unit test. The app's GpsMonitor feeds it once a second and only
// notifies the UI when the result changes.
import 'startup_location.dart' show LocationAccess;

enum GpsHealthKind {
  /// Nothing to show yet (no drive running).
  idle,

  /// Location is off or not allowed for the app; pings cannot be placed.
  noPermission,

  /// iOS "Precise Location" is off: fixes are kilometres wide.
  approximate,

  /// Drive started, no usable fix yet.
  waiting,

  /// Fixes stopped arriving.
  noFix,

  /// Fixes arrive but are poor.
  weak,

  /// Fine.
  good,
}

/// What the person can do about it, handled by the app (open the phone's Settings).
enum GpsHealthAction { none, openAppSettings, openLocationSettings }

/// The background permission level on the platform that has one (iOS). `notApplicable` = Android / desktop.
enum BackgroundLocation { unknown, always, whileUsing, notApplicable }

/// Accuracy at or better than this is "good" (metres).
const double gpsGoodAccuracyM = 25;

/// No fix for this long is worth saying so (the engine keeps using the window up to 8 s).
const Duration gpsNoFixAfter = Duration(seconds: 8);

class GpsHealth {
  final GpsHealthKind kind;

  /// The line for the drive screen.
  final String line;

  /// A second, quieter line (what to do), or null.
  final String? advice;
  final GpsHealthAction action;
  final double? accuracyM;

  /// Age of the newest fix (monotonic); null when there is none.
  final Duration? fixAge;

  /// How long the drive has been waiting for its first usable fix; null once it has one.
  final Duration? waited;
  const GpsHealth(
    this.kind,
    this.line, {
    this.advice,
    this.action = GpsHealthAction.none,
    this.accuracyM,
    this.fixAge,
    this.waited,
  });

  static const GpsHealth idle = GpsHealth(GpsHealthKind.idle, '');

  /// True when the person should look at it.
  bool get needsAttention => kind != GpsHealthKind.good && kind != GpsHealthKind.idle;

  /// Same words and state: what decides whether the UI is told again.
  @override
  bool operator ==(Object other) =>
      other is GpsHealth && other.kind == kind && other.line == line && other.advice == advice && other.action == action;
  @override
  int get hashCode => Object.hash(kind, line, advice, action);
  @override
  String toString() => 'GpsHealth($kind, "$line")';
}

String _metres(double m) => '${m.round()} m';

String _secs(Duration d) => '${d.inSeconds} s';

/// [sinceStart] = time since the drive began; [fixAge] / [accuracyM] = the newest fix the stream delivered (null = none yet);
/// [haveUsableFix] = at least one fix has met the ping policy this drive; [access] / [background] = the permission state;
/// [distance] formats a length in the person's units (the app passes `Units.shortLength`; the default is whole metres).
GpsHealth computeGpsHealth({
  required Duration sinceStart,
  Duration? fixAge,
  double? accuracyM,
  required bool haveUsableFix,
  LocationAccess access = LocationAccess.unknown,
  BackgroundLocation background = BackgroundLocation.notApplicable,
  String Function(double metres)? distance,
}) {
  final dist = distance ?? _metres;
  switch (access) {
    case LocationAccess.servicesOff:
      return const GpsHealth(GpsHealthKind.noPermission, 'Location is turned off on this phone.',
          advice: 'Turn on Location Services in Settings, then pings can be placed.', action: GpsHealthAction.openLocationSettings);
    case LocationAccess.denied:
    case LocationAccess.deniedForever:
    case LocationAccess.restricted:
    case LocationAccess.notAsked:
      return const GpsHealth(GpsHealthKind.noPermission, 'MeshSonar is not allowed to use your location.',
          advice: 'Allow Location for MeshSonar in Settings > MeshSonar > Location.', action: GpsHealthAction.openAppSettings);
    case LocationAccess.approximate:
      return const GpsHealth(GpsHealthKind.approximate, 'Precise Location is off.',
          advice: 'Pings would land up to a kilometre from you. Turn on Precise Location in Settings > MeshSonar > Location.',
          action: GpsHealthAction.openAppSettings);
    case LocationAccess.unknown:
    case LocationAccess.granted:
      break;
  }
  final advice = background == BackgroundLocation.whileUsing
      ? 'Location is set to While Using: pings stop when you leave the app or lock the phone. Choose Always in Settings > MeshSonar > Location.'
      : null;

  if (!haveUsableFix) {
    final best = accuracyM;
    final tail = fixAge != null && best != null && best > pingAccuracyLimitForText ? ' (best so far ±${dist(best)})' : '';
    return GpsHealth(GpsHealthKind.waiting, 'Waiting for GPS (${_secs(sinceStart)})$tail',
        advice: advice, accuracyM: best, fixAge: fixAge, waited: sinceStart);
  }
  if (fixAge == null || fixAge >= gpsNoFixAfter) {
    final age = fixAge ?? sinceStart;
    return GpsHealth(GpsHealthKind.noFix, 'No GPS for ${_secs(age)}',
        advice: age >= const Duration(seconds: 20) ? 'Check that Location is on and the phone can see the sky.' : advice,
        fixAge: fixAge);
  }
  final acc = accuracyM;
  if (acc != null && acc > gpsGoodAccuracyM) {
    return GpsHealth(GpsHealthKind.weak, 'GPS weak (${dist(acc)})', advice: advice, accuracyM: acc, fixAge: fixAge);
  }
  return GpsHealth(GpsHealthKind.good, acc == null ? 'GPS good' : 'GPS good (${dist(acc)})', advice: advice, accuracyM: acc, fixAge: fixAge);
}

/// Only used to decide when "best so far" is worth printing while waiting (a coarse fix, not a near miss).
const double pingAccuracyLimitForText = 50;
