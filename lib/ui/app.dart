// Root widget, theme, AppScope (how screens reach AppState) and the bottom-tab shell.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'drive_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';

/// Gives every screen the AppState and rebuilds dependents when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Read without subscribing (for callbacks).
  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}

ThemeData meshSonarTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF00897B), brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.standard,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(64, 56), textStyle: const TextStyle(fontSize: 18)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 52), textStyle: const TextStyle(fontSize: 16)),
    ),
    listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class MeshSonarApp extends StatelessWidget {
  final AppState state;
  const MeshSonarApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'MeshSonar',
        debugShowCheckedModeBanner: false,
        theme: meshSonarTheme(Brightness.light),
        darkTheme: meshSonarTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  AppState? _state;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.read(context);
    if (!identical(s, _state)) {
      _state?.removeListener(_onState);
      _state = s;
      s.addListener(_onState);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onState());
    }
  }

  void _onState() {
    final s = _state;
    if (s == null || s.pendingNotice == null || !mounted) return;
    final msg = s.takeNotice();
    if (msg == null) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg, style: const TextStyle(fontSize: 16)), duration: const Duration(seconds: 6)));
  }

  @override
  void dispose() {
    _state?.removeListener(_onState);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pages = [DriveScreen(), SessionsScreen(), SettingsScreen()];
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            setState(() => _tab = i);
            if (i == 1) AppScope.read(context).refreshSessions();
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.radar), label: 'Drive'),
            NavigationDestination(icon: Icon(Icons.list_alt), label: 'Drives'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
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
