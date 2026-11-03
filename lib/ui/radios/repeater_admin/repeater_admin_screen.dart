// Remote administration of one repeater or room server: log in, then Overview / Settings / Neighbours / Regions / Access /
// Console. Free for the owner. The password goes only to your own radio; nothing here talks to MeshSonar's servers.
import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/material.dart';

import '../../../app/app_flags.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../theme.dart';
import 'admin_access_view.dart';
import 'admin_common.dart';
import 'admin_console_view.dart';
import 'admin_controller.dart';
import 'admin_login_view.dart';
import 'login_sheet.dart';
import 'admin_neighbours_view.dart';
import 'admin_overview_view.dart';
import 'admin_regions_view.dart';
import 'admin_settings_view.dart';

class RepeaterAdminScreen extends StatefulWidget {
  final RepeaterAdminController controller;
  final String keyHex;

  /// The screen disposes the controller (and with it the session) when it closes.
  final bool ownsController;

  /// "Via 3 repeaters - Strong" under the node name on the login sheet; null when unknown.
  final String? routeLine;

  /// Forgets the radio's saved route to this node (the login sheet's "Search for it").
  final Future<void> Function()? resetRoute;
  const RepeaterAdminScreen({super.key, required this.controller, required this.keyHex, this.ownsController = true, this.routeLine, this.resetRoute});

  @override
  State<RepeaterAdminScreen> createState() => _RepeaterAdminScreenState();
}

class _RepeaterAdminScreenState extends State<RepeaterAdminScreen> {
  RepeaterAdminController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // A saved password (only if the person chose to remember) logs in by itself.
    c.checkVault();
    if (AppFlags.chatRedesign) WidgetsBinding.instance.addPostFrameCallback((_) => _openLogin(auto: true));
  }

  bool _sheetOpen = false;

  /// New flow (chatRedesign): the login is one sheet over the node. A session the radio still holds is resumed without it.
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
    if (widget.ownsController) {
      // With the new flow the login stays on the radio (it is resumed next time, when the radio can confirm it).
      if (!AppFlags.chatRedesign) c.session.logout();
      c.dispose();
    }
    super.dispose();
  }

  List<(String, IconData, Widget)> get _tabs => [
        ('Overview', Icons.dashboard_outlined, AdminOverviewView(controller: c, keyHex: widget.keyHex)),
        ('Settings', Icons.tune, AdminSettingsView(controller: c)),
        if (!c.isRoom) ('Neighbours', Icons.hub_outlined, AdminNeighboursView(controller: c)),
        if (!c.isRoom) ('Regions', Icons.account_tree_outlined, AdminRegionsView(controller: c)),
        ('Access', Icons.key_outlined, AdminAccessView(controller: c)),
        ('Console', Icons.terminal, AdminConsoleView(controller: c)),
      ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final ready = c.stage == AdminStage.ready;
        final title = c.snapshot?.identity.name ?? c.title;
        if (!ready) {
          return Scaffold(
            key: const Key('repeater-admin-screen'),
            appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis), actions: [AirtimeChip(active: c.usingAirtime)]),
            body: SafeArea(
                child: AppFlags.chatRedesign
                    ? _LoginPlaceholder(controller: c, onLogin: _openLogin)
                    : AdminLoginView(controller: c, what: c.isRoom ? 'room' : 'repeater')),
          );
        }
        final tabs = _tabs;
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            key: const Key('repeater-admin-screen'),
            appBar: AppBar(
              title: Text(title, overflow: TextOverflow.ellipsis),
              actions: [
                AirtimeChip(active: c.usingAirtime),
                IconButton(
                  key: const Key('admin-menu'),
                  tooltip: 'More',
                  icon: const AppSymbolIcon(AppSymbols.ellipsisCircle),
                  onPressed: () async {
                    final v = await showAppActionSheet<String>(context, actions: const [AppAction('Log out', 'logout', destructive: true, key: Key('admin-menu-logout'))]);
                    if (v == 'logout') c.logout();
                  },
                ),
              ],
              bottom: TabBar(
                key: const Key('admin-tabs'),
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                // Icons go at large text sizes: icon, label and padding no longer fit in a tab's height.
                tabs: [
                  for (final t in tabs)
                    MediaQuery.textScalerOf(context).scale(16) > 24
                        ? Tab(key: Key('tab-${t.$1.toLowerCase()}'), text: t.$1)
                        : Tab(key: Key('tab-${t.$1.toLowerCase()}'), text: t.$1, icon: Icon(t.$2), height: 64),
                ],
              ),
            ),
            body: SafeArea(top: false, child: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [for (final t in tabs) t.$3])),
          ),
        );
      },
    );
  }
}

/// Used by the tabs that load lazily to avoid a flash of "not loaded".
const double kTabGap = Gap.l;


/// Behind the login sheet: the node's name, the last problem, and a button to open the sheet again.
class _LoginPlaceholder extends StatelessWidget {
  final RepeaterAdminController controller;
  final Future<void> Function({bool auto}) onLogin;
  const _LoginPlaceholder({required this.controller, required this.onLogin});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      key: const Key('admin-login-placeholder'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(controller.title, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
          if (controller.loginError != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(controller.loginError!, textAlign: TextAlign.center)),
          const SizedBox(height: Gap.l),
          CupertinoButton.filled(key: const Key('admin-open-login'), onPressed: () => onLogin(), child: const Text('Log in')),
        ]),
      ),
    );
  }
}
