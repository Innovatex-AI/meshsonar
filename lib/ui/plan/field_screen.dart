// Plan > Field data. The website's tools/field page is a pointer ("Field data has moved") plus a driver-management note; its
// content lives in measured coverage, community drives and contribute-data pages. In the app those are native already, so this
// screen is the honest native twin: what measured field data the region has, with a button to each place it lives in the app.
import 'package:flutter/material.dart';

import '../app.dart';
import 'plan_common.dart';

class FieldScreen extends StatelessWidget {
  const FieldScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final cov = s.networkCoverage;
    final driven = cov?.cells.where((c) => c.pings > 0).toList() ?? const [];
    final heard = driven.where((c) => c.heard > 0).length;
    final mine = s.drivePings.length;
    return PlanPage(id: 'field', title: 'Field data', children: [
      Text('Measured data checked against the model: drives from MeshSonar and forwarded MeshMapper data, square by square.', style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.m),
      PlanCard(cardKey: const Key('field-summary'), title: s.viewingRegion?.name ?? 'Measured coverage', children: [
        if (cov == null)
          const PlanNote('Measured coverage has not loaded yet. Open the Map tab to load it.', key: Key('field-none'))
        else
          PlanFacts([
            ('Driven cells', '${driven.length}'),
            ('Cells where a repeater answered', driven.isEmpty ? '-' : '$heard (${(100 * heard / driven.length).round()} %)'),
            ('Pings measured', '${driven.fold<int>(0, (a, c) => a + c.pings)}'),
            ('Data as of', cov.asOf),
            if (mine > 0) ('Pings in your current drive', '$mine'),
          ]),
      ]),
      PlanCard(title: 'Where field data lives in the app', children: [
        ListTile(
          key: const Key('field-map'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.map_outlined),
          title: const Text('Measured coverage map'),
          subtitle: const Text('Every driven square, by signal, age or noise.'),
          onTap: () => _go(context, AppTab.map),
        ),
        ListTile(
          key: const Key('field-drive'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.directions_car_outlined),
          title: const Text('Drive and contribute'),
          subtitle: const Text('Your drives upload as they finish and count at once.'),
          onTap: () => _go(context, AppTab.map, drive: true),
        ),
      ]),
      Text('Revoking or banning driver keys is an admin job on the website; anyone can drive with a key from the app.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }

  void _go(BuildContext context, AppTab tab, {bool drive = false}) {
    final shell = ShellScope.maybeOf(context);
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (drive) {
      shell?.openDrive();
    } else {
      shell?.select(tab);
    }
  }
}
