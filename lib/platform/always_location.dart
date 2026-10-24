// iOS "Always" location: lets MeshSonar keep recording a drive (and keep region tracking honest) with the screen
// locked or another app in front. iOS only shows the Always upgrade prompt once, so the app explains first
// (lib/ui/always_location_screen.dart) and only then asks. Other platforms: no-op.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

enum AlwaysLocationState {
  /// Already "Always".
  granted,

  /// "While Using" is granted; the Always upgrade has not been refused yet.
  canUpgrade,

  /// No location at all, or Always was refused: only Settings can change it.
  unavailable,

  /// Not iOS (Android handles background location through its foreground service).
  notApplicable,
}

bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

Future<AlwaysLocationState> alwaysLocationState() async {
  if (!_isIos) return AlwaysLocationState.notApplicable;
  try {
    final p = await Geolocator.checkPermission();
    switch (p) {
      case LocationPermission.always:
        return AlwaysLocationState.granted;
      case LocationPermission.whileInUse:
        return AlwaysLocationState.canUpgrade;
      default:
        return AlwaysLocationState.unavailable;
    }
  } catch (_) {
    return AlwaysLocationState.notApplicable;
  }
}

/// Triggers the system prompt (first "While Using" if nothing is granted yet, then the Always upgrade) and
/// returns whether Always ended up granted.
Future<bool> requestAlwaysLocation() async {
  if (!_isIos) return false;
  try {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.whileInUse) p = await Geolocator.requestPermission(); // iOS shows the Always upgrade
    return p == LocationPermission.always;
  } catch (_) {
    return false;
  }
}

Future<File?> _askedFile() async {
  try {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}${Platform.pathSeparator}always_location_asked');
  } catch (_) {
    return null;
  }
}

/// True once the explainer has been shown (whatever the person chose); we never nag.
Future<bool> alwaysExplainerShown() async {
  final f = await _askedFile();
  return f != null && await f.exists();
}

Future<void> markAlwaysExplainerShown() async {
  try {
    final f = await _askedFile();
    await f?.writeAsString('1');
  } catch (_) {}
}
