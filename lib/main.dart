// MeshSonar — open-source MeshCore wardriving. MIT licensed; see LICENSE and THIRD_PARTY_NOTICES.md.
import 'dart:async';

import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'alerts/alerts_runtime.dart';
import 'app/chat_wiring.dart';
import 'app/wiring.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final services = await buildRealServices();
    final state = AppState(services);
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
