// Battery modes and the power knobs every component reads (build 70, meshsonar-infra
// docs/planning/battery-efficiency-plan-2026-11-16.md §3). Pure Dart: lib/radio and lib/core read [PowerProfile.current]; the
// UI listens through [PowerProfile.addListener]. One profile for the whole app, saved in `power_profile.json`.
import 'dart:convert';
import 'dart:io';

enum BatteryMode { maxData, balanced, saver, custom }

enum ScreenOnMode { always, driveTabOnly, never }

enum GpsPrecision { best, high, standard }

enum CompassMode { always, auto, off }

/// The resolved knobs. A preset mode fills every field; changing one field makes the mode [BatteryMode.custom].
class PowerSettings {
  final BatteryMode mode;
  final ScreenOnMode screenOn;

  /// Puck/camera loop cap in frames per second (120, 60 or 30).
  final int mapFps;
  final GpsPrecision gps;

  /// Minutes parked before the drive GPS drops to low accuracy (0 = never).
  final int pauseGpsParkedMin;

  /// Minutes parked before an open drive is ended and saved (0 = never).
  final int endDriveParkedMin;

  /// Minutes with no radio before an open drive is ended and saved (0 = never).
  final int endDriveNoRadioMin;
  final CompassMode compass;

  /// Backup BLE message check while the app is in front / in the background, seconds (0 = push only).
  final int radioPollFrontS;
  final int radioPollBackS;

  /// Observer (telemetry) upload interval while locked, seconds.
  final int observerUploadBackS;

  /// Drive upload during a drive (false = at drive end only).
  final bool uploadDuringDrive;

  /// Radio + phone stats sampling interval for the drive report, seconds.
  final int statsEveryS;

  /// Use Saver while iPhone Low Power Mode is on.
  final bool followLowPower;

  const PowerSettings({
    required this.mode,
    required this.screenOn,
    required this.mapFps,
    required this.gps,
    required this.pauseGpsParkedMin,
    required this.endDriveParkedMin,
    required this.endDriveNoRadioMin,
    required this.compass,
    required this.radioPollFrontS,
    required this.radioPollBackS,
    required this.observerUploadBackS,
    required this.uploadDuringDrive,
    required this.statsEveryS,
    this.followLowPower = true,
  });

  static const maxData = PowerSettings(
    mode: BatteryMode.maxData,
    screenOn: ScreenOnMode.always,
    mapFps: 120,
    gps: GpsPrecision.best,
    pauseGpsParkedMin: 0,
    endDriveParkedMin: 0,
    endDriveNoRadioMin: 0,
    compass: CompassMode.always,
    radioPollFrontS: 5,
    radioPollBackS: 5,
    observerUploadBackS: 60,
    uploadDuringDrive: true,
    statsEveryS: 60,
  );

  static const balanced = PowerSettings(
    mode: BatteryMode.balanced,
    screenOn: ScreenOnMode.driveTabOnly,
    mapFps: 60,
    gps: GpsPrecision.high,
    pauseGpsParkedMin: 3,
    endDriveParkedMin: 30,
    endDriveNoRadioMin: 15,
    compass: CompassMode.auto,
    radioPollFrontS: 30,
    radioPollBackS: 120,
    observerUploadBackS: 300,
    uploadDuringDrive: true,
    statsEveryS: 60,
  );

  static const saver = PowerSettings(
    mode: BatteryMode.saver,
    screenOn: ScreenOnMode.never,
    mapFps: 30,
    gps: GpsPrecision.standard,
    pauseGpsParkedMin: 1,
    endDriveParkedMin: 15,
    endDriveNoRadioMin: 5,
    compass: CompassMode.off,
    radioPollFrontS: 120,
    radioPollBackS: 0,
    observerUploadBackS: 900,
    uploadDuringDrive: false,
    statsEveryS: 300,
  );

  static PowerSettings preset(BatteryMode m, {bool followLowPower = true}) => switch (m) {
        BatteryMode.maxData => maxData,
        BatteryMode.saver => saver,
        _ => balanced,
      }.copyWith(followLowPower: followLowPower, mode: m == BatteryMode.custom ? BatteryMode.balanced : m);

  PowerSettings copyWith({
    BatteryMode? mode,
    ScreenOnMode? screenOn,
    int? mapFps,
    GpsPrecision? gps,
    int? pauseGpsParkedMin,
    int? endDriveParkedMin,
    int? endDriveNoRadioMin,
    CompassMode? compass,
    int? radioPollFrontS,
    int? radioPollBackS,
    int? observerUploadBackS,
    bool? uploadDuringDrive,
    int? statsEveryS,
    bool? followLowPower,
  }) =>
      PowerSettings(
        mode: mode ?? this.mode,
        screenOn: screenOn ?? this.screenOn,
        mapFps: mapFps ?? this.mapFps,
        gps: gps ?? this.gps,
        pauseGpsParkedMin: pauseGpsParkedMin ?? this.pauseGpsParkedMin,
        endDriveParkedMin: endDriveParkedMin ?? this.endDriveParkedMin,
        endDriveNoRadioMin: endDriveNoRadioMin ?? this.endDriveNoRadioMin,
        compass: compass ?? this.compass,
        radioPollFrontS: radioPollFrontS ?? this.radioPollFrontS,
        radioPollBackS: radioPollBackS ?? this.radioPollBackS,
        observerUploadBackS: observerUploadBackS ?? this.observerUploadBackS,
        uploadDuringDrive: uploadDuringDrive ?? this.uploadDuringDrive,
        statsEveryS: statsEveryS ?? this.statsEveryS,
        followLowPower: followLowPower ?? this.followLowPower,
      );

  /// Changes one knob: the mode becomes Custom.
  PowerSettings tweak(PowerSettings Function(PowerSettings s) f) => f(this).copyWith(mode: BatteryMode.custom);

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'screenOn': screenOn.name,
        'mapFps': mapFps,
        'gps': gps.name,
        'pauseGpsParkedMin': pauseGpsParkedMin,
        'endDriveParkedMin': endDriveParkedMin,
        'endDriveNoRadioMin': endDriveNoRadioMin,
        'compass': compass.name,
        'radioPollFrontS': radioPollFrontS,
        'radioPollBackS': radioPollBackS,
        'observerUploadBackS': observerUploadBackS,
        'uploadDuringDrive': uploadDuringDrive,
        'statsEveryS': statsEveryS,
        'followLowPower': followLowPower,
      };

  static T _enum<T extends Enum>(List<T> values, Object? v, T d) {
    for (final e in values) {
      if (e.name == v) return e;
    }
    return d;
  }

  static int _int(Object? v, int d) => v is int ? v : d;

  /// Unknown or missing fields fall back to Balanced; a preset mode always resolves to its preset values. A saved
  /// `simpleBasemap` (builds 70 to 75: no basemap while driving, removed in build 76) is ignored.
  static PowerSettings fromJson(Map<String, dynamic> j) {
    final mode = _enum(BatteryMode.values, j['mode'], BatteryMode.balanced);
    final follow = j['followLowPower'] is bool ? j['followLowPower'] as bool : true;
    if (mode != BatteryMode.custom) return preset(mode, followLowPower: follow);
    const b = balanced;
    return PowerSettings(
      mode: BatteryMode.custom,
      screenOn: _enum(ScreenOnMode.values, j['screenOn'], b.screenOn),
      mapFps: _int(j['mapFps'], b.mapFps),
      gps: _enum(GpsPrecision.values, j['gps'], b.gps),
      pauseGpsParkedMin: _int(j['pauseGpsParkedMin'], b.pauseGpsParkedMin),
      endDriveParkedMin: _int(j['endDriveParkedMin'], b.endDriveParkedMin),
      endDriveNoRadioMin: _int(j['endDriveNoRadioMin'], b.endDriveNoRadioMin),
      compass: _enum(CompassMode.values, j['compass'], b.compass),
      radioPollFrontS: _int(j['radioPollFrontS'], b.radioPollFrontS),
      radioPollBackS: _int(j['radioPollBackS'], b.radioPollBackS),
      observerUploadBackS: _int(j['observerUploadBackS'], b.observerUploadBackS),
      uploadDuringDrive: j['uploadDuringDrive'] is bool ? j['uploadDuringDrive'] as bool : b.uploadDuringDrive,
      statsEveryS: _int(j['statsEveryS'], b.statsEveryS),
      followLowPower: follow,
    );
  }
}

/// The app-wide profile. [chosen] is what the user picked; [current] is what components obey (Saver while iPhone Low Power
/// Mode is on and [PowerSettings.followLowPower] is set).
abstract final class PowerProfile {
  static PowerSettings _chosen = PowerSettings.balanced;
  static bool _lowPower = false;
  static File? _file;
  static final List<void Function()> _listeners = [];

  static PowerSettings get chosen => _chosen;
  static bool get lowPowerMode => _lowPower;

  /// What every component reads.
  static PowerSettings get current =>
      _lowPower && _chosen.followLowPower ? PowerSettings.saver.copyWith(followLowPower: true) : _chosen;

  /// True while Low Power Mode is overriding the chosen mode.
  static bool get lowPowerOverride => _lowPower && _chosen.followLowPower;

  static void addListener(void Function() l) => _listeners.add(l);
  static void removeListener(void Function() l) => _listeners.remove(l);
  static void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Reads the saved profile. A missing or damaged file leaves Balanced.
  static Future<void> load(File? file) async {
    _file = file;
    if (file == null) return;
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is Map<String, dynamic>) _chosen = PowerSettings.fromJson(j);
    } catch (_) {}
    _notify();
  }

  /// Sets and saves the profile (best effort).
  static Future<void> set(PowerSettings s) async {
    _chosen = s;
    _notify();
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(s.toJson()), flush: true);
    } catch (_) {}
  }

  /// Fed by the native Low Power Mode channel.
  static void setLowPowerMode(bool on) {
    if (on == _lowPower) return;
    _lowPower = on;
    _notify();
  }

  /// Tests only.
  static void debugReset([PowerSettings s = PowerSettings.balanced]) {
    _chosen = s;
    _lowPower = false;
    _file = null;
    _listeners.clear();
  }
}

/// Phase 0 power counters (Diagnostics and the drive report). Counted in code so tests can assert them.
abstract final class PowerCounters {
  static final Map<String, int> _c = {};
  static final DateTime _since = DateTime.now();

  static void inc(String key, [int by = 1]) => _c[key] = (_c[key] ?? 0) + by;
  static int get(String key) => _c[key] ?? 0;
  static Map<String, int> snapshot() => Map.unmodifiable(_c);
  static DateTime get since => _since;
  static void debugReset() => _c.clear();

  // Keys.
  static const bleCommand = 'ble_commands';
  static const blePoll = 'ble_safety_polls';
  static const httpRequest = 'http_requests';
  static const timerWake = 'timer_wakes';
  static const mapFrame = 'map_frames';
  static const compassSeconds = 'compass_s';
  static const screenOnSeconds = 'screen_on_s';
  static const gpsBestSeconds = 'gps_best_s';
  static const gpsHighSeconds = 'gps_high_s';
  static const gpsLowSeconds = 'gps_low_s';
}
