// Plan > Site explorer, native: every possible repeater site in the planning engine's order, with search, kind and town filters,
// sort, distance from a place, a map view, and a selection that opens Compare or the scenario lab. The list is the website's
// (plan-native?view=sites) and filtering and sorting run on the phone, so the last list works offline.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_sites.dart';
import '../theme.dart';
import 'compare_screen.dart';
import 'plan_common.dart';
import 'site_detail_screen.dart';

const _kindLabel = {'worship': 'Church / worship', 'school': 'School', 'park': 'Park', 'plan': 'Original plan'};

class SitesScreen extends StatelessWidget {
  final PlanNativeApi? api;
  const SitesScreen({super.key, this.api});
  @override
  Widget build(BuildContext context) {
    final a = api ?? planApiFor(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Site explorer')),
      body: SafeArea(
        top: false,
        child: PlanFetchView<PlanSites>(
          id: 'sites',
          load: a.sites,
          reloadKey: a.baseUrl,
          available: (d) => d.available && d.rows.isNotEmpty,
          unavailableText: (d) => d.reason ?? 'No possible sites are listed for this region yet.',
          build: (context, d, reload) => _SitesList(api: a, data: d),
        ),
      ),
    );
  }
}

class _SitesList extends StatefulWidget {
  final PlanNativeApi api;
  final PlanSites data;
  const _SitesList({required this.api, required this.data});
  @override
  State<_SitesList> createState() => _SitesListState();
}

class _SitesListState extends State<_SitesList> {
  SiteFilter _f = const SiteFilter();
  final _text = TextEditingController();
  final Set<String> _sel = {};
  bool _map = false;
  int _page = 1;
  static const _pageSize = 50;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(SiteFilter f) => setState(() {
        _f = f;
        _page = 1;
      });

  void _sort(SiteSort s) => _set(_f.copyWith(sort: s, asc: defaultAsc(s)));

  Future<void> _pickNear() async {
    final d = widget.data;
    // A site is the nearest thing to "a place" the list knows: pick one to sort by distance from it.
    final picked = await showModalBottomSheet<SiteRow>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _PlacePicker(rows: d.rows),
    );
    if (picked != null) _set(_f.copyWith(near: NearPoint(picked.lat, picked.lon, picked.name), sort: SiteSort.dist, asc: true));
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final t = Theme.of(context);
    final base = baseFilter(d.rows, _f);
    final counts = kindCounts(base);
    final towns = townCounts(d.rows);
    final rows = applyFilter(d.rows, _f);
    final pages = (rows.length / _pageSize).ceil().clamp(1, 1 << 30);
    final page = _page.clamp(1, pages);
    final shown = rows.skip((page - 1) * _pageSize).take(_pageSize).toList();
    final selRows = [for (final id in _sel) ?d.rows.where((r) => r.id == id).firstOrNull];
    return planColumn(key: const Key('sites-list'), [
      planHeader(context, 'Site explorer', 'Every place of worship, school and park in the analysis area plus the original plan sites, on one model. Ordered by the planning engine.'),
      TextField(
        key: const Key('sites-search'),
        controller: _text,
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name, street, town, ZIP or plan ID', isDense: true),
        onChanged: (v) => _set(_f.copyWith(q: v)),
      ),
      const SizedBox(height: Gap.s),
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(key: const Key('sites-kind-all'), label: Text('All ${groupInt(base.length)}'), selected: _f.kind == null, onSelected: (_) => _set(_f.copyWith(kind: null))),
        for (final k in const ['worship', 'school', 'park', 'plan'])
          ChoiceChip(key: Key('sites-kind-$k'), label: Text('${_kindLabel[k]} ${groupInt(counts[k] ?? 0)}'), selected: _f.kind == k, onSelected: (on) => _set(_f.copyWith(kind: on ? k : null))),
      ]),
      Wrap(spacing: 8, children: [
        FilterChip(key: const Key('sites-joins'), label: const Text('Links into today\'s main mesh'), selected: _f.joins, onSelected: (v) => _set(_f.copyWith(joins: v))),
        FilterChip(key: const Key('sites-likely'), label: const Text('Has a Likely+ link'), selected: _f.likely, onSelected: (v) => _set(_f.copyWith(likely: v))),
      ]),
      Row(children: [
        Expanded(
          child: DropdownButton<String>(
            key: const Key('sites-town'),
            isExpanded: true,
            value: _f.town,
            hint: Text('All towns (${towns.length})'),
            items: [
              DropdownMenuItem<String>(value: null, child: Text('All towns (${towns.length})')),
              for (final tw in towns) DropdownMenuItem(value: tw.$1, child: Text('${tw.$1} (${tw.$2})')),
            ],
            onChanged: (v) => _set(_f.copyWith(town: v)),
          ),
        ),
      ]),
      Row(children: [
        Expanded(
          child: DropdownButton<SiteSort>(
            key: const Key('sites-sort'),
            isExpanded: true,
            value: _f.sort,
            items: [for (final s in SiteSort.values) if (s != SiteSort.dist || _f.near != null) DropdownMenuItem(value: s, child: Text('Order: ${siteSortLabels[s]}'))],
            onChanged: (s) => s == null ? null : _sort(s),
          ),
        ),
        IconButton(
          key: const Key('sites-dir'),
          tooltip: _f.asc ? 'Ascending' : 'Descending',
          icon: Icon(_f.asc ? Icons.arrow_upward : Icons.arrow_downward),
          onPressed: () => _set(_f.copyWith(asc: !_f.asc)),
        ),
      ]),
      Row(children: [
        TextButton.icon(
          key: const Key('sites-near'),
          onPressed: _f.near == null ? _pickNear : () => _set(_f.copyWith(near: null, sort: SiteSort.value, asc: true)),
          icon: Icon(_f.near == null ? Icons.near_me_outlined : Icons.close),
          label: Text(_f.near == null ? 'Distance from a site…' : 'From ${_f.near!.label}'),
        ),
        const Spacer(),
        SegmentedButton<bool>(
          key: const Key('sites-view'),
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: false, label: Text('List')), ButtonSegment(value: true, label: Text('Map'))],
          selected: {_map},
          onSelectionChanged: (s) => setState(() => _map = s.first),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.s),
        child: Text('${groupInt(rows.length)} of ${groupInt(d.rows.length)} sites', key: const Key('sites-count'), style: t.textTheme.labelLarge),
      ),
      if (_sel.isNotEmpty)
        Card(
          key: const Key('sites-selbar'),
          color: t.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.s),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${_sel.length} selected'),
              FilledButton.tonal(
                key: const Key('sites-compare'),
                onPressed: _sel.length < 2 || _sel.length > 4
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CompareScreen(api: widget.api, data: d, refs: [for (final r in selRows) r.ref]))),
                child: Text(_sel.length < 2 ? 'Compare (2–4)' : (_sel.length > 4 ? 'Compare takes 4' : 'Compare ${_sel.length}')),
              ),
              TextButton(key: const Key('sites-clear-sel'), onPressed: () => setState(_sel.clear), child: const Text('Clear')),
            ]),
          ),
        ),
      if (rows.isEmpty)
        Padding(padding: const EdgeInsets.all(Gap.l), child: Text('No site matches these filters.', key: const Key('sites-empty'), style: t.textTheme.bodyLarge))
      else if (_map)
        planSection(context, 'Map', lead: 'Sites in the regional sequence are filled; the others are rings. The first 300 of the current list are drawn.', children: [
          PlanMap(
            height: 340,
            markers: [
              for (final r in rows.take(300))
                PlanMarker(LatLng(r.lat, r.lon),
                    color: r.seqLikely != null || r.seqPossible != null ? t.colorScheme.primary : (r.joinsMain == true ? t.colorScheme.tertiary : t.colorScheme.outline),
                    ring: r.seqLikely == null && r.seqPossible == null,
                    size: 14),
            ],
          ),
          const SizedBox(height: Gap.s),
          Text('Open a site from the list to see its dossier.', style: t.textTheme.bodySmall),
        ])
      else
        for (final r in shown)
          _SiteTile(
            row: r,
            data: d,
            selected: _sel.contains(r.id),
            dist: distKm(r, _f.near),
            onSelect: (v) => setState(() => v ? _sel.add(r.id) : _sel.remove(r.id)),
            onOpen: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SiteDetailScreen(api: widget.api, ref: r.ref))),
          ),
      if (pages > 1 && !_map)
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton(key: const Key('sites-prev'), onPressed: page > 1 ? () => setState(() => _page = page - 1) : null, child: const Text('Previous')),
          Text('Page $page of $pages'),
          TextButton(key: const Key('sites-next'), onPressed: page < pages ? () => setState(() => _page = page + 1) : null, child: const Text('Next')),
        ]),
      const SizedBox(height: Gap.m),
      Text(
        '${d.meta == null ? '' : '${groupInt(d.meta!.count)} OpenStreetMap places of worship, schools and parks as of ${d.meta!.asOfOsm.length >= 10 ? d.meta!.asOfOsm.substring(0, 10) : d.meta!.asOfOsm} (© OpenStreetMap contributors, ODbL) plus original plan sites without an OSM record. '}'
        'Step = position in the engine\'s Likely+ build sequence (P = Possible+ only). Value today = live repeaters the site joins to the main mesh if built alone, and people it brings newly within ${radiusText(context, 3)}.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    ]);
  }
}

class _SiteTile extends StatelessWidget {
  final SiteRow row;
  final PlanSites data;
  final bool selected;
  final double? dist;
  final ValueChanged<bool> onSelect;
  final VoidCallback onOpen;
  const _SiteTile({required this.row, required this.data, required this.selected, required this.dist, required this.onSelect, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = row;
    final step = c.seqLikely != null ? 'Step ${c.seqLikely}' : (c.seqPossible != null ? 'Possible+ step ${c.seqPossible}' : null);
    final value = c.value == null ? null : '${c.value!.joins > 0 ? '+${c.value!.joins}' : '0'} repeaters, ${groupInt(c.value!.newPeople)} people';
    return Card(
      key: Key('site-${c.id}'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Corners.card),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.s, Gap.m, Gap.s),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Checkbox(key: Key('site-sel-${c.id}'), value: selected, onChanged: (v) => onSelect(v ?? false)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c.planSite != null ? '${c.planSite}  ' : ''}${c.name}', style: t.textTheme.titleSmall),
                Text('${c.sub} · ${c.town}${dist != null ? ' · ${kmText(context, dist!)}' : ''}', style: t.textTheme.bodySmall),
                const SizedBox(height: 2),
                Wrap(spacing: 10, children: [
                  if (step != null) Text(step, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
                  if (value != null) Text(value, style: t.textTheme.labelMedium),
                  if (c.best != null) Text('Best ${c.best!.tier} ${oddsPct(c.best!.odds)} ${basisLabel(c.best!.basis)} to ${data.repeaterName(c.best!.key)}', style: t.textTheme.labelMedium) else Text('No link in ${radiusText(context, 30)}', style: t.textTheme.labelMedium),
                ]),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

class _PlacePicker extends StatefulWidget {
  final List<SiteRow> rows;
  const _PlacePicker({required this.rows});
  @override
  State<_PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<_PlacePicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final hits = [for (final r in widget.rows) if (_q.trim().length >= 2 && matchRow(r, _q)) r].take(20).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, MediaQuery.of(context).viewInsets.bottom + Gap.l),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Sort by distance from…', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.s),
        TextField(key: const Key('place-search'), autofocus: true, decoration: const InputDecoration(hintText: 'Type a site name or town', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _q = v)),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final r in hits) ListTile(key: Key('place-${r.id}'), title: Text(r.name), subtitle: Text(r.town), onTap: () => Navigator.of(context).pop(r)),
          ]),
        ),
      ]),
    );
  }
}
