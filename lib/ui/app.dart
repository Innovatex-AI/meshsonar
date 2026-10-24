// Root widget, theme wiring (see theme.dart), AppScope (how screens reach AppState) and the bottom-tab shell.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'antenna_sheet.dart';
import 'drive_screen.dart';
import 'onboarding/first_run_gate.dart';
import 'always_location_screen.dart';
import 'region/region_hub_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

export 'theme.dart' show meshSonarTheme, meshSonarThemeMode, MeshSonarColors, Gap, Corners, numberStyle;

/// Gives every screen the AppState and rebuilds dependents when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

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
      child: MaterialApp(
        // Screens pushed for one AppState (a report form, its review) belong to it. Without this key, giving the app
        // a new AppState (a restart in the same engine, as widget tests do) would keep the old screen stack and Navigator
        // over the new state.
        key: ObjectKey(state),
        title: 'MeshSonar',
        debugShowCheckedModeBanner: false,
        theme: meshSonarTheme(Brightness.light),
        darkTheme: meshSonarTheme(Brightness.dark),
        themeMode: meshSonarThemeMode(),
        home: FirstRunGate(builder: (tab) => HomeShell(key: ValueKey('shell-$tab'), initialTab: tab)),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  /// 0 Drive, 1 Region, 2 Drives, 3 Settings.
  final int initialTab;
  const HomeShell({super.key, this.initialTab = 0});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _tab = widget.initialTab;
  AppState? _state;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _antennaSheetScheduled = false;
  bool _presetDialogOpen = false;

  @override
  void initState() {
    super.initState();
    // iOS only (no-op elsewhere): explain, then ask for "Always" location once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeAskAlwaysLocation(context);
    });
  }

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
    if (s == null || !mounted) return;
    // A radio connected for the first time: ask about its antenna once the connect screen has closed.
    if (s.antennaPromptPending && !_antennaSheetScheduled) {
      _antennaSheetScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _antennaSheetScheduled = false;
        if (mounted && s.takeAntennaPrompt()) showAntennaSheet(context);
      });
    }
    // A border crossing into a region with a different radio preset: ask (never while driving; never touches the radio).
    final prompt = s.presetPrompt;
    if (prompt != null && !s.driving && !_presetDialogOpen) {
      _presetDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showPresetPrompt(context, prompt, onAnswer: (v) => s.resolvePresetPrompt(switchView: v));
        _presetDialogOpen = false;
      });
    }
    if (s.pendingNotice == null) return;
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
    const pages = [DriveScreen(), RegionHubScreen(), SessionsScreen(), SettingsScreen()];
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            setState(() => _tab = i);
            if (i == 2) AppScope.read(context).refreshSessions();
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.radar), label: 'Drive'),
            NavigationDestination(icon: Icon(Icons.public), label: 'Region'),
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
