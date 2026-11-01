// The More tab: everything that is not a daily screen. It has its own Navigator, so Radio, Settings and the rest open
// inside the tab and the tab bar and mini drive bar stay in view.
import 'package:flutter/material.dart';

import '../../core/server_url.dart' show privacyPolicyUrl;
import '../about_screen.dart';
import '../app.dart';
import '../info/method_screens.dart';
import '../map/legend_sheet.dart' show showMapLegend;
import '../onboarding/onboarding_screen.dart';
import '../radio/radio_screen.dart';
import '../radios/observer_join_screen.dart';
import '../radios/repeaters_screen.dart';
import '../report_problem_screen.dart' show openReportProblem;
import '../radios/radio_setup/radio_setup_screen.dart';
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
        MoreItem.radio => const RadioScreen(),
        MoreItem.repeaters => const RepeatersScreen(),
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
        MoreItem.legend || MoreItem.howItWorks => const SizedBox.shrink(),
      };

  void _open(MoreItem item) {
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
        nav.popUntil((r) => r.isFirst);
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

class MoreList extends StatelessWidget {
  final void Function(MoreItem) onOpen;
  const MoreList({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    Widget row(MoreItem item, IconData icon, String title, String subtitle, {String? keyName, bool external = false}) =>
        ListTile(
          key: Key('more-${keyName ?? item.name}'),
          minVerticalPadding: Gap.s,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: Icon(external ? Icons.open_in_new : Icons.chevron_right, size: external ? 18 : 24),
          onTap: () => onOpen(item),
        );
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
          child: Semantics(
            header: true,
            child: Text(text, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('more-list'),
          children: [
            header('Your radio'),
            row(MoreItem.radio, Icons.settings_input_antenna, 'Radio',
                s.connected ? 'What your radio reports, compared with this region' : 'Not connected. Connect and see its settings'),
            row(MoreItem.myRadios, Icons.verified_user_outlined, 'My radios and claims',
                'Radios and repeaters you manage'),
            row(MoreItem.devices, Icons.key_outlined, 'Devices and keys', 'Your driver key, other phones, MeshMapper forwarding'),
            row(MoreItem.leaderboard, Icons.emoji_events_outlined, 'Leaderboard', 'Drivers who opted in, this region or every region'),
            row(MoreItem.myReports, Icons.report_gmailerrorred_outlined, 'My reports', 'Problem reports you sent and where they stand'),
            header('Radios and tools'),
            row(MoreItem.repeaters, Icons.cell_tower, 'Repeaters and rooms',
                s.connected ? 'Administer a repeater, read and post in a room' : 'Needs your radio. Free repeater administration'),
            row(MoreItem.trace, Icons.route, 'Trace path', 'Test the route through repeaters, hop by hop'),
            row(MoreItem.discover, Icons.radar, 'Discover nearby', 'Find repeaters that can hear you, and how well'),
            row(MoreItem.adverts, Icons.campaign_outlined, 'Adverts', 'Send yours, see who is advertising'),
            row(MoreItem.rxLog, Icons.list_alt, 'Rx log', 'Every packet your radio hears'),
            row(MoreItem.noiseFloor, Icons.show_chart, 'Noise floor and health', 'Interference and radio counters, live'),
            row(MoreItem.telemetry, Icons.thermostat, 'Telemetry', 'Battery, temperature and position of a node'),
            row(MoreItem.radioSetup, Icons.tune, 'Radio setup', 'Name, position, power and frequency, with checks'),
            row(MoreItem.observerJoin, Icons.visibility_outlined, 'Become an observer',
                'Step by step: make your repeater report to MeshSonar. Free'),
            header('App'),
            row(MoreItem.wardriving, Icons.radar, 'Wardriving settings',
                'Send pings, channel, interval, distance, listen window'),
            row(MoreItem.notifications, Icons.notifications_outlined, 'Notifications',
                'Message alerts, previews, quiet hours, per-conversation mute'),
            row(MoreItem.settings, Icons.settings, 'Settings', 'Units, maps, uploads, storage, diagnostics, your driver key'),
            row(MoreItem.legend, Icons.palette_outlined, 'Colour legend', 'What the map colours mean'),
            row(MoreItem.howItWorks, Icons.explore_outlined, 'How it works', 'From a ping to a square on the map, and a tour of the tabs'),
            row(MoreItem.method, Icons.menu_book_outlined, 'Method', 'How the figures are made, and what they cannot say'),
            header('About'),
            row(MoreItem.privacy, Icons.privacy_tip_outlined, 'Privacy and data sharing', 'What is shared, and how to stop it'),
            ListTile(
              key: const Key('more-report'),
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report a problem'),
              subtitle: const Text('Send the team what went wrong'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openReportProblem(context),
            ),
            row(MoreItem.about, Icons.info_outline, 'About MeshSonar',
                'Version ${s.services.appInfo.version ?? ''}, licence, credits'),
            ListTile(
              key: const Key('more-privacy-policy'),
              leading: const Icon(Icons.policy_outlined),
              title: const Text('Privacy policy'),
              subtitle: const Text('Opens in your browser'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => s.services.openUrl(Uri.parse(privacyPolicyUrl)),
            ),
            const SizedBox(height: Gap.xl),
          ],
        ),
      ),
    );
  }
}
