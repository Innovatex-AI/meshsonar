// Location permission for the launch/Region notes (lib/core/startup_location.dart), via geolocator. [check] never
// prompts; [request] shows the system question and is only called after the person taps "Allow location" (the same
// question Start drive asks through LocationSource.ensurePermission).
//
// geolocator reports iOS "not determined" and "restricted" both as `denied`, and iOS "denied" as `deniedForever`. A flag
// file records that MeshSonar asked through this probe: still `denied` on iOS after that means "restricted" (policy or
// Screen Time); on Android it means refused once, and the app may ask again.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import '../core/startup_location.dart';

class GeolocatorLocationAccess implements LocationAccessProbe {
  bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<File?> _askedFile() async {
    try {
      final d = await getApplicationSupportDirectory();
      return File('${d.path}${Platform.pathSeparator}location_asked');
    } catch (_) {
      return null;
    }
  }

  Future<bool> _asked() async {
    final f = await _askedFile();
    return f != null && await f.exists();
  }

  @override
  Future<LocationAccess> check() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.servicesOff;
      switch (await Geolocator.checkPermission()) {
        case LocationPermission.deniedForever:
          return LocationAccess.deniedForever;
        case LocationPermission.denied:
          final asked = await _asked();
          if (!asked) return LocationAccess.notAsked;
          return _ios ? LocationAccess.restricted : LocationAccess.denied;
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          try {
            if (await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced) return LocationAccess.approximate;
          } catch (_) {}
          return LocationAccess.granted;
        case LocationPermission.unableToDetermine:
          return LocationAccess.unknown;
      }
    } catch (_) {
      return LocationAccess.unknown;
    }
  }

  @override
  Future<LocationAccess> request() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.servicesOff;
      final f = await _askedFile();
      try {
        await f?.writeAsString('1');
      } catch (_) {}
      if (await Geolocator.checkPermission() == LocationPermission.denied) await Geolocator.requestPermission();
    } catch (_) {}
    return check();
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }
}
