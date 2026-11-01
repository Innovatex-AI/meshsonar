// Plan > Radio presets. Every bandwidth x spreading factor against the region's preset for a 50-byte packet: time on air,
// receiver sensitivity, link-budget change and the airtime of one flood across the region's repeaters. All maths on the
// phone (lib/core/plan/presets_calc.dart, a port of the website's src/lib/tools/presets.ts, verified against numbers
// generated from it), so it works with no connection. The website's extra "links that survive the change" columns need its
// in-browser terrain grid and link list, which the app does not carry; they are not shown here. Read-only.
import 'package:flutter/material.dart';

import '../../core/plan/airtime_calc.dart';
import '../../core/plan/presets_calc.dart';
import '../app.dart';
import 'plan_common.dart';

class PresetsScreen extends StatefulWidget {
  const PresetsScreen({super.key});

  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  int? _cr;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final region = s.viewingRegion;
    final preset = s.viewingPreset;
    final none = s.viewingPresetNone;
    final base = preset != null ? AirRadio(sf: preset.sf, bwKHz: preset.bwKhz, cr: preset.cr) : meshcoreUs;
    final baseName = preset?.name ?? (none != null ? 'MeshCore US reference' : 'MeshCore US default');
    final cr = _cr ?? base.cr;
    final repeaters = s.regionRepeaterSet.rows.where((r) => !r.isRoom).length;
    final rows = presetRows(cr: cr, repeaters: repeaters, base: base);
    final cur = rows.where((r) => r.sf == base.sf && r.bwKHz == base.bwKHz).firstOrNull;
    return PlanPage(id: 'presets', title: 'Radio presets', children: [
      Text(
        'Every bandwidth and spreading factor against the $baseName preset '
        '(${preset == null ? '${meshcoreUsFreqMhz.toStringAsFixed(3)} MHz, ' : '${preset.freqMhz.toStringAsFixed(3)} MHz, '}${_bw(base.bwKHz)} kHz, SF${base.sf}, CR 4/${base.cr}) for a $presetPacketBytes-byte packet. '
        'Narrow and low SF wins, but every node on the mesh has to change together.',
        style: t.textTheme.bodyMedium,
      ),
      if (none != null) ...[
        const SizedBox(height: Gap.s),
        PlanNote('${region?.name ?? 'This region'} has no published preset: ${none.reason}', key: const Key('presets-none')),
      ] else if (preset == null) ...[
        const SizedBox(height: Gap.s),
        const PlanNote('No preset is on file for this region, so the comparison is against MeshCore\'s US default.', key: Key('presets-nobase')),
      ],
      const SizedBox(height: Gap.m),
      PlanCard(
        cardKey: const Key('presets-grid'),
        title: 'Presets compared',
        lead: repeaters > 0 ? 'One flood = $repeaters repeaters, each re-broadcasting once.' : 'Flood load needs the region\'s repeater list, which is not loaded.',
        children: [
          PlanSegments<int>(
            label: 'Coding rate',
            segKey: const Key('presets-cr'),
            selected: cr,
            segments: [for (final c in crOptions) ButtonSegment(value: c, label: Text('4/$c'))],
            onChanged: (v) => setState(() => _cr = v),
          ),
          const SizedBox(height: Gap.m),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              key: const Key('presets-table'),
              columnSpacing: 20,
              headingRowHeight: 40,
              dataRowMinHeight: 40,
              dataRowMaxHeight: 52,
              columns: [
                const DataColumn(label: Text('Preset')),
                const DataColumn(label: Text('Time on air'), numeric: true),
                const DataColumn(label: Text('Sensitivity'), numeric: true),
                const DataColumn(label: Text('Budget vs now'), numeric: true),
                if (repeaters > 0) const DataColumn(label: Text('One flood'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    key: ValueKey('presets-row-${r.bwKHz}-${r.sf}'),
                    selected: r.sf == base.sf && r.bwKHz == base.bwKHz,
                    cells: [
                      DataCell(Text('SF${r.sf} / ${_bw(r.bwKHz)} kHz${r.sf == base.sf && r.bwKHz == base.bwKHz ? (r.isBase ? '  (now)' : '  (now, at CR 4/${base.cr})') : ''}')),
                      DataCell(Text(fmtMs(r.toaMs))),
                      DataCell(Text('${r.sensitivity.toStringAsFixed(1)} dBm')),
                      DataCell(Text(_delta(r.delta))),
                      if (repeaters > 0) DataCell(Text(fmtMs(r.floodLoadMs))),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          Text(
            'Sensitivity = -174 + 10 log10(BW) + 6 dB noise figure + the SF\'s SNR floor (SF7 -7.5 to SF12 -20 dB). Budget vs now = the current preset\'s sensitivity minus this one; '
            'positive means more margin. ${cur == null ? '' : 'One flood at the current preset is ${fmtMs(cur.floodLoadMs)}. '}'
            'Time on air follows Semtech AN1200.13 with MeshCore\'s preamble. The website also scores how many of the region\'s modelled links would survive each preset on its terrain grid; that needs data the app does not carry.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    ]);
  }

  static String _bw(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  static String _delta(double d) => d.abs() < 0.05 ? '0.0 dB' : '${d > 0 ? '+' : '-'}${d.abs().toStringAsFixed(1)} dB';
}
