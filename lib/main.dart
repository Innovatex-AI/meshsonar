// MeshSonar — open-source MeshCore wardriving. MIT licensed; see LICENSE and THIRD_PARTY_NOTICES.md.
import 'dart:async';

import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/benign_errors.dart' show installBenignErrorFilter;
import 'alerts/alerts_runtime.dart';
import 'app/chat_wiring.dart';
import 'app/map_definition_wiring.dart';
import 'app/removed_map_packs.dart';
import 'app/wiring.dart';
import 'platform/map_prefs_store.dart' show openSharedMapPrefs;
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A map disposed while its tiles load cancels them (vector_map_tiles): harmless, never a crash. Everything else is reported.
  installBenignErrorFilter();
  try {
    final services = await buildRealServices();
    // The map's remembered choices (layers, follow options) are read before the first frame so the Drive map never flashes defaults.
    await openSharedMapPrefs();
    final state = AppState(services);
    AlertsRuntime? alerts;
    try {
      // Notifications, the link's lifecycle log and reconnect-on-launch. Never prompts at launch. A failure here must not
      // stop the app: wardriving works without it.
      alerts = await AlertsRuntime.createReal();
      AlertsHost.runtime.value = alerts;
      alerts.bindApp(state);
      // The app is an observer whenever a radio is connected (observer everywhere, Nov 15 2026): a radio that dropped by
      // itself outside a drive comes back through the saved-radio auto-connect, which honours Settings > Radio >
      // Auto-connect (Always, the default) and a radio the person released on purpose.
      final reconnect = alerts.reconnect;
      if (reconnect != null) state.onRadioDropped = () => unawaited(reconnect.run(reason: 'foreground'));
    } catch (_) {}
    runApp(MeshSonarApp(state: state));
    await state.init();
    // Chat opens after the app is up; a failure here must never take the drive features down with it.
    unawaited(ChatWiring.attach(state).catchError((Object e) {
      state.diagnostics.add('chat failed to start: ${e.runtimeType}');
      return null;
    }));
    alerts?.startLaunchReconnect();
    // Build 76: downloadable map packs are gone; what an older build left on the phone is deleted (removed_map_packs.dart).
    unawaited(removeOldMapPackFilesAtLaunch());
    unawaited(startMapDefinition(state.client.baseUrl));
  } catch (e) {
    runApp(StartupErrorApp(message: e.toString()));
  }
}
