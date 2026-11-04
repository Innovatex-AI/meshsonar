// The repeater dashboard (chat plan 4.10): one scrolling page instead of the old tab bar. A 2x2 glance grid with sparklines, the
// status rows, and standard drill-in rows for Neighbours, Telemetry, Settings, Access list and Console (the existing views, pushed).
// The login is the one sheet from login_sheet.dart. Pull to refresh really asks the repeater, through the radio's request queue.
// Auto refresh is off until switched on in the menu. Leaving the page logs out unless "Stay logged in" is on.
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoButton, CupertinoPageRoute, CupertinoSliverRefreshControl;
import 'package:flutter/material.dart';

import '../../../chat/db/stats_history_repository.dart' show StatsPoint;
import '../../../radio/default_passwords.dart';
import '../../../radio/has_connection.dart';
import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_wire.dart';
import '../../app.dart' show AppScope;
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/app_type.dart';
import '../../design/sparkline.dart';
import '../../design/tokens.dart';
import 'admin_access_view.dart';
import 'admin_common.dart';
import 'admin_console_view.dart';
import 'admin_controller.dart';
import 'admin_neighbours_view.dart';
import 'admin_overview_view.dart';
import 'admin_regions_view.dart';
import 'admin_settings_view.dart';
import 'dashboard_widgets.dart';
import 'login_sheet.dart';

/// Which glance card / chart.
enum DashMetric { battery, uptime, noise, airtime }

class RepeaterDashboardScreen extends StatefulWidget {
  final RepeaterAdminController controller;
  final String keyHex;

  /// The screen disposes the controller (and with it the session) when it closes.
  final bool ownsController;

  /// "Via 3" for the subtitle and the login sheet; null when unknown.
  final String? routeLine;
  final Future<void> Function()? resetRoute;
  const RepeaterDashboardScreen({super.key, required this.controller, required this.keyHex, this.ownsController = true, this.routeLine, this.resetRoute});

  /// How long a login is kept after leaving with "Stay logged in" on.
  static Duration stayFor = const Duration(minutes: 10);
  static final Map<String, Timer> _stayTimers = {};

  @override
  State<RepeaterDashboardScreen> createState() => _RepeaterDashboardScreenState();
}

class _RepeaterDashboardScreenState extends State<RepeaterDashboardScreen> with WidgetsBindingObserver {
  RepeaterAdminController get c => widget.controller;
  late final RemoteQueueWatch _watch = RemoteQueueWatch(c.session.queue);
  Timer? _tick;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RepeaterDashboardScreen._stayTimers.remove(widget.keyHex)?.cancel();
    c.checkVault();
    c.loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openLogin(auto: true));
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && c.statusAt != null) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => c.foreground = state == AppLifecycleState.resumed;

  Future<void> _openLogin({bool auto = false}) async {
    if (!mounted || _sheetOpen || c.stage == AdminStage.ready) return;
    _sheetOpen = true;
    try {
      if (auto && await c.resume()) return;
      if (!mounted) return;
      final model = LoginSheetModel.forAdmin(c, routeLine: widget.routeLine, resetRoute: widget.resetRoute);
      final o = await showLoginSheet(context, model: model);
      model.dispose();
      if (o == null && auto && mounted && c.stage != AdminStage.ready) Navigator.of(context).maybePop();
    } finally {
      _sheetOpen = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _watch.dispose();
    if (widget.ownsController) {
      final session = c.session;
      if (session.loggedIn) {
        if (c.stayLoggedIn) {
          // kept for a while so coming back resumes without the password
          final key = widget.keyHex;
          RepeaterDashboardScreen._stayTimers[key]?.cancel();
          RepeaterDashboardScreen._stayTimers[key] = Timer(RepeaterDashboardScreen.stayFor, () {
            RepeaterDashboardScreen._stayTimers.remove(key);
            AdminSessions.drop(key);
            unawaited(session.logout());
          });
        } else {
          AdminSessions.drop(widget.keyHex);
          unawaited(session.logout());
        }
      }
      c.dispose();
    }
    super.dispose();
  }

  String _nameFor(String target) {
    if (target == c.session.keyHex) return c.snapshot?.identity.name ?? c.title;
    final n = target.length >= 12 ? c.nameFor(target.substring(0, 12)) : null;
    return n ?? 'a repeater';
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final ready = c.stage == AdminStage.ready;
        final title = c.snapshot?.identity.name ?? c.title;
        if (!ready) {
          return Scaffold(
            key: const Key('repeater-dashboard'),
            appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
            body: SafeArea(child: _LoginPlaceholder(controller: c, onLogin: _openLogin)),
          );
        }
        return Scaffold(
          key: const Key('repeater-dashboard'),
          backgroundColor: AppColors.of(context).bg,
          appBar: AppBar(
            toolbarHeight: 64,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline),
              Text(_subtitle(), key: const Key('dash-subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted)),
            ]),
            actions: [
              IconButton(
                key: const Key('admin-menu'),
                tooltip: 'More',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const AppSymbolIcon(AppSymbols.ellipsisCircle),
                onPressed: _menu,
              ),
            ],
          ),
          body: Column(children: [
            Expanded(child: _page(context)),
            SafeArea(top: false, child: RemoteQueueStrip(watch: _watch, nameFor: _nameFor)),
          ]),
        );
      },
    );
  }

  String _subtitle() {
    final fw = c.snapshot?.identity.firmware;
    return [
      'Signed in as ${c.caps.isAdmin ? 'Admin' : 'Guest'}',
      if (widget.routeLine != null) widget.routeLine!,
      if (fw != null) 'fw ${fw.startsWith('v') ? fw.substring(1) : fw}',
    ].join(' · ');
  }

  Widget _page(BuildContext context) {
    final colors = AppColors.of(context);
    final admin = c.caps.isAdmin;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: CustomScrollView(
          key: const Key('dashboard-scroll'),
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: () => c.refreshStatus()),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.xl),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (c.notices['overview'] != null) NoticeBanner(c.notices['overview']!, bannerKey: const Key('overview-notice')),
                  _grid(context),
                  _updatedLine(context),
                  if (admin && c.factoryPasswordInUse != null) _factoryCard(context),
                  _statusGroup(context),
                  InsetGroup(
                    groupKey: const Key('group-more'),
                    header: 'More',
                    footer: admin ? null : 'Signed in as Guest. Admin features need the admin password.',
                    rows: [
                      if (c.hasNeighbours) GroupRow(rowKey: const Key('row-neighbours'), title: 'Neighbours', value: c.neighbours == null ? null : '${c.neighbours!.length}', onTap: () => _push('Neighbours', AdminNeighboursView(controller: c))),
                      GroupRow(rowKey: const Key('row-telemetry'), title: 'Telemetry', onTap: () => _push('Telemetry', _TelemetryPage(controller: c))),
                      if (c.hasRegions) GroupRow(rowKey: const Key('row-regions'), title: 'Regions', onTap: () => _push('Regions', AdminRegionsView(controller: c))),
                      GroupRow(rowKey: const Key('row-health'), title: 'Health check and clock', onTap: () => _push('Health check', AdminOverviewView(controller: c, keyHex: widget.keyHex))),
                      if (admin) GroupRow(rowKey: const Key('row-settings'), title: 'Settings', onTap: _openSettings),
                      if (admin) GroupRow(rowKey: const Key('row-access'), title: 'Access list', onTap: () => _push('Access list', AdminAccessView(controller: c))),
                      if (admin) GroupRow(rowKey: const Key('row-console'), title: 'Console', onTap: () => _push('Console', AdminConsoleView(controller: c))),
                    ],
                  ),
                  SizedBox(height: Gap.xl, child: ColoredBox(color: colors.bg)),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _push(String title, Widget body) {
    Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => _SubPage(title: title, child: body)));
  }

  void _openSettings() => _push('Settings', AdminSettingsView(controller: c));

  // ---- glance grid

  List<double> _series(DashMetric m) => [
        for (final p in c.history)
          switch (m) {
            DashMetric.battery => p.batteryMv / 1000,
            DashMetric.uptime => p.uptimeS / 86400,
            DashMetric.noise => p.noiseFloor.toDouble(),
            DashMetric.airtime => p.txAirPct,
          }
      ];

  ({String label, String value, String unit, String what, String sumUnit, int decimals}) _spec(DashMetric m) {
    final st = c.snapshot?.stats;
    switch (m) {
      case DashMetric.battery:
        final v = c.snapshot?.telemetry?.voltageV ?? (st == null ? null : st.battMilliVolts / 1000);
        return (label: 'Battery', value: v == null ? '—' : v.toStringAsFixed(2), unit: 'V', what: 'Battery', sumUnit: 'V', decimals: 2);
      case DashMetric.uptime:
        return (label: 'Uptime', value: st == null ? '—' : shortUptime(st.upTimeSecs).split(' ').first, unit: st == null ? '' : shortUptime(st.upTimeSecs).split(' ').skip(1).join(' '), what: 'Uptime', sumUnit: 'days', decimals: 1);
      case DashMetric.noise:
        return (label: 'Noise', value: st == null ? '—' : '${st.noiseFloorDbm}', unit: 'dBm', what: 'Noise', sumUnit: 'dBm', decimals: 0);
      case DashMetric.airtime:
        final pct = st == null || st.upTimeSecs <= 0 ? null : st.airTimeSecs * 100 / st.upTimeSecs;
        return (label: 'Airtime', value: pct == null ? '—' : pct.toStringAsFixed(1), unit: '% TX', what: 'Airtime sending', sumUnit: '%', decimals: 1);
    }
  }

  Widget _card(DashMetric m) {
    final s = _spec(m);
    final series = _series(m);
    return GlanceCard(
      cardKey: Key('glance-${m.name}'),
      valueKey: Key('glance-${m.name}-value'),
      label: s.label,
      value: s.value,
      unit: s.unit,
      series: series,
      summary: Sparkline.summary(s.what, series, unit: s.sumUnit, decimals: s.decimals),
      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => DashboardChartPage(controller: c, metric: m))),
    );
  }

  Widget _grid(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
    final width = MediaQuery.sizeOf(context).width;
    final cards = [for (final m in DashMetric.values) _card(m)];
    Widget wrap(List<Widget> row) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < row.length; i++) ...[if (i > 0) const SizedBox(width: Gap.m), Expanded(child: row[i])],
        ]);
    Widget body;
    if (scale >= 1.3) {
      body = Column(key: const Key('glance-one-column'), children: [for (final w in cards) Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: w)]);
    } else if (width >= 700) {
      body = Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: KeyedSubtree(key: const Key('glance-four-up'), child: wrap(cards)));
    } else {
      body = Column(key: const Key('glance-two-by-two'), children: [
        Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: wrap(cards.sublist(0, 2))),
        Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: wrap(cards.sublist(2))),
      ]);
    }
    return Padding(padding: const EdgeInsets.only(top: Gap.s), child: body);
  }

  Widget _updatedLine(BuildContext context) {
    final colors = AppColors.of(context);
    final busy = c.loadingStatus || c.loadingOverview;
    final text = busy ? 'Asking ${_nameFor(c.session.keyHex)}… up to 12 s' : '${updatedText(c.statusAt, c.now())} · pull to refresh';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (busy) const Padding(padding: EdgeInsets.only(right: Gap.s), child: CupertinoActivityIndicator(radius: 7)),
        Flexible(child: Text(text, key: const Key('dash-updated'), textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: colors.textMuted))),
      ]),
    );
  }

  Widget _factoryCard(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      key: const Key('factory-nag'),
      margin: const EdgeInsets.only(top: Gap.s),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: Color.alphaBlend(colors.warning.withValues(alpha: 0.14), colors.surface), borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        AppSymbolIcon(AppSymbols.exclamationTriangle, color: colors.warning),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(factoryPasswordWarning, style: AppType.subhead.copyWith(color: colors.textPrimary))),
        CupertinoButton(
          key: const Key('factory-nag-change'),
          minimumSize: const Size(Hit.min, Hit.min),
          padding: const EdgeInsets.only(left: Gap.s),
          onPressed: _openSettings,
          child: const Text('Change now'),
        ),
      ]),
    );
  }

  // ---- status group

  Widget _statusGroup(BuildContext context) {
    final st = c.snapshot?.stats;
    const na = 'n/a';
    String pct(int secs, bool has) => st == null || !has ? na : (st.upTimeSecs <= 0 ? na : '${(secs * 100 / st.upTimeSecs).toStringAsFixed(1)}%');
    final rows = <Widget>[
      GroupRow(rowKey: const Key('status-airtime'), valueKey: const Key('v-airtime'), title: 'Airtime TX / RX', value: st == null ? '—' : '${pct(st.airTimeSecs, true)} / ${pct(st.rxAirTimeSecs, st.hasRxAir)}'),
      GroupRow(rowKey: const Key('status-packets'), valueKey: const Key('v-packets'), title: 'Packets', value: st == null ? '—' : 'recv ${groupedInt(st.packetsRecv)}  sent ${groupedInt(st.packetsSent)}'),
      GroupRow(
          rowKey: const Key('status-signal'),
          valueKey: const Key('v-signal'),
          title: 'Last RSSI / SNR',
          value: st == null ? '—' : '${st.lastRssiDbm} / ${st.hasSnr ? '${st.lastSnrDb >= 0 ? '+' : ''}${st.lastSnrDb.toStringAsFixed(1)}' : na}'),
      GroupRow(rowKey: const Key('status-queue'), valueKey: const Key('v-queue'), title: 'Queue · errors', value: st == null ? '—' : '${st.txQueueLen} · ${st.hasErrEvents ? st.errEvents : na}'),
    ];
    return InsetGroup(groupKey: const Key('group-status'), header: 'Status', rows: rows);
  }

  // ---- menu

  Future<void> _menu() async {
    final v = await showAppActionSheet<String>(
      context,
      actions: [
        const AppAction('Refresh', 'refresh', key: Key('dash-refresh')),
        AppAction('Auto-refresh', 'auto', checked: c.autoRefresh, key: const Key('dash-auto')),
        AppAction('Stay logged in', 'stay', checked: c.stayLoggedIn, key: const Key('dash-stay')),
        if (c.caps.isAdmin) const AppAction('Reboot repeater', 'reboot', destructive: true, key: Key('dash-reboot')),
        const AppAction('Log out', 'logout', destructive: true, key: Key('admin-menu-logout')),
      ],
    );
    if (!mounted) return;
    switch (v) {
      case 'refresh':
        unawaited(c.refreshStatus());
      case 'auto':
        c.setAutoRefresh(!c.autoRefresh);
        showAppToast(context, c.autoRefresh ? 'Auto-refresh on: every 2 minutes while this page is open.' : 'Auto-refresh off.');
      case 'stay':
        c.stayLoggedIn = !c.stayLoggedIn;
        showAppToast(context, c.stayLoggedIn ? 'Staying logged in for ${RepeaterDashboardScreen.stayFor.inMinutes} minutes after you leave.' : 'You will be logged out when you leave.');
      case 'reboot':
        await _reboot();
      case 'logout':
        await c.logout();
        if (mounted) Navigator.of(context).maybePop();
    }
  }

  Future<void> _reboot() async {
    final name = c.snapshot?.identity.name ?? c.title;
    final go = await showAppActionSheet<bool>(
      context,
      title: 'Reboot $name?',
      message: 'It is off the air for a few seconds and then comes back.',
      actions: const [AppAction('Reboot repeater', true, destructive: true, key: Key('dash-reboot-confirm'))],
    );
    if (go != true || !mounted) return;
    try {
      final r = await c.reboot('REBOOT');
      if (mounted) showAppToast(context, r.message);
    } on AdminException catch (e) {
      if (mounted) showAppToast(context, e.message, kind: AppToastKind.error);
    }
  }
}

/// Behind the login sheet: the node's name, the last problem, and a button to open the sheet again.
class _LoginPlaceholder extends StatelessWidget {
  final RepeaterAdminController controller;
  final Future<void> Function({bool auto}) onLogin;
  const _LoginPlaceholder({required this.controller, required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('admin-login-placeholder'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(controller.title, style: AppType.title2, textAlign: TextAlign.center),
          if (controller.loginError != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(controller.loginError!, textAlign: TextAlign.center)),
          const SizedBox(height: Gap.l),
          CupertinoButton.filled(key: const Key('admin-open-login'), onPressed: () => onLogin(), child: const Text('Log in')),
        ]),
      ),
    );
  }
}

/// A pushed drill-in page around one of the existing views.
class _SubPage extends StatelessWidget {
  final String title;
  final Widget child;
  const _SubPage({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: Key('subpage-${title.toLowerCase().replaceAll(' ', '-')}'),
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: SafeArea(top: false, child: child),
    );
  }
}

// ---------------------------------------------------------------------------------------------- telemetry

class _TelemetryPage extends StatefulWidget {
  final RepeaterAdminController controller;
  const _TelemetryPage({required this.controller});

  @override
  State<_TelemetryPage> createState() => _TelemetryPageState();
}

class _TelemetryPageState extends State<_TelemetryPage> {
  RepeaterAdminController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (c.snapshot?.telemetry == null) WidgetsBinding.instance.addPostFrameCallback((_) => c.refreshTelemetry());
  }

  static String _name(LppValue v) => switch (v.type) {
        LppValue.typeVoltage => 'Voltage',
        LppValue.typeTemperature => 'Temperature',
        LppValue.typeHumidity => 'Humidity',
        LppValue.typePressure => 'Pressure',
        _ => 'Sensor ${v.channel}',
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final colors = AppColors.of(context);
        final t = c.snapshot?.telemetry;
        final rows = <Widget>[];
        if (t != null) {
          if (t.voltageV != null) rows.add(GroupRow(title: 'Battery', value: '${t.voltageV!.toStringAsFixed(2)} V', valueKey: const Key('tele-battery')));
          if (t.temperatureC != null) rows.add(GroupRow(title: 'Chip temperature', value: AppScope.unitsOf(context).temperature(t.temperatureC!), valueKey: const Key('tele-temp')));
          for (final v in t.values) {
            if (v.type == LppValue.typeVoltage && t.voltageV != null && v.channel == 1) continue;
            if (v.type == LppValue.typeTemperature && t.temperatureC != null && v.channel == 1) continue;
            rows.add(GroupRow(title: _name(v), value: v.value.toStringAsFixed(2)));
          }
        }
        return CustomScrollView(
          key: const Key('telemetry-page'),
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: c.refreshTelemetry),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.xl),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (c.notices['telemetry'] != null) NoticeBanner(c.notices['telemetry']!),
                  if (c.loadingTelemetry && t == null)
                    const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CupertinoActivityIndicator()))
                  else if (rows.isEmpty)
                    Padding(padding: const EdgeInsets.all(Gap.xl), child: Text('No readings yet. Pull down to ask the repeater.', style: AppType.body.copyWith(color: colors.textMuted)))
                  else
                    InsetGroup(
                      header: 'Readings',
                      footer: c.caps.isAdmin ? null : 'Signed in as Guest. Guests see the battery and chip temperature.',
                      rows: rows,
                    ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------- full chart

/// The page a glance card opens: the last 7 days of one value, larger, with lowest / highest / first / latest.
class DashboardChartPage extends StatelessWidget {
  final RepeaterAdminController controller;
  final DashMetric metric;
  const DashboardChartPage({super.key, required this.controller, required this.metric});

  (String title, String unit, int decimals, double Function(StatsPoint) pick) get _def => switch (metric) {
        DashMetric.battery => ('Battery', 'V', 2, (p) => p.batteryMv / 1000),
        DashMetric.uptime => ('Uptime', 'days', 1, (p) => p.uptimeS / 86400),
        DashMetric.noise => ('Noise', 'dBm', 0, (p) => p.noiseFloor.toDouble()),
        DashMetric.airtime => ('Airtime sending', '%', 1, (p) => p.txAirPct),
      };

  @override
  Widget build(BuildContext context) {
    final (title, unit, dec, pick) = _def;
    return Scaffold(
      key: Key('chart-${metric.name}'),
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final colors = AppColors.of(context);
            final pts = controller.history;
            final values = [for (final p in pts) pick(p)];
            String f(double x) => '${x.toStringAsFixed(dec)} $unit';
            final rows = <Widget>[];
            if (values.isNotEmpty) {
              final lo = values.reduce((a, b) => a < b ? a : b), hi = values.reduce((a, b) => a > b ? a : b);
              rows.addAll([
                GroupRow(title: 'Latest', value: f(values.last), valueKey: const Key('chart-latest')),
                GroupRow(title: 'Lowest', value: f(lo), valueKey: const Key('chart-lowest')),
                GroupRow(title: 'Highest', value: f(hi), valueKey: const Key('chart-highest')),
                GroupRow(title: 'Readings', value: '${values.length}'),
              ]);
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.xl),
              children: [
                Text('Last 7 days', style: AppType.footnote.copyWith(color: colors.textMuted)),
                const SizedBox(height: Gap.s),
                if (values.length < 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xl),
                    child: Text(
                      values.isEmpty ? 'No readings yet. Every time the dashboard reads this repeater it adds a point.' : 'One reading so far. A line appears after the next one.',
                      key: const Key('chart-empty'),
                      style: AppType.body.copyWith(color: colors.textMuted),
                    ),
                  )
                else
                  SparklineChart(values: values, format: (x) => x.toStringAsFixed(dec), semanticLabel: Sparkline.summary(title, values, unit: unit, decimals: dec)),
                if (rows.isNotEmpty) InsetGroup(rows: rows),
              ],
            );
          },
        ),
      ),
    );
  }
}
