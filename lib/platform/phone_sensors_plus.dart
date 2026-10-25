// Real phone sensors for the drive context (stream 7 WP3), behind the pure-Dart seams in lib/core/phone_sensors.dart.
//
// Plugins (all BSD-3-Clause, Flutter Community plus_plugins, checked in the pub cache LICENSE files):
// - sensors_plus: barometer. The smallest maintained plugin with an iOS barometer (CMAltimeter, reported in kPa and
//   converted to hPa by the plugin) and Android TYPE_PRESSURE. iOS shows the Motion & Fitness prompt the first time
//   the stream is listened to (Info.plist NSMotionUsageDescription), which only happens at a drive start with Air
//   pressure on and the disclosure seen. No barometer / access refused = the stream fails ("UNAVAILABLE").
// - battery_plus: level, charging state, Low Power Mode / battery saver. No permission.
// - device_info_plus: the hardware model identifier (iOS utsname.machine e.g. "iPhone15,2", Android Build.MODEL) and
//   OS version. Never the user's device name, identifierForVendor, Android id or serial.
import 'dart:io';

import 'package:battery_plus/battery_plus.dart' as bp;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/drive_context.dart';
import '../core/phone_sensors.dart';

class SensorsPlusBarometer implements BarometerSource {
  @override
  Stream<double> readings() =>
      barometerEventStream(samplingPeriod: const Duration(seconds: 1)).map((e) => e.pressure);
}

PhoneBatteryState phoneBatteryStateOf(bp.BatteryState s) => switch (s) {
      bp.BatteryState.charging => PhoneBatteryState.charging,
      bp.BatteryState.full => PhoneBatteryState.full,
      bp.BatteryState.discharging => PhoneBatteryState.unplugged,
      // Plugged in but not charging (charge limit reached, weak charger): not one of the stored states, so unknown.
      _ => PhoneBatteryState.unknown,
    };

class BatteryPlusSource implements PhoneBatterySource {
  final bp.Battery _battery;
  BatteryPlusSource([bp.Battery? battery]) : _battery = battery ?? bp.Battery();

  @override
  Future<PhoneBatteryReading?> read() async {
    int? level;
    var state = PhoneBatteryState.unknown;
    bool? low;
    try {
      level = await _battery.batteryLevel; // -1 on a simulator: out of range, stored as unknown
    } catch (_) {}
    try {
      state = phoneBatteryStateOf(await _battery.batteryState);
    } catch (_) {}
    try {
      low = await _battery.isInBatterySaveMode;
    } catch (_) {}
    if (level == null && state == PhoneBatteryState.unknown && low == null) return null;
    return PhoneBatteryReading(levelPct: level, state: state, lowPower: low);
  }

  @override
  Stream<PhoneBatteryState> get stateChanges => _battery.onBatteryStateChanged.map(phoneBatteryStateOf);
}

class DeviceInfoPlusDetails implements DeviceDetailsSource {
  /// App build number (pubspec `+N`), from AppInfo.
  final String? appBuild;
  final DeviceInfoPlugin _plugin;
  DeviceDetails? _cached;
  DeviceInfoPlusDetails({this.appBuild, DeviceInfoPlugin? plugin}) : _plugin = plugin ?? DeviceInfoPlugin();

  @override
  Future<DeviceDetails?> read() async {
    if (_cached != null) return _cached;
    String? model, osVersion;
    try {
      if (Platform.isIOS) {
        final i = await _plugin.iosInfo;
        model = i.utsname.machine; // hardware identifier, never i.name (the user's device name)
        osVersion = i.systemVersion;
      } else if (Platform.isAndroid) {
        final a = await _plugin.androidInfo;
        model = a.model;
        osVersion = a.version.release;
      } else {
        osVersion = Platform.operatingSystemVersion;
      }
    } catch (_) {
      osVersion ??= Platform.operatingSystemVersion;
    }
    final d = DeviceDetails(os: Platform.operatingSystem, osVersion: osVersion, model: model, appBuild: appBuild);
    return _cached = d.isEmpty ? null : d;
  }
}
