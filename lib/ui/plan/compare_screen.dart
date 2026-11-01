// Plan > Site explorer > Compare: two to four sites row by row on the planning engine's model. Bold marks the best value in a row;
// it is a label, not a recommendation. Built from the site list the explorer already holds, so it works offline.
import 'package:flutter/material.dart';

import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_sites.dart';
import '../app.dart';
import 'plan_common.dart';
import 'site_detail_screen.dart';

class CompareScreen extends StatefulWidget {
  final PlanNativeApi? api;
  final PlanSites data;
  final List<String> refs;
  const CompareScreen({super.key, this.api, required this.data, required this.refs});
  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  late final List<String> _refs = [...widget.refs];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cols = [for (final r in _refs) ?widget.data.byRef(r)];
    final rows = cols.length < 2 ? <CompareRow>[] : compareRows(cols, widget.data.repeaterName, units: AppScope.unitsOf(context));
    return Scaffold(
      appBar: AppBar(title: const Text('Compare sites')),
      body: SafeArea(
        top: false,
        child: planColumn(key: const Key('compare-list'), [
          planHeader(context, 'Compare sites', 'Up to four sites, row by row. The best value in each row is in bold.'),
          if (cols.length < 2) Text('Pick two to four sites in the explorer to compare.', key: const Key('compare-few'), style: t.textTheme.bodyLarge),
          if (cols.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                key: const Key('compare-table'),
                columnSpacing: 20,
                dataRowMinHeight: 56,
                dataRowMaxHeight: 96,
                columns: [
                  const DataColumn(label: Text('')),
                  for (final c in cols)
                    DataColumn(
                      label: SizedBox(
                        width: 130,
                        child: Row(children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SiteDetailScreen(api: widget.api, ref: c.ref))),
                              child: Text(c.planSite ?? c.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                            ),
                          ),
                          IconButton(
                            key: Key('compare-remove-${c.id}'),
                            tooltip: 'Remove ${c.name} from the comparison',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => setState(() => _refs.remove(c.ref)),
                          ),
                        ]),
                      ),
                    ),
                ],
                rows: [
                  for (final r in rows)
                    DataRow(cells: [
                      DataCell(SizedBox(width: 120, child: Text(r.sub == null ? r.label : '${r.label}\n${r.sub}', style: t.textTheme.labelMedium))),
                      for (final c in r.cells)
                        DataCell(SizedBox(
                          width: 130,
                          child: Semantics(
                            label: c.best ? '${c.text} (best in row)' : c.text,
                            child: Text(c.text, style: c.best ? t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800) : t.textTheme.bodyMedium),
                          ),
                        )),
                    ]),
                ],
              ),
            ),
          const SizedBox(height: Gap.m),
          Text('Planning engine model: ${mountName(33)} (${heightText(context, 10)}) sites, live repeaters at ${heightText(context, 8)}; odds marked lidar (USGS 3DEP), est. (ESA WorldCover tree estimate) or terrain (no trees). Bold marks the best value in a row (earliest step, least canopy).',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
