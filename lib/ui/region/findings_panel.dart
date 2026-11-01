// Region "Findings" tab: the website's /findings page. What the network data shows, the evidence behind each finding, the action it
// implies, then the recommendations those findings support. Data: `region-findings` (lib/core/region_findings_api.dart).
// A severity filter (All / Critical / High / Medium / Low with counts) narrows the list. Evidence references ("D2", "link:A|B")
// are written out with the site's name. The website's live "re-checked against the latest snapshot" chips are not shown.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_findings_api.dart';
import '../theme.dart';
import 'region_dataset_view.dart';

/// "D2" -> "D2 (Dublin Library)"; "link:D2|Oscar's" -> "D2 to Oscar's"; several refs split on commas.
String findingRefText(String ref, Map<String, String> sites) => [
      for (final p in ref.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty))
        if (p.startsWith('link:'))
          () {
            final ab = p.substring(5).split('|');
            return '${ab.first} to ${ab.length > 1 ? ab[1] : ''}';
          }()
        else if (sites[p] != null)
          '$p (${sites[p]})'
        else
          p,
    ].join(', ');

class FindingsPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  final http.Client? client;
  const FindingsPanel({super.key, required this.baseUrl, required this.regionSlug, this.client});
  @override
  State<FindingsPanel> createState() => _FindingsPanelState();
}

class _FindingsPanelState extends State<FindingsPanel> {
  FindingSeverity? _sev;

  @override
  Widget build(BuildContext context) => RegionDatasetView<RegionFindings>(
        id: 'findings',
        title: 'Findings',
        reloadKey: '${widget.baseUrl}|${widget.regionSlug}',
        load: () => RegionFindingsApi(widget.baseUrl, client: widget.client).fetch(),
        status: (d) => d.status,
        isEmpty: (d) => d.isEmpty,
        emptyText: 'No findings have been written for this region yet.',
        build: (context, d) => _body(context, d),
      );

  List<Widget> _body(BuildContext context, RegionFindings d) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final visible = _sev == null ? d.insights : [for (final i in d.insights) if (i.severity == _sev) i];
    final day = d.asOf == null ? null : '${d.asOf!.toUtc().year}-${d.asOf!.toUtc().month.toString().padLeft(2, '0')}-${d.asOf!.toUtc().day.toString().padLeft(2, '0')}';
    return [
      Text(
        '${d.insights.length} finding${d.insights.length == 1 ? '' : 's'} from the ${day == null ? '' : '$day '}baseline, each with its evidence and the action it implies, followed by the ${d.recommendations.length} recommendation${d.recommendations.length == 1 ? '' : 's'} they support.',
        key: const Key('findings-lead'),
        style: t.textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.m),
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(key: const Key('findings-sev-all'), label: Text('All ${d.insights.length}'), selected: _sev == null, onSelected: (_) => setState(() => _sev = null)),
        for (final s in FindingSeverity.values)
          if (d.count(s) > 0)
            ChoiceChip(
              key: Key('findings-sev-${s.name}'),
              label: Text('${_cap(s.name)} ${d.count(s)}'),
              selected: _sev == s,
              onSelected: (_) => setState(() => _sev = _sev == s ? null : s),
            ),
      ]),
      const SizedBox(height: Gap.s),
      if (visible.isEmpty) const Text('No findings at this severity.', key: Key('findings-none')),
      for (final i in visible) _FindingCard(finding: i, sites: d.sites),
      if (d.recommendations.isNotEmpty) ...[
        const SizedBox(height: Gap.l),
        Text('Recommendations', style: t.textTheme.titleLarge),
        const SizedBox(height: Gap.s),
        for (final r in d.recommendations)
          DatasetCard(
            child: Column(key: Key('findings-rec-${r.id}'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r.id}  ${r.title}', style: t.textTheme.titleMedium),
              if (r.why.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(r.why)),
              if (r.impact.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final e in r.impact.entries) Chip(visualDensity: VisualDensity.compact, label: Text('${impactValue(e.key, e.value)} ${impactLabel(e.key)}')),
                  ]),
                ),
              for (final a in r.actions)
                Padding(padding: const EdgeInsets.only(top: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: Text(a))])),
              if (r.insights.isNotEmpty || r.sites.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: Text(
                    [
                      if (r.insights.isNotEmpty) 'Findings: ${r.insights.join(', ')}',
                      if (r.sites.isNotEmpty) 'Sites: ${[for (final s in r.sites) d.sites[s] == null ? s : '$s (${d.sites[s]})'].join(', ')}',
                    ].join('   '),
                    style: t.textTheme.bodySmall?.copyWith(color: m.textMuted),
                  ),
                ),
            ]),
          ),
      ],
    ];
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _FindingCard extends StatelessWidget {
  final Finding finding;
  final Map<String, String> sites;
  const _FindingCard({required this.finding, required this.sites});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final f = finding;
    final tone = switch (f.severity) {
      FindingSeverity.critical => t.colorScheme.error,
      FindingSeverity.high => m.snrWeak,
      FindingSeverity.medium => m.beacon,
      FindingSeverity.low => m.textMuted,
    };
    Widget block(String label, String text) => text.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t.textTheme.labelLarge?.copyWith(color: m.textMuted)),
              Text(text),
            ]),
          );
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.s),
      child: ExpansionTile(
        key: Key('finding-${f.id}'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.flag, color: tone),
        title: Text('${f.id}  ${f.headline}'),
        subtitle: Text('${_cap(f.severity.name)}${f.category.isEmpty ? '' : ' · ${f.category}'}'),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          block('Finding', f.finding),
          if (f.evidence.isNotEmpty) ...[
            Text('Evidence', style: t.textTheme.labelLarge?.copyWith(color: m.textMuted)),
            for (final e in f.evidence)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 5, child: Text(e.label)),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: Text(e.ref == null ? e.value : '${e.value}  (${findingRefText(e.ref!, sites)})', textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            const SizedBox(height: Gap.s),
          ],
          block('What it means', f.implication),
          block('Action', f.action),
          if (f.sites.isNotEmpty) block('Sites', [for (final s in f.sites) sites[s] == null ? s : '$s (${sites[s]})'].join(', ')),
          if (f.repeaters.isNotEmpty) block('Repeaters', f.repeaters.join(', ')),
        ],
      ),
    );
  }
}
