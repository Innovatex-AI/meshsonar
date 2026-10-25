// Phone sensor contracts for the drive context (stream 7 WP3). The real implementations live in lib/platform
// (sensors_plus barometer, battery_plus, device_info_plus); tests use fakes. Pure Dart: no Flutter imports.
//
// What a phone can and cannot measure (stream-7-data-collection.md section 3.1), never invented:
// - Barometer: most phones; not some iPads and some Android phones. iOS asks for Motion & Fitness the first time.
// - Air temperature: NO iPhone has an ambient temperature sensor, and battery temperature is not air temperature.
//   No phone temperature is collected on any phone (Andy, Oct 24 2026; see [phoneTemperatureNote]).
// - Battery level, charging state, Low Power Mode: every phone, no permission.
// - Device model identifier (e.g. iPhone15,2), OS version: every phone. Never the user's device name.
import 'dart:async';

import 'drive_context.dart';

/// The phone barometer. [readings] is a stream of pressure in hPa; it fails (an error event) when the phone has no
/// barometer or the OS refused access (iOS Motion & Fitness off). Listening is what starts the sensor, so nothing is
/// read (and on iOS no permission is asked) until a drive with the Air pressure category on subscribes.
abstract class BarometerSource {
  Stream<double> readings();
}

/// One battery reading. Every field null = not reported by this phone.
class PhoneBatteryReading {
  final int? levelPct;
  final PhoneBatteryState state;
  final bool? lowPower;
  const PhoneBatteryReading({this.levelPct, this.state = PhoneBatteryState.unknown, this.lowPower});
}

abstract class PhoneBatterySource {
  /// The battery right now, or null when the phone does not report it (desktop without a battery, plugin error).
  Future<PhoneBatteryReading?> read();

  /// Charging state changes (plugged in, unplugged, full). May be an empty stream.
  Stream<PhoneBatteryState> get stateChanges;
}

/// Phone and app details for the `device` category: OS name + version, hardware model identifier, app build.
abstract class DeviceDetailsSource {
  Future<DeviceDetails?> read();
}

/// Where the barometer stands for this drive (shown in Settings and the drive report).
enum SensorStatus {
  /// Not asked yet (no drive since launch with the category on).
  notStarted,

  /// Readings are arriving.
  reading,

  /// Asked and nothing came: no barometer on this phone, or access refused in the OS settings.
  unavailable,

  /// The app build has no barometer support on this platform (desktop, tests).
  unsupported,
}

/// Said wherever the collected categories are listed: what is NOT measured and why.
const String phoneTemperatureNote =
    'Phone temperature: not collected. iPhones have no air-temperature sensor, and battery temperature is not air '
    'temperature. Your radio\'s chip temperature is part of Radio health; outside weather will come from the server '
    '(not available yet).';

/// The median of [values], or null when empty.
double? medianOf(Iterable<double> values) {
  final v = values.toList()..sort();
  if (v.isEmpty) return null;
  final m = v.length ~/ 2;
  return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
}
