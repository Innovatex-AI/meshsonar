// Remote administration of one repeater or room server: log in, then Overview / Settings / Neighbours / Regions / Access /
// Console. Free for the owner. The password goes only to your own radio; nothing here talks to MeshSonar's servers.
import 'package:flutter/material.dart';

import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../theme.dart';
import 'admin_access_view.dart';
import 'admin_common.dart';
import 'admin_console_view.dart';
import 'admin_controller.dart';
import 'admin_login_view.dart';
import 'admin_neighbours_view.dart';
import 'admin_overview_view.dart';
import 'admin_regions_view.dart';
import 'admin_settings_view.dart';

class RepeaterAdminScreen extends StatefulWidget {
  final RepeaterAdminController controller;
  final String keyHex;

  /// The screen disposes the controller (and with it the session) when it closes.
  final bool ownsController;
  const RepeaterAdminScreen({super.key, required this.controller, required this.keyHex, this.ownsController = true});

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
  }

  @override
  void dispose() {
    if (widget.ownsController) {
      c.session.logout();
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
            body: SafeArea(child: AdminLoginView(controller: c, what: c.isRoom ? 'room' : 'repeater')),
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
