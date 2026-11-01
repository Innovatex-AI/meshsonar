// Plan > Scenarios, native: tick original plan sites (or start from a preset), pick a mount height, a link tier and a people radius, and see
// what the mesh would become: live repeaters in the main mesh, pieces, people within reach, single points of failure and what each site
// is worth. Every figure is computed by the website's own scenario code on the server (plan-native?view=scenario) and shown against today.
// "Pin" keeps a scenario to compare the next one with; "Plan next sites" hands the selection to the Planner.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_scenario.dart';
import '../../core/plan/plan_sites.dart' show groupInt;
import '../../core/plan/planner_query.dart';
import '../../core/region_dataset_fetch.dart';
import '../theme.dart';
import 'plan_engine_common.dart';
import 'planner_screen.dart';

class ScenariosScreen extends StatefulWidget {
  final PlanNativeApi? api;

  /// Sites ticked at the start; null = the recommended build (waves 1 and 2).
  final List<String>? initialSites;
  const ScenariosScreen({super.key, this.api, this.initialSites});
  @override
  State<ScenariosScreen> createState() => _ScenariosScreenState();
}

class _Pin {
  final String label;
  final ScenarioFigures f;
  const _Pin(this.label, this.f);
}

class _ScenariosScreenState extends State<ScenariosScreen> {
  List<String>? _sites;
  int _h = 33;
  String _tier = 'likely';
  double _r = 3;
  bool _live = false;
  RegionFetch<ScenarioResult>? _res;
  ScenarioResult? _last;
  bool _loading = true;
  Timer? _debounce;
  int _seq = 0;
  _Pin? _pin;

  @override
  void initState() {
    super.initState();
    _sites = widget.initialSites;
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _change(VoidCallback f) {
    setState(f);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _fetch);
  }

  Future<void> _fetch() async {
    if (!mounted) return;
    final api = widget.api ?? planApiFor(context);
    final mine = ++_seq;
    setState(() => _loading = true);
    final r = await api.scenario(sites: _sites, h: _h, tier: _tier, r: _r, live: _live);
    if (!mounted || mine != _seq) return;
    setState(() {
      _res = r;
      if (r.ok && r.data!.available) {
        _last = r.data;
        _sites ??= r.data!.sites;
      }
      _loading = false;
    });
  }

  String _label(BuildContext context, ScenarioResult s) => '${s.network == 'live' ? 'Live network, ' : ''}${s.sites.length} site${s.sites.length == 1 ? '' : 's'}, ${mountName(s.h)}, ${s.tier == 'likely' ? 'Likely+' : 'Possible+'}, ${radiusText(context, s.r)}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _res;
    final d = _last;
    Widget body;
    if (f != null && !f.ok && d == null) {
      body = Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Row(key: const Key('scn-error'), children: [
          const Icon(Icons.cloud_off),
          const SizedBox(width: Gap.m),
          Expanded(child: Text('Scenarios could not load. ${f.error ?? ''}')),
          TextButton(onPressed: _fetch, child: const Text('Retry')),
        ]),
      );
    } else if (d == null) {
      body = _loading ? const Center(key: Key('scn-loading'), child: CircularProgressIndicator()) : const SizedBox.shrink();
    } else if (f != null && f.ok && !f.data!.available) {
      body = Padding(padding: const EdgeInsets.all(Gap.l), child: Text(f.data!.reason ?? 'No planning data for this region yet.', key: const Key('scn-unavailable')));
    } else {
      body = planColumn(key: const Key('scn-list'), [
        planHeader(context, 'Scenarios', 'Toggle sites, heights and link tiers and see what the mesh would become.'),
        if (f != null && !f.ok) Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text('Could not refresh: ${f.error}. Showing the last figures.', key: const Key('scn-stale'), style: t.textTheme.bodySmall)),
        _controls(context, d),
        _results(context, d),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Scenarios'), bottom: _loading && d != null ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _controls(BuildContext context, ScenarioResult d) {
    final t = Theme.of(context);
    final sites = _sites ?? d.sites;
    bool same(List<String> a) => a.length == sites.length && a.every(sites.contains);
    return planSection(context, 'Scenario', key: const Key('scn-controls'), children: [
      SegmentedButton<bool>(
        key: const Key('scn-net'),
        segments: [
          const ButtonSegment(value: false, label: Text('Frozen baseline')),
          ButtonSegment(value: true, label: const Text('Live network'), enabled: d.liveAvailable || _live),
        ],
        selected: {_live},
        onSelectionChanged: (s) => _change(() => _live = s.first),
      ),
      if (!d.liveAvailable) Padding(padding: const EdgeInsets.only(top: 4), child: Text('The live network needs a stored living plan, which this region does not have yet.', style: t.textTheme.bodySmall)),
      const SizedBox(height: Gap.s),
      Text('Presets', style: t.textTheme.labelLarge),
      Wrap(spacing: 8, children: [
        for (final p in d.presets)
          ChoiceChip(key: Key('scn-preset-${p.id}'), label: Text(p.label), tooltip: '${p.detail}: ${p.sites.isEmpty ? 'no sites' : p.sites.join(', ')}', selected: same(p.sites), onSelected: (_) => _change(() => _sites = [...p.sites])),
      ]),
      const SizedBox(height: Gap.s),
      // Natural widths that wrap, not two half-width cells ("33 ft" and "Likely+" broke mid-word on a phone).
      Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
        SegmentedButton<int>(
          key: const Key('scn-height'),
          showSelectedIcon: false,
          segments: [ButtonSegment(value: 20, label: Text(mountName(20))), ButtonSegment(value: 33, label: Text(mountName(33)))],
          selected: {_h},
          onSelectionChanged: (s) => _change(() => _h = s.first),
        ),
        SegmentedButton<String>(
          key: const Key('scn-tier'),
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: 'possible', label: Text('Possible+')), ButtonSegment(value: 'likely', label: Text('Likely+'))],
          selected: {_tier},
          onSelectionChanged: (s) => _change(() => _tier = s.first),
        ),
      ]),
      Text('Population radius: ${radiusText(context, _r)}', style: t.textTheme.labelLarge),
      Slider(key: const Key('scn-radius'), min: 2, max: 5, divisions: 6, value: _r, label: radiusText(context, _r), onChanged: (v) => _change(() => _r = v)),
      const SizedBox(height: Gap.s),
      Text('Sites (${sites.length} of ${d.sitesList.length})', style: t.textTheme.labelLarge),
      Text('Right column: live repeaters each site adds to the main mesh if ticked, or holds in it if ticked already; people when it joins none.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      for (final w in d.waves) ...[
        Row(children: [
          Expanded(child: Text(w.name, style: t.textTheme.titleSmall)),
          TextButton(
            key: Key('scn-wave-${w.wave}'),
            onPressed: () => _change(() {
              final all = w.sites.every(sites.contains);
              _sites = all ? sites.where((x) => !w.sites.contains(x)).toList() : {...sites, ...w.sites}.toList();
            }),
            child: Text(w.sites.every(sites.contains) ? 'None' : 'All'),
          ),
        ]),
        for (final id in w.sites) _siteTile(context, d, id, sites),
      ],
    ]);
  }

  Widget _siteTile(BuildContext context, ScenarioResult d, String id, List<String> sites) {
    final s = d.sitesList.where((x) => x.id == id).firstOrNull;
    if (s == null) return const SizedBox.shrink();
    final m = d.marginal(id);
    String tag = '·';
    if (m != null) {
      tag = m.dMain != 0 ? '${m.on ? '' : '+'}${m.dMain}' : (m.dPeople != 0 ? '${m.on ? '' : '+'}${groupInt(m.dPeople)} people' : '0');
    }
    return CheckboxListTile(
      key: Key('scn-site-$id'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: sites.contains(id),
      onChanged: (v) => _change(() => _sites = v == true ? [...sites, id] : sites.where((x) => x != id).toList()),
      title: Text('$id  ${s.name}', maxLines: 2),
      subtitle: s.poleTop ? const Text('Pole-top mount priority') : null,
      secondary: Text(tag, key: Key('scn-marg-$id')),
    );
  }

  Widget _results(BuildContext context, ScenarioResult d) {
    final t = Theme.of(context);
    final r = d.result, today = d.today;
    String delta(int n, {bool lowerBetter = false}) => '${signedInt(n)} vs today';
    final markers = <PlanMarker>[];
    final lines = <PlanLine>[];
    final m = MeshSonarColors.of(context);
    for (final x in d.repeaters) {
      markers.add(PlanMarker(LatLng(x.lat, x.lon), color: x.inMain ? m.beacon : t.colorScheme.error, ring: !x.inMain, size: x.inMain ? 10 : 12));
    }
    for (final s in d.sitesList.where((s) => d.sites.contains(s.id))) {
      markers.add(PlanMarker(LatLng(s.lat, s.lon), label: s.id, color: t.colorScheme.primary, size: 26));
    }
    for (final l in d.addedLinks) {
      if (l.aLat != null && l.bLat != null) lines.add(PlanLine(LatLng(l.aLat!, l.aLon!), LatLng(l.bLat!, l.bLon!), tierColor(context, l.tier).withValues(alpha: 0.85), width: 2));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(key: const Key('scn-figures'), spacing: 8, runSpacing: 8, children: [
        PlanFigure('Live repeaters in the main mesh', '${r.mainMesh} of ${d.repeaterCount}', hint: delta(r.mainMesh - today.mainMesh)),
        PlanFigure('Pieces', '${r.pieces.length}', hint: '${r.pieces.take(6).join(', ')}${r.pieces.length > 6 ? ', …' : ''}'),
        PlanFigure('People within ${radiusText(context, d.r)}', groupInt(r.people), hint: delta(r.people - today.people)),
        PlanFigure('Single points of failure', r.spof == null ? 'Too many to count' : '${r.spof}', hint: r.spof == null || today.spof == null ? null : delta(r.spof! - today.spof!)),
        if (d.baseline != null) PlanFigure('Frozen baseline', '${d.baseline!.mainMesh} in main mesh', hint: '${groupInt(d.baseline!.people)} people'),
      ]),
      const SizedBox(height: Gap.s),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          key: const Key('scn-pin'),
          onPressed: () => setState(() => _pin = _pin == null ? _Pin(_label(context, d), r) : null),
          icon: Icon(_pin == null ? Icons.push_pin_outlined : Icons.push_pin),
          label: Text(_pin == null ? 'Pin to compare' : 'Unpin'),
        ),
        OutlinedButton.icon(
          key: const Key('scn-plan-next'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlannerScreen(api: widget.api, initial: PlannerQuery(start: 'scenario', prebuiltSites: d.sites)))),
          icon: const Icon(Icons.edit_road_outlined),
          label: const Text('Plan next sites'),
        ),
      ]),
      if (_pin != null)
        planSection(context, 'Pinned: ${_pin!.label}', key: const Key('scn-pinned'), children: [
          Text('Main mesh ${_pin!.f.mainMesh} → ${r.mainMesh} (${signedInt(r.mainMesh - _pin!.f.mainMesh)})', style: t.textTheme.bodyMedium),
          Text('Pieces ${_pin!.f.pieces.length} → ${r.pieces.length}', style: t.textTheme.bodyMedium),
          Text('People ${groupInt(_pin!.f.people)} → ${groupInt(r.people)} (${signedInt(r.people - _pin!.f.people)})', style: t.textTheme.bodyMedium),
          if (_pin!.f.spof != null && r.spof != null) Text('Single points of failure ${_pin!.f.spof} → ${r.spof}', style: t.textTheme.bodyMedium),
        ]),
      const SizedBox(height: Gap.m),
      planSection(context, 'On the map', lead: 'Filled dots are live repeaters in the main mesh; rings are outside it. Numbered dots are the ticked sites; lines are the links they add.', children: [
        PlanMap(markers: markers, lines: lines, height: 320),
        if (d.outside.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Outside the main mesh: ${d.outside.map((o) => '${o.$2} in ${o.$1}').join(', ')}.', style: t.textTheme.bodySmall)),
      ]),
      if (d.network == 'live' && (d.liveAdded.isNotEmpty || d.liveRemoved.isNotEmpty))
        planSection(context, 'Live network changes', key: const Key('scn-live-changes'), children: [
          if (d.liveAdded.isNotEmpty) Text('New since the baseline: ${d.liveAdded.join(', ')}.', style: t.textTheme.bodyMedium),
          if (d.liveRemoved.isNotEmpty) Text('Gone quiet: ${d.liveRemoved.join(', ')}.', style: t.textTheme.bodyMedium),
        ]),
      planSection(context, 'Single points of failure', key: const Key('scn-spof'), lead: 'Nodes whose loss strands the most others from the main mesh.', children: [
        if (d.spofTop.isEmpty) Text(r.spof == null ? 'Too many nodes to test one by one here.' : 'None: no single node strands another.', style: t.textTheme.bodyMedium),
        for (final s in d.spofTop) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(s.name), trailing: Text('${s.stranded} stranded'), subtitle: s.isSite ? const Text('Proposed site') : null),
      ]),
      planSection(context, 'Links the ticked sites add', key: const Key('scn-links'), children: [
        if (d.addedLinks.isEmpty) const Text('No links added at this height and tier.'),
        for (final l in d.addedLinks.take(30)) ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('${l.a} → ${l.b}'), subtitle: Text('${kmText(context, l.km)} · ${oddsPct(l.odds)}'), trailing: TierChip(l.tier)),
      ]),
      Text('Every figure comes from the website\'s scenario code against ${d.network == 'live' ? 'the live network' : 'the frozen baseline'}${d.asOf != null ? ' as of ${d.asOf!.substring(0, 10)}' : ''}. People are a reach proxy from 2020 Census block groups, not a user count.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}
