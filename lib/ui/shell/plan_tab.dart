// The Plan tab. The planning tools live on the website today (planner, site explorer, link and coverage tools,
// airtime); each row here opens the real page for the region being viewed. Tools that will run inside the app are
// listed once, plainly marked "coming next", and have no button. Nothing here is a dead control.
import 'package:flutter/material.dart';

import '../app.dart';
import '../plan/airtime_screen.dart';
import '../plan/coverage_check_screen.dart';
import '../plan/field_screen.dart';
import '../plan/planner_screen.dart';
import '../plan/recommended_screen.dart';
import '../plan/scenarios_screen.dart';
import '../plan/link_screen.dart';
import '../plan/sites_screen.dart';
import '../plan/tracker_screen.dart';
import '../plan/painter_screen.dart';
import '../plan/presets_screen.dart';
import 'drive_next_card.dart';

class PlanTool {
  final String id;
  final String title;
  final String lead;
  final IconData icon;

  /// Path on the region's site (the website twin; for a native tool it is only the "view on the web" address).
  final String path;

  /// Set = the tool is a native screen in the app; null = it still opens on the website.
  final Widget Function()? native;
  const PlanTool(this.id, this.title, this.lead, this.icon, this.path, {this.native});
}

/// Website tools, with the names and leads the site itself uses (meshcore-insights `TOOL_PAGES`).
final List<PlanTool> planTools = [
  PlanTool('planner', 'Planner', 'Ask the planning engine where to build next.', Icons.edit_road_outlined, '/plan/planner',
      native: () => const PlannerScreen()),
  PlanTool('recommended', 'Recommended build', 'The engine\'s recommended build, phase by phase, with the budget and the risks.',
      Icons.checklist_rtl, '/plan/recommended', native: () => const RecommendedScreen()),
  PlanTool('sites', 'Site explorer', 'Candidate sites and the links between them.', Icons.place_outlined, '/sites', native: () => const SitesScreen()),
  PlanTool('scenarios', 'Scenarios', 'Toggle sites, heights and link tiers and see what the mesh would become.', Icons.tune, '/plan/scenarios', native: () => const ScenariosScreen()),
  PlanTool('tracker', 'Build tracker', 'Who is installing what, and where each site stands.', Icons.view_kanban_outlined, '/plan/tracker', native: () => const TrackerScreen()),
  PlanTool('link', 'Point-to-point link',
      'A terrain check between any two points: line of sight, clearance and the odds the link works.', Icons.timeline, '/tools/link', native: () => const LinkScreen()),
  PlanTool('painter', 'Coverage painter',
      'Modelled coverage from any point, from terrain and the link model.', Icons.blur_on, '/tools/painter', native: () => const PainterScreen()),
  PlanTool('airtime', 'Airtime and load',
      'Airtime per packet for any radio setting, and the mesh\'s channel load.', Icons.timer_outlined, '/tools/airtime', native: () => const AirtimeScreen()),
  PlanTool('presets', 'Radio presets',
      'How the common MeshCore radio presets compare on range, airtime and channel load.', Icons.tune, '/tools/presets', native: () => const PresetsScreen()),
  PlanTool('check', 'Coverage check', 'Is there measured coverage at a place? Checked against real drives.',
      Icons.fact_check_outlined, '/coverage/check', native: () => const CoverageCheckScreen()),
  PlanTool('field', 'Field data', 'Measured drives checked against the model, and where they live in the app.', Icons.dataset_outlined, '/tools/field',
      native: () => const FieldScreen()),
];

/// In-app tools that do not exist yet. Listed so the direction is honest; not tappable.
const List<(String, String)> plannedInApp = [];

Uri planToolUri(String base, String path) {
  final b = Uri.tryParse(base);
  return (b == null || !b.hasScheme) ? Uri.parse('https://meshsonar.com$path') : b.replace(path: path, query: '');
}

class PlanTab extends StatelessWidget {
  const PlanTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final region = s.viewingRegion;
    final base = region?.url ?? s.settings.serverUrl;
    final webTools = planTools.where((x) => x.native == null).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Plan')),
      body: SafeArea(
        top: false,
        // A reading column: on an iPad the cards would otherwise stretch across 1,100 dp.
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
          key: const Key('plan-list'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
          children: [
            const DriveNextCard(),
            Semantics(header: true, child: Text('Planning tools', style: t.textTheme.titleSmall)),
            const SizedBox(height: Gap.xs),
            Text(
              'Plan where the next repeater should go, check a link, paint coverage, work out airtime and compare radio presets${region == null ? '' : ' for ${region.name}'}, right here. No account needed.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.m),
            for (final tool in planTools.where((x) => x.native != null))
              Card(
                margin: const EdgeInsets.only(bottom: Gap.s),
                child: ListTile(
                  key: Key('plan-${tool.id}'),
                  minVerticalPadding: Gap.m,
                  leading: Icon(tool.icon, color: t.colorScheme.primary),
                  title: Text(tool.title),
                  subtitle: Text(tool.lead),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => tool.native!())),
                ),
              ),
            if (webTools.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              Semantics(header: true, child: Text('Plan on the website', style: t.textTheme.titleSmall)),
              const SizedBox(height: Gap.xs),
              Text(
                'These open on the website${region == null ? '' : ' for ${region.name}'}, in your browser. No account needed.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.m),
              for (final tool in webTools)
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.s),
                  child: ListTile(
                    key: Key('plan-${tool.id}'),
                    minVerticalPadding: Gap.m,
                    leading: Icon(tool.icon, color: t.colorScheme.primary),
                    title: Text(tool.title),
                    subtitle: Text(tool.lead),
                    trailing: const Icon(Icons.open_in_new, size: 18, semanticLabel: 'Opens in your browser'),
                    onTap: () async {
                      final ok = await s.services.openUrl(planToolUri(base, tool.path));
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Couldn\'t open the browser. Try again, or visit meshsonar.com.')));
                      }
                    },
                  ),
                ),
            ],
            if (plannedInApp.isNotEmpty) ...[
              const SizedBox(height: Gap.l),
              Semantics(header: true, child: Text('Coming next, inside the app', style: t.textTheme.titleSmall)),
              const SizedBox(height: Gap.xs),
              for (final p in plannedInApp)
                ListTile(
                  key: Key('plan-soon-${p.$1.hashCode}'),
                  enabled: false,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text(p.$1),
                  subtitle: Text(p.$2),
                ),
            ],
          ],
        ),
          ),
        ),
      ),
    );
  }
}
