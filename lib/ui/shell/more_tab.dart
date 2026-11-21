// The More tab: everything that is not a daily screen. It has its own Navigator, so Radio, Settings and the rest open
// inside the tab and the tab bar and mini drive bar stay in view.
//
// Build 71 (clutter pass): nine rows, no group headers: Drives, Radio, Devices and keys, Leaderboard, Add an observer,
// Chat settings, Settings, Help, About. Rows that only jumped into a Settings section are gone (Claimed radios,
// Observer, Wardriving settings, Notifications, Privacy and data sharing: all in Settings; their MoreItem values still
// open the section for code that asks). Radio (more_radio_screen.dart) holds what was Chat > Radio plus Radio settings,
// Radio setup, Noise floor and Telemetry. Help (more_help_screen.dart) holds How it works, Method, Colour legend,
// Report a problem, My reports and the Privacy policy.

import 'package:flutter/material.dart';


import '../about_screen.dart';
import '../app.dart';
import '../info/method_screens.dart';
import '../map/legend_sheet.dart' show showMapLegend;
import '../onboarding/onboarding_screen.dart';
import '../radio/radio_screen.dart';
import '../radios/observer_join_screen.dart';
import '../radios/radio_setup/radio_setup_screen.dart';
import '../sessions_screen.dart';
import '../settings_screen.dart';
import '../tools/adverts_screen.dart';
import '../tools/discover_screen.dart';
import '../account/devices_screen.dart';
import '../account/leaderboard_screen.dart';
import '../account/reports_history_screen.dart';
import '../tools/noise_screen.dart';
import '../tools/rx_log_screen.dart';
import '../tools/telemetry_screen.dart';
import '../tools/trace_screen.dart';
import '../chat/chat_settings_screen.dart';
import 'more_help_screen.dart';
import 'more_radio_screen.dart';

class MoreTab extends StatefulWidget {
  const MoreTab({super.key});
  @override
  State<MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<MoreTab> {
  final _nav = GlobalKey<NavigatorState>();
  int _seenReselect = 0;
  ShellController? _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = ShellScope.maybeOf(context);
    if (!identical(shell, _shell)) {
      _shell = shell;
      _seenReselect = shell?.reselectCount ?? 0;
    }
    if (shell == null) return;
    // Tapping the More tab again pops back to its list.
    if (shell.reselectCount != _seenReselect) {
      _seenReselect = shell.reselectCount;
      if (shell.tab == AppTab.more) _nav.currentState?.popUntil((r) => r.isFirst);
    }
    final pending = shell.tab == AppTab.more ? shell.takePendingMore() : null;
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(pending);
      });
    }
  }

  Widget _screenFor(MoreItem item) => switch (item) {
        MoreItem.drives => const SessionsScreen(),
        MoreItem.radio || MoreItem.repeaters => MoreRadioScreen(onOpen: (i) => _open(i, keep: true)),
        MoreItem.radioSettings => const RadioScreen(),
        MoreItem.help => MoreHelpScreen(onOpen: (i) => _open(i, keep: true)),
        MoreItem.myRadios => const SettingsScreen(initialSection: 'my-radios-section'),
        MoreItem.wardriving => const SettingsScreen(initialSection: 'wardriving'),
        MoreItem.notifications => const SettingsScreen(initialSection: 'notifications'),
        MoreItem.settings => const SettingsScreen(),
        MoreItem.about => const AboutScreen(),
        MoreItem.privacy => const SettingsScreen(initialSection: 'privacy'),
        MoreItem.trace => const TraceScreen(),
        MoreItem.discover => const DiscoverScreen(),
        MoreItem.adverts => const AdvertsScreen(),
        MoreItem.rxLog => const RxLogScreen(),
        MoreItem.noiseFloor => const NoiseScreen(),
        MoreItem.telemetry => const TelemetryScreen(),
        MoreItem.radioSetup => const RadioSetupScreen(),
        MoreItem.observerJoin => const ObserverJoinScreen(),
        MoreItem.method => const MethodScreen(),
        MoreItem.devices => const DevicesScreen(),
        MoreItem.myReports => const ReportsHistoryScreen(),
        MoreItem.leaderboard => const LeaderboardScreen(),
        MoreItem.chat => const ChatSettingsScreen(),
        MoreItem.observer => const SettingsScreen(initialSection: 'observer'),
        MoreItem.legend || MoreItem.howItWorks => const SizedBox.shrink(),
      };

  /// Opens [item] over the More list. [keep] leaves the page it was opened from (Radio, Help) underneath, so Back
  /// returns there.
  void _open(MoreItem item, {bool keep = false}) {
    final nav = _nav.currentState;
    if (nav == null) return;
    switch (item) {
      case MoreItem.legend:
        showMapLegend(nav.context);
      case MoreItem.howItWorks:
        nav.push(MaterialPageRoute<void>(
          builder: (ctx) => HowItWorksScreen(
            onReplayTour: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (c2) => OnboardingScreen(replay: true, onFinish: (_) => Navigator.of(c2).pop()),
            )),
          ),
        ));
      default:
        // The Drives list reads from disk: refresh it whenever it is opened (it lived in the Analyze tab until build 71).
        if (item == MoreItem.drives) AppScope.read(context).refreshSessions();
        if (!keep) nav.popUntil((r) => r.isFirst);
        nav.push(MaterialPageRoute<void>(builder: (_) => _screenFor(item)));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sheets and dialogs opened from inside this Navigator size themselves from MediaQuery.size: give them the size of
    // this tab's area (not the whole screen), or a "80% of the screen" sheet would run under the tab bar.
    return LayoutBuilder(
      builder: (context, box) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: Size(box.maxWidth, box.maxHeight)),
        child: Navigator(
          key: _nav,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => MoreList(onOpen: _open),
          ),
        ),
      ),
    );
  }
}

/// One row of the More tab and its pages: icon, title, one line, chevron. Key `more-<item name>`.
class MoreRow extends StatelessWidget {
  final MoreItem item;
  final IconData icon;
  final String title, subtitle;
  final void Function(MoreItem) onOpen;
  const MoreRow(this.item, this.icon, this.title, this.subtitle, {super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) => ListTile(
        key: Key('more-${item.name}'),
        minVerticalPadding: Gap.s,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onOpen(item),
      );
}

class MoreList extends StatelessWidget {
  final void Function(MoreItem) onOpen;
  const MoreList({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    Widget row(MoreItem item, IconData icon, String title, String subtitle) => MoreRow(item, icon, title, subtitle, onOpen: onOpen);
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('more-list'),
          children: [
            row(MoreItem.drives, Icons.list_alt, 'Drives', 'Your drives, reports and progress'),
            row(MoreItem.radio, Icons.settings_input_antenna, 'Radio',
                s.connected ? 'Your radio, repeaters, rooms, sensors and radio tools' : 'Not connected. Repeaters, rooms and radio tools'),
            row(MoreItem.devices, Icons.key_outlined, 'Devices and keys', 'Your driver key, other phones, MeshMapper forwarding'),
            row(MoreItem.leaderboard, Icons.emoji_events_outlined, 'Leaderboard', 'Drivers who opted in, this region or every region'),
            row(MoreItem.observerJoin, Icons.visibility_outlined, observerJoinTitle, 'Step by step: make your repeater report to MeshSonar. Free'),
            row(MoreItem.chat, Icons.chat_bubble_outline, 'Chat settings', 'Quick replies, Return key, haptics'),
            row(MoreItem.settings, Icons.settings, 'Settings', 'Wardriving, notifications, observer, privacy, claimed radios, maps, storage'),
            row(MoreItem.help, Icons.help_outline, 'Help', 'How it works, method, colour legend, report a problem'),
            ListTile(
              key: const Key('more-about'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.info_outline),
              title: const Text('About MeshSonar'),
              subtitle: Text('Version ${s.services.appInfo.version ?? ''}, licence, credits'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(MoreItem.about),
            ),
            const SizedBox(height: Gap.xl),
          ],
        ),
      ),
    );
  }
}
