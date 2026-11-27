import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/time_format.dart';
import 'package:meshsonar/ui/drive/drive_clock.dart';

/// Tests run as a metric (en_GB) phone unless they say otherwise, so Auto units never depend on the host's region.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppState.localeNameProvider = () => 'en_GB';
  // Every test starts with the app in front (the drive UI clocks and the wakelock follow the lifecycle, build 70).
  setUp(UiForeground.debugReset);
  // The shared map prefs are a process-wide singleton: no layer choice leaks from one test into the next.
  setUp(() => MapPrefs.shared.setLayerPrefs(kDriveLayerPage, LayerPrefs.empty));
  // Build 77: the app-wide Time zone setting and 12/24-hour choice never leak between tests.
  setUp(() {
    activeTimeZone = TimeZonePreference.phone;
    use24HourClock = false;
  });
  await testMain();
}
