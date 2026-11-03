// Face ID / Touch ID / passcode check that guards saved repeater passwords (chat plan WP9). Wraps local_auth so the pure-Dart
// vault only sees a `Future<bool> Function()`. Any failure (no hardware, user cancel, plugin error) is "not proven".
import 'package:local_auth/local_auth.dart';

/// Whether this device can authenticate at all (biometrics or passcode set).
Future<bool> biometricsAvailable() async {
  try {
    return await LocalAuthentication().isDeviceSupported();
  } catch (_) {
    return false;
  }
}

/// Asks for Face ID (falls back to the device passcode). True only when the person passed.
Future<bool> authenticateWithDevice() async {
  try {
    return await LocalAuthentication().authenticate(localizedReason: 'Unlock your saved repeater passwords');
  } catch (_) {
    return false;
  }
}
