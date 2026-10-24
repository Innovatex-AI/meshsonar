import 'dart:async';

import 'package:meshsonar/app/app_state.dart';

/// Tests run as a metric (en_GB) phone unless they say otherwise, so Auto units never depend on the host's region.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppState.localeNameProvider = () => 'en_GB';
  await testMain();
}
