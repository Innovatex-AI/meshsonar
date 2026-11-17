// Which GPS settings the drive stream runs with right now (build 70, battery plan §3 "Drive GPS precision" / "Pause GPS when
// parked", A10). Pure Dart. The drive's GpsMonitor decides the mode once a second (lib/app/drive_power_governor.dart); the
// platform source (lib/platform/geolocator_location.dart) listens and re-subscribes the platform stream when it changes.
import 'power_profile.dart';

/// The drive GPS settings in force.
///  * [best]: navigation accuracy, every fix (Max data).
///  * [high]: best accuracy, 5 m filter (Balanced; also the cap while no radio is connected).
///  * [standard]: ~10 m accuracy, 15 m filter (Saver).
///  * [parked]: the car has not moved for a while: ~100 m accuracy, 50 m filter, until the phone moves 50 m.
enum DriveGpsMode { best, high, standard, parked }

DriveGpsMode driveGpsModeOf(GpsPrecision p) => switch (p) {
      GpsPrecision.best => DriveGpsMode.best,
      GpsPrecision.high => DriveGpsMode.high,
      GpsPrecision.standard => DriveGpsMode.standard,
    };

/// The mode a drive should run with. [radioConnected] false caps it at [DriveGpsMode.high] (no pings are possible, A10);
/// [parked] wins over everything.
DriveGpsMode effectiveDriveGpsMode({required GpsPrecision chosen, required bool radioConnected, required bool parked}) {
  if (parked) return DriveGpsMode.parked;
  final m = driveGpsModeOf(chosen);
  if (!radioConnected && m == DriveGpsMode.best) return DriveGpsMode.high;
  return m;
}

/// The app-wide drive GPS mode. Null [set] value = follow the chosen profile (no drive is deciding).
class DriveGpsTuning {
  DriveGpsTuning();

  static final DriveGpsTuning shared = DriveGpsTuning();

  DriveGpsMode? _mode;
  final List<void Function()> _listeners = [];

  /// The mode in force: what the running drive decided, else the chosen profile's precision.
  DriveGpsMode get mode => _mode ?? driveGpsModeOf(PowerProfile.current.gps);

  /// Sets the mode (null = follow the profile). Listeners hear only real changes.
  set mode(DriveGpsMode? m) {
    final before = mode;
    _mode = m;
    if (mode != before) _notify();
  }

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Tests only.
  void debugReset() {
    _mode = null;
    _listeners.clear();
  }
}
