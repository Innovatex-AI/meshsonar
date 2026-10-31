// Root widget, theme wiring (see theme.dart) and AppScope (how screens reach AppState). The tab shell is in shell/.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/units.dart';
import 'onboarding/first_run_gate.dart';
import 'shell/home_shell.dart';
import 'theme.dart';

export 'shell/home_shell.dart' show HomeShell;
export 'shell/shell_controller.dart' show AppTab, AnalyzeView, MoreItem, ShellController, ShellScope;
export 'theme.dart' show meshSonarTheme, meshSonarThemeMode, MeshSonarColors, Gap, Corners, numberStyle;

/// Gives every screen the AppState and rebuilds dependents when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// The state when there is an AppScope above (rebuilds on change), else null (isolated widget tests).
  static AppState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;

  /// The Units for the current Settings (rebuilds on change); metric when there is no AppScope (isolated widget tests).
  static Units unitsOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier?.units ?? Units.metric;

  /// Read without subscribing (for callbacks).
  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}

class MeshSonarApp extends StatelessWidget {
  final AppState state;
  const MeshSonarApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      // Builder so the theme follows Settings > Colour palette (the strength colours live in the theme extension).
      child: Builder(builder: (context) {
        final palette = AppScope.of(context).settings.colourPalette;
        return MaterialApp(
          // Screens pushed for one AppState (a report form, its review) belong to it. Without this key, giving the app
          // a new AppState (a restart in the same engine, as widget tests do) would keep the old screen stack and Navigator
          // over the new state.
          key: ObjectKey(state),
          title: 'MeshSonar',
          debugShowCheckedModeBanner: false,
          theme: meshSonarTheme(Brightness.light, palette: palette),
          darkTheme: meshSonarTheme(Brightness.dark, palette: palette),
          themeMode: meshSonarThemeMode(),
          home: FirstRunGate(builder: () => const HomeShell()),
        );
      }),
    );
  }
}

/// Shown if the app can't even open its storage.
class StartupErrorApp extends StatelessWidget {
  final String message;
  const StartupErrorApp({super.key, required this.message});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshSonar',
      theme: meshSonarTheme(Brightness.light),
      darkTheme: meshSonarTheme(Brightness.dark),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 56),
                const SizedBox(height: 16),
                const Text('MeshSonar couldn\'t start', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(
                  'It couldn\'t open its storage on this device. Make sure there is free space, then restart the app.\n\n'
                  '${message.split('\n').first}',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
