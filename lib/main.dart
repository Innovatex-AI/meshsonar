// MeshSonar — open-source MeshCore wardriving. MIT licensed; see LICENSE and THIRD_PARTY_NOTICES.md.
import 'dart:async';

import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'alerts/alerts_runtime.dart';
import 'app/chat_wiring.dart';
import 'app/wiring.dart';
import 'platform/map_prefs_store.dart' show openSharedMapPrefs;
import 'ui/app.dart';
import 'ui/device_feedback.dart' show PlatformDeviceFeedback;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final services = await buildRealServices();
    // The map's remembered choices (layers, follow options) are read before the first frame so the Drive map never flashes defaults.
    await openSharedMapPrefs();
    final state = AppState(services);
    // Home observer keeps the screen awake while it is on (lib/app/app_state.dart _applyHomeMode).
    state.keepAwakeHook = (on) => unawaited(const PlatformDeviceFeedback().keepAwake(on));
    AlertsRuntime? alerts;
    try {
      // Notifications, the link's lifecycle log and reconnect-on-launch. Never prompts at launch. A failure here must not
      // stop the app: wardriving works without it.
      alerts = await AlertsRuntime.createReal();
      AlertsHost.runtime.value = alerts;
      alerts.bindApp(state);
    } catch (_) {}
    runApp(MeshSonarApp(state: state));
    await state.init();
    // Chat opens after the app is up; a failure here must never take the drive features down with it.
    unawaited(ChatWiring.attach(state).catchError((Object e) {
      state.diagnostics.add('chat failed to start: ${e.runtimeType}');
      return null;
    }));
    alerts?.startLaunchReconnect();
  } catch (e) {
    runApp(StartupErrorApp(message: e.toString()));
  }
}
