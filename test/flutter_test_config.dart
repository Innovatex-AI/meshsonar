import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/map_prefs.dart';

/// Tests run as a metric (en_GB) phone unless they say otherwise, so Auto units never depend on the host's region.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppState.localeNameProvider = () => 'en_GB';
  // The shared map prefs are a process-wide singleton: no layer choice leaks from one test into the next.
  setUp(() => MapPrefs.shared.setLayerPrefs(kDriveLayerPage, LayerPrefs.empty));
  // Production default is ON (AppFlags.chatRedesignDefault); the older tests exercise the old Chat UI, redesign tests opt in.
  AppFlags.chatRedesign = false;
  await testMain();
}
