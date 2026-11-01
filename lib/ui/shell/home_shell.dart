// The app shell: five tabs (Chat, Map, Analyze, Plan, More), a bottom bar on phones and a navigation rail from 700 dp
// wide (iPad, phones in landscape), and the mini drive bar above the tabs while a drive runs.
//
// Tab API: see shell_controller.dart (ShellScope). Seams for other work: ChatTabHost (chat_tab_host.dart) and
// MiniDriveBar (mini_drive_bar.dart). The last open tab is remembered (UiPrefs.lastTab, by name).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../always_location_screen.dart';
import '../antenna_sheet.dart';
import '../app.dart';
import '../drive_screen.dart';
import '../onboarding/ui_prefs.dart';
import '../telemetry_sheet.dart';
import 'analyze_tab.dart';
import '../chat/chat_banner_host.dart';
import 'chat_tab.dart';
import 'chat_tab_host.dart';
import 'mini_drive_bar.dart';
import 'more_tab.dart';
import 'plan_tab.dart';
import 'shell_controller.dart';

/// From this width the tabs sit in a rail on the left instead of a bar at the bottom.
const double shellRailWidth = 700;

class HomeShell extends StatefulWidget {
  /// Opens this tab; null restores the last open tab (Map on a fresh install).
  final AppTab? initialTab;

  /// Opens where a pre-0.25 tab index lives now (0 Drive, 1 Region, 2 Drives, 3 Radio, 4 Settings). For old callers.
  final int? legacyTab;
  const HomeShell({super.key, this.initialTab, this.legacyTab});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final ShellController _shell;
  AppState? _state;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _antennaSheetScheduled = false;
  bool _telemetrySheetScheduled = false;
  bool _presetDialogOpen = false;
  bool _restored = false;

  /// Keeps every tab's state (map, scroll, More's Navigator) when the layout flips between rail and bar on rotation.
  final _contentKey = GlobalKey();
  AppTab _lastTab = AppTab.map;
  AnalyzeView _lastAnalyze = AnalyzeView.region;

  @override
  void initState() {
    super.initState();
    _shell = ShellController(initial: widget.initialTab ?? AppTab.map)..visited.add(AppTab.map);
    _shell.visited.add(_shell.tab);
    _shell.addListener(_onShell);
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
    if (!_restored) {
      _restored = true;
      if (widget.legacyTab != null) {
        _shell.openLegacy(LegacyTab.fromIndex(widget.legacyTab!));
      } else if (widget.initialTab == null) {
        final saved = AppTab.byName(uiPrefsFor(s).lastTab);
        if (saved != null && saved != _shell.tab) _shell.select(saved);
      }
      _lastTab = _shell.tab;
      _lastAnalyze = _shell.analyzeView;
    }
  }

  void _onShell() {
    final s = _state;
    final tab = _shell.tab;
    if (s != null) {
      if (tab != _lastTab) unawaited(uiPrefsFor(s).setLastTab(tab.name));
      // The Drives list reads from disk: refresh it whenever it comes into view.
      final enteringDrives = tab == AppTab.analyze &&
          _shell.analyzeView == AnalyzeView.drives &&
          (_lastTab != AppTab.analyze || _lastAnalyze != AnalyzeView.drives);
      if (enteringDrives) s.refreshSessions();
    }
    _lastTab = tab;
    _lastAnalyze = _shell.analyzeView;
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
    // First run: tell the person what telemetry shares (it is on unless they opt out).
    if (!_telemetrySheetScheduled && !uiPrefsFor(s).telemetryDisclosed) {
      _telemetrySheetScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showTelemetryDisclosure(context);
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
    _shell.removeListener(_onShell);
    _shell.dispose();
    super.dispose();
  }

  Widget _page(AppTab t) => switch (t) {
        AppTab.chat => const ChatTab(),
        AppTab.map => const DriveScreen(),
        AppTab.analyze => const AnalyzeTab(),
        AppTab.plan => const PlanTab(),
        AppTab.more => const MoreTab(),
      };

  /// The Chat tab's icon, with the unread count when chat services report one.
  Widget _icon(AppTab t, {required bool selected}) {
    final icon = Icon(selected ? t.selectedIcon : t.icon);
    if (t != AppTab.chat) return icon;
    return ListenableBuilder(
      listenable: Listenable.merge([ChatTabHost.provider, ChatTabHost.provider.value?.changes]),
      builder: (_, _) {
        final n = ChatTabHost.unread;
        if (n <= 0) return icon;
        return Badge.count(key: const Key('chat-badge'), count: n, child: icon);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChatBannerHost(
      child: ShellScope(
      controller: _shell,
      child: ListenableBuilder(
        listenable: _shell,
        builder: (context, _) {
          final tab = _shell.tab;
          final wide = MediaQuery.sizeOf(context).width >= shellRailWidth;
          final pages = IndexedStack(
            index: tab.index,
            children: [
              for (final t in AppTab.values)
                _shell.visited.contains(t) || t == AppTab.map ? _page(t) : const SizedBox.shrink(),
            ],
          );
          // The Map tab already is the drive screen, so the bar is for every other tab.
          final bar = tab == AppTab.map ? const SizedBox.shrink() : MiniDriveBar(onOpen: _shell.openDrive);
          final content = Column(key: _contentKey, children: [Expanded(child: pages), bar]);
          return ScaffoldMessenger(
            key: _messengerKey,
            child: Scaffold(
              body: wide
                  ? Row(children: [
                      SafeArea(
                        right: false,
                        child: NavigationRail(
                          key: const Key('shell-rail'),
                          selectedIndex: tab.index,
                          labelType: NavigationRailLabelType.all,
                          onDestinationSelected: (i) => _shell.select(AppTab.values[i]),
                          destinations: [
                            for (final t in AppTab.values)
                              NavigationRailDestination(
                                icon: _icon(t, selected: false),
                                selectedIcon: _icon(t, selected: true),
                                label: Text(t.label),
                              ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: content),
                    ])
                  : content,
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      key: const Key('shell-tabs'),
                      selectedIndex: tab.index,
                      onDestinationSelected: (i) => _shell.select(AppTab.values[i]),
                      destinations: [
                        for (final t in AppTab.values)
                          NavigationDestination(
                            icon: _icon(t, selected: false),
                            selectedIcon: _icon(t, selected: true),
                            label: t.label,
                          ),
                      ],
                    ),
            ),
          );
        },
      ),
      ),
    );
  }
}
