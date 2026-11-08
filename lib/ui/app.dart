// Root widget, theme wiring (see theme.dart) and AppScope (how screens reach AppState). The tab shell is in shell/.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/units.dart';
import '../platform/accessibility_channel.dart';
import 'design/app_haptics.dart';
import 'design/drive_guard.dart';
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

/// `MaterialApp.builder` for every MaterialApp in the app: one app-wide text style under the Navigator.
///
/// MaterialApp's own default text style (above the Navigator) is Flutter's debug fallback: red monospace with a yellow
/// double underline, meant to flag Text outside a Material. Release builds draw it too. A Scaffold or Material supplies the
/// real style, but plenty of text is drawn with neither above it: CupertinoPageScaffold pages, the long-press context menu
/// (a PopupRoute: the lifted bubble and its info card), the nav-bar hero that flies the title and back label between pages
/// during a push or pop, overlay toasts, Cupertino popups. This DefaultTextStyle sits under MaterialApp's and above the
/// Navigator and its Overlay, so all of those get the same style a Material would give (`textTheme.bodyMedium`) instead.
/// Pinned by test/ui/no_debug_underline_test.dart.
Widget meshSonarAppBuilder(BuildContext context, Widget? child) {
  return DefaultTextStyle(
    style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
    child: child ?? const SizedBox.shrink(),
  );
}

class MeshSonarApp extends StatefulWidget {
  final AppState state;
  const MeshSonarApp({super.key, required this.state});

  @override
  State<MeshSonarApp> createState() => _MeshSonarAppState();
}

class _MeshSonarAppState extends State<MeshSonarApp> {
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    AccessibilitySignals.refresh(); // Reduce Transparency, for the blurred bars (S10)
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      // Builder so the theme follows Settings > Colour palette (the strength colours live in the theme extension).
      child: Builder(builder: (context) {
        final scope = AppScope.of(context);
        final palette = scope.settings.colourPalette;
        // Foundation wiring (WP0): the Haptics setting, and the drive guard that holds self-raised prompts while driving.
        AppHaptics.enabled = scope.settings.haptics;
        final driving = scope.driving;
        WidgetsBinding.instance.addPostFrameCallback((_) => DriveGuard.instance.setDriving(driving));
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
          builder: meshSonarAppBuilder,
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
      builder: meshSonarAppBuilder,
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
