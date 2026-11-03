import 'dart:async';

import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';

/// Tests run as a metric (en_GB) phone unless they say otherwise, so Auto units never depend on the host's region.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppState.localeNameProvider = () => 'en_GB';
  // Production default is ON (AppFlags.chatRedesignDefault); the older tests exercise the old Chat UI, redesign tests opt in.
  AppFlags.chatRedesign = false;
  await testMain();
}
