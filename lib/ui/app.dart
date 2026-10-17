// Root widget, theme wiring (see theme.dart), AppScope (how screens reach AppState) and the bottom-tab shell.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'antenna_sheet.dart';
import 'drive_screen.dart';
import 'onboarding/first_run_gate.dart';
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

/// Lets any screen, including ones opened over the tabs, send the person to a place in the tab shell.
class ShellNavigation {
  VoidCallback? _showDriverKey;

  /// Closes the screens open over the tabs and shows Settings at the driver key.
  void showDriverKey() => _showDriverKey?.call();
}

/// Gives every screen (and every pushed route) the app's [ShellNavigation].
class ShellScope extends InheritedWidget {
  final ShellNavigation navigation;
  const ShellScope({super.key, required this.navigation, required super.child});

  static ShellNavigation of(BuildContext context) => context.getInheritedWidgetOfExactType<ShellScope>()!.navigation;

  @override
  bool updateShouldNotify(ShellScope oldWidget) => !identical(navigation, oldWidget.navigation);
}

class MeshSonarApp extends StatefulWidget {
  final AppState state;
  const MeshSonarApp({super.key, required this.state});
  @override
  State<MeshSonarApp> createState() => _MeshSonarAppState();
}

class _MeshSonarAppState extends State<MeshSonarApp> {
  final _navigation = ShellNavigation();

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ShellScope(
        navigation: _navigation,
        child: MaterialApp(
          // A different AppState is a different app (e.g. after a restart): it starts on a fresh screen stack.
          key: ObjectKey(widget.state),
          title: 'MeshSonar',
          debugShowCheckedModeBanner: false,
          theme: meshSonarTheme(Brightness.light),
          darkTheme: meshSonarTheme(Brightness.dark),
          themeMode: meshSonarThemeMode(),
          home: FirstRunGate(builder: (tab) => HomeShell(key: ValueKey('shell-$tab'), initialTab: tab)),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  /// 0 Drive, 1 Drives, 2 Settings.
  final int initialTab;
  const HomeShell({super.key, this.initialTab = 0});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _tab = widget.initialTab;
  AppState? _state;
  ShellNavigation? _navigation;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _settingsScroll = ScrollController();
  bool _antennaSheetScheduled = false;

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
    final nav = ShellScope.of(context);
    if (!identical(nav, _navigation)) {
      _navigation?._showDriverKey = null;
      _navigation = nav.._showDriverKey = _showDriverKey;
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
    if (s.pendingNotice == null) return;
    final msg = s.takeNotice();
    if (msg == null) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg, style: const TextStyle(fontSize: 16)), duration: const Duration(seconds: 6)));
  }

  void _showDriverKey() {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => _tab = 2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The driver key section is the first thing in Settings.
      if (_settingsScroll.hasClients) {
        _settingsScroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _state?.removeListener(_onState);
    // A newer shell may have taken over the link already (FirstRunGate swaps shells).
    if (_navigation?._showDriverKey == _showDriverKey) _navigation?._showDriverKey = null;
    _settingsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const DriveScreen(), const SessionsScreen(), SettingsScreen(scrollController: _settingsScroll)];
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
