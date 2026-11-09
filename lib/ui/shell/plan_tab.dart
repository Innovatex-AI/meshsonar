// The Plan tab: "Where to drive next" and the planning tools that work today, all native screens in the app. The Oct 15
// planning-engine screens (Planner, Recommended build, Site explorer, Scenarios, Build tracker) and the Field data page were
// removed in M0 (Nov 8 2026, unified map plan §4): they were CMH-only and frozen. "Find a site" replaces the planner in phase P.
import 'package:flutter/material.dart';

import '../plan/airtime_screen.dart';
import '../plan/coverage_check_screen.dart';
import '../plan/link_screen.dart';
import '../plan/painter_screen.dart';
import '../plan/presets_screen.dart';
import 'drive_next_card.dart';
import '../app.dart';

class PlanTool {
  final String id;
  final String title;
  final String lead;
  final IconData icon;

  /// Path of the website twin on the region's site.
  final String path;

  /// The native screen the row opens.
  final Widget Function() native;
  const PlanTool(this.id, this.title, this.lead, this.icon, this.path, {required this.native});
}

/// The tools, with the names and leads the website uses (meshcore-insights `TOOL_PAGES`).
final List<PlanTool> planTools = [
  PlanTool('link', 'Point-to-point link',
      'A terrain check between any two points: line of sight, clearance and the odds the link works.', Icons.timeline, '/tools/link', native: () => const LinkScreen()),
  PlanTool('painter', 'Coverage painter',
      'Modelled coverage from any point, from terrain and the link model.', Icons.blur_on, '/tools/painter', native: () => const PainterScreen()),
  PlanTool('airtime', 'Airtime and load',
      'Airtime per packet for any radio setting, and how much of the channel a send rate takes.', Icons.timer_outlined, '/tools/airtime', native: () => const AirtimeScreen()),
  PlanTool('presets', 'Radio presets',
      'How the common MeshCore radio presets compare on range, airtime and channel load.', Icons.tune, '/tools/presets', native: () => const PresetsScreen()),
  PlanTool('check', 'Coverage check', 'Is there measured coverage at a place? Checked against real drives.',
      Icons.fact_check_outlined, '/coverage/check', native: () => const CoverageCheckScreen()),
];

/// A page on the region's website (or meshsonar.com when the base is not a URL).
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
                  'Check a link, paint coverage, work out airtime, compare radio presets and check measured coverage'
                  '${region == null ? '' : ' for ${region.name}'}, right here. No account needed.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: Gap.m),
                for (final tool in planTools)
                  Card(
                    margin: const EdgeInsets.only(bottom: Gap.s),
                    child: ListTile(
                      key: Key('plan-${tool.id}'),
                      minVerticalPadding: Gap.m,
                      leading: Icon(tool.icon, color: t.colorScheme.primary),
                      title: Text(tool.title),
                      subtitle: Text(tool.lead),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => tool.native())),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
