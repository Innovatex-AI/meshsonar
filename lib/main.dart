// MeshSonar — open-source MeshCore wardriving. MIT licensed; see LICENSE and THIRD_PARTY_NOTICES.md.
import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/wiring.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final services = await buildRealServices();
    final state = AppState(services);
    runApp(MeshSonarApp(state: state));
    await state.init();
  } catch (e) {
    runApp(StartupErrorApp(message: e.toString()));
  }
}
