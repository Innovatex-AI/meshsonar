// Plan > Site explorer > one site: where it sits in the engine's build sequence, what it adds, its links to live repeaters (with the
// lidar / tree-estimate / terrain basis), the map, and the other sites within 2 km. An original plan site also carries its host,
// address, rationale and what to verify; a candidate its OpenStreetMap record. A link opens its terrain profile.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/plan/plan_candidate.dart';
import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_overview.dart';
import '../../core/plan/plan_sites.dart';
import '../../core/plan/planner_query.dart';
import '../../core/region_dataset_fetch.dart';
import '../app.dart';
import 'link_screen.dart';
import 'plan_common.dart';
import 'planner_screen.dart';
import 'scenarios_screen.dart';

class SiteBundle {
  final PlanSites sites;
  final PlanOverview? overview;
  final CandidateDetail? candidate;
  const SiteBundle(this.sites, this.overview, this.candidate);
}

class SiteDetailScreen extends StatelessWidget {
  final PlanNativeApi? api;

  /// A plan id (`D2`), `c:<osm id>`, or a row id.
  final String ref;
  const SiteDetailScreen({super.key, this.api, required this.ref});

  Future<RegionFetch<SiteBundle>> _load(PlanNativeApi a) async {
    final s = await a.sites();
    if (!s.ok) return RegionFetch.fail(s.error ?? 'Could not load the sites.', notFound: s.notFound, status: s.status);
    final o = await a.overview();
    final row = s.data!.byRef(ref);
    CandidateDetail? cand;
    if (row?.candId != null) {
      final c = await a.candidate(row!.candId!);
      cand = c.data;
    }
    return RegionFetch.ok(SiteBundle(s.data!, o.data, cand), offlineAsOf: s.offlineAsOf);
  }

  @override
  Widget build(BuildContext context) {
    final a = api ?? planApiFor(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Site')),
      body: SafeArea(
        top: false,
        child: PlanFetchView<SiteBundle>(
          id: 'site',
          load: () => _load(a),
          reloadKey: '${a.baseUrl}|$ref',
          available: (b) => b.sites.byRef(ref) != null,
          unavailableText: (b) => 'No site has the reference “$ref”.',
          build: (context, b, reload) => _Body(api: a, bundle: b, ref: ref),
        ),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  final PlanNativeApi api;
  final SiteBundle bundle;
  final String ref;
  const _Body({required this.api, required this.bundle, required this.ref});
  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  int _h = 33;

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    final t = Theme.of(context);
    final row = b.sites.byRef(widget.ref)!;
    final plan = row.planSite == null ? null : b.overview?.site(row.planSite!);
    final lines = <PlanLine>[];
    final markers = <PlanMarker>[PlanMarker(LatLng(row.lat, row.lon), color: t.colorScheme.primary, size: 24)];
    final m = MeshSonarColors.of(context);
    void addEnd(String? key, double lat, double lon, String tier) {
      markers.add(PlanMarker(LatLng(lat, lon), color: m.beacon, size: 10));
      lines.add(PlanLine(LatLng(row.lat, row.lon), LatLng(lat, lon), tierColor(context, tier).withValues(alpha: 0.8)));
    }

    if (plan != null) {
      for (final l in plan.links) {
        final r = l.toKey == null ? null : b.sites.repeater(l.toKey!);
        final s = r == null ? b.overview?.site(l.to) : null;
        if (r != null) addEnd(r.key, r.lat, r.lon, _h == 33 ? l.tier33 : l.tier20);
        if (s != null) addEnd(null, s.lat, s.lon, _h == 33 ? l.tier33 : l.tier20);
      }
    } else if (b.candidate != null) {
      for (final l in b.candidate!.links.take(12)) {
        final r = b.sites.repeater(l.key);
        if (r != null) addEnd(l.key, r.lat, r.lon, l.treeTier ?? l.terrainTier ?? 'Stretch');
      }
    }
    final alts = nearby(b.sites.rows, row.lat, row.lon, 2, exclude: (c) => c.id == row.id || (row.planSite != null && c.planSite == row.planSite)).take(5).toList();
    return planColumn(key: const Key('site-detail'), [
      planHeader(context, '${row.planSite != null ? '${row.planSite}  ' : ''}${row.name}', plan?.role.isNotEmpty == true ? plan!.role : '${row.sub} · ${row.town}'),
      _facts(context, row, plan, b),
      if (plan != null && plan.rationale.isNotEmpty)
        planSection(context, 'Why here', children: [
          Text(plan.rationale, style: t.textTheme.bodyMedium),
          if (plan.verifyNote.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Verify: ${plan.verifyNote}', style: t.textTheme.bodyMedium)),
        ]),
      planSection(context, 'Links', key: const Key('site-links'), children: [
        if (plan != null)
          SegmentedButton<int>(
            key: const Key('site-height'),
            segments: [ButtonSegment(value: 20, label: Text(mountName(20))), ButtonSegment(value: 33, label: Text(mountName(33)))],
            selected: {_h},
            onSelectionChanged: (s) => setState(() => _h = s.first),
          ),
        const SizedBox(height: Gap.s),
        if (plan != null) ..._planLinks(context, plan, b) else if (b.candidate != null) ..._candLinks(context, b.candidate!, b) else Text('No modelled links for this site.', style: t.textTheme.bodyMedium),
        PlanMap(markers: markers, lines: lines, height: 260),
      ]),
      planSection(context, 'Other sites within ${radiusText(context, 2)}', key: const Key('site-alts'), children: [
        if (alts.isEmpty) Text('No other site within ${radiusText(context, 2)}.'),
        for (final (c, km) in alts)
          ListTile(
            key: Key('alt-${c.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text('${c.planSite != null ? '${c.planSite}  ' : ''}${c.name}'),
            subtitle: Text('${kmText(context, km)} · ${c.sub}${c.seqLikely != null ? ' · step ${c.seqLikely}' : ''}${c.best != null ? ' · best ${c.best!.tier}' : ''}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SiteDetailScreen(api: widget.api, ref: c.ref))),
          ),
      ]),
      planSection(context, 'Use this site', children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            key: const Key('site-ask-planner'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlannerScreen(api: widget.api, initial: PlannerQuery(include: [if (row.planSite != null && row.candId == null) 'site:${row.planSite}' else row.id])))),
            icon: const Icon(Icons.edit_road_outlined),
            label: const Text('Plan with this site'),
          ),
          if (plan != null)
            FilledButton.tonalIcon(
              key: const Key('site-scenario'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ScenariosScreen(api: widget.api, initialSites: [plan.id]))),
              icon: const Icon(Icons.tune),
              label: const Text('Try it in a scenario'),
            ),
        ]),
      ]),
    ]);
  }

  Widget _facts(BuildContext context, SiteRow row, PlanOriginalSite? plan, SiteBundle b) {
    final t = Theme.of(context);
    String? seqText() {
      final runs = b.overview?.runs ?? const <String, PlanRun>{};
      final parts = <String>[];
      for (final r in runs.values) {
        for (final p in r.phases) {
          for (final g in p.groups) {
            for (final s in g.sites) {
              if (s.id == row.id || (row.planSite != null && s.planSite == row.planSite)) {
                parts.add('${r.label}: step ${g.ordFrom}${g.isPair ? ' (a linked pair)' : ''} of ${r.totalSites}, ${p.name} phase; takes the main mesh to ${g.mainMesh} and ${groupInt(g.people)} people within ${radiusText(context, 3)}');
              }
            }
          }
        }
      }
      return parts.isEmpty ? null : parts.join('\n');
    }

    Widget fact(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 130, child: Text(k, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
            Expanded(child: Text(v, style: t.textTheme.bodyMedium)),
          ]),
        );
    final c = b.candidate;
    final seq = seqText();
    return planSection(context, 'At a glance', key: const Key('site-facts'), children: [
      fact('Build sequence', seq ?? 'Not in the engine\'s recommended sequence'),
      if (row.value != null) fact('Value today', 'Built alone it would join ${row.value!.joins} live repeater${row.value!.joins == 1 ? '' : 's'} to the main mesh and bring ${groupInt(row.value!.newPeople)} people newly within ${radiusText(context, 3)} (Likely+).'),
      fact('Tree cover', row.canopy150 == null ? 'Not loaded' : '${pct0(row.canopy150)} within ${radiusText(context, 0.15)}${c?.canopy1k != null ? ', ${pct0(c!.canopy1k)} within ${radiusText(context, 1)}' : ''}'),
      if (plan != null) ...[
        fact('Original plan', 'Wave ${plan.wave}, phase ${plan.phase} ${plan.phaseName}'),
        fact('Area', plan.area),
        fact('Address', plan.address),
        fact('Host type', plan.hostType),
        fact('Likely+ links, ${mountName(33)}', '${plan.linksLikelyPlus33} (Possible+ ${plan.linksPossiblePlus20} at ${mountName(20)}, ${plan.linksPossiblePlus33} at ${mountName(33)})'),
        fact('New people', '${groupInt(plan.newPeople2)} within ${radiusText(context, 2)}, ${groupInt(plan.newPeople3)} within ${radiusText(context, 3)}, ${groupInt(plan.newPeople5)} within ${radiusText(context, 5)}'),
        if (b.overview?.strandedAfterWave(plan) != null) fact('If lost', '${b.overview!.strandedAfterWave(plan)} node${b.overview!.strandedAfterWave(plan) == 1 ? '' : 's'} stranded after Wave ${plan.wave} (${mountName(33)}, Likely+)'),
        fact('Ground', '${heightText(context, plan.groundElevM)}${plan.usgsElevM != null ? ', USGS ${heightText(context, plan.usgsElevM!)}' : ''}'),
        if (plan.poleTop) fact('Mount', 'Pole-top mount is a priority here'),
      ] else ...[
        fact('Type', '${row.sub}${c?.denomination != null ? ' (${c!.denomination})' : ''}'),
        fact('Place', c?.place.isNotEmpty == true ? c!.place : row.town),
        if (c != null) fact('People within ${radiusText(context, 3)}', '${groupInt(c.pop3)} (${groupInt(c.gap3)} not already within ${radiusText(context, 3)} of a live repeater)'),
        fact('Ground', '${heightText(context, row.elevM)}${c != null ? ', prominence ${heightText(context, c.promM)}' : ''}'),
        if (c != null) fact('Pre-score', '${c.score.round()} of 100 (rank ${groupInt(c.rank)}), terrain only'),
        if (c?.osm != null) fact('Source', '© OpenStreetMap contributors, ODbL (${c!.osm})'),
      ],
      fact('Coordinates', '${row.lat.toStringAsFixed(5)}, ${row.lon.toStringAsFixed(5)}'),
    ]);
  }

  List<Widget> _planLinks(BuildContext context, PlanOriginalSite plan, SiteBundle b) {
    final t = Theme.of(context);
    final links = [...plan.links]..sort((x, y) => (_h == 33 ? y.odds33 : y.odds20).compareTo(_h == 33 ? x.odds33 : x.odds20));
    return [
      for (final l in links)
        ListTile(
          key: Key('link-${l.to}'),
          contentPadding: EdgeInsets.zero,
          title: Text(l.toKey != null ? (b.sites.repeater(l.toKey!)?.name ?? l.toName) : '${l.to} ${l.toName}'),
          subtitle: Text('${kmText(context, l.km)} · ${oddsPct(_h == 33 ? l.odds33 : l.odds20)} · trees on the line ${AppScope.unitsOf(context).distance(_h == 33 ? l.treeM33 : l.treeM20)}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [TierChip(_h == 33 ? l.tier33 : l.tier20), const Icon(Icons.chevron_right)]),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LinkScreen(api: widget.api, a: plan.id, b: l.to))),
        ),
      if (links.isEmpty) Text('No scored links.', style: t.textTheme.bodyMedium),
      Text('Lidar-model tiers. Tap a link for its terrain profile.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ];
  }

  List<Widget> _candLinks(BuildContext context, CandidateDetail c, SiteBundle b) {
    final t = Theme.of(context);
    return [
      for (final l in c.links.take(25))
        ListTile(
          key: Key('link-${l.key}'),
          contentPadding: EdgeInsets.zero,
          title: Text(b.sites.repeaterName(l.key)),
          subtitle: Text(
            '${kmText(context, l.km)} · ${l.treeOdds != null ? '${oddsPct(l.treeOdds!)} ${basisLabel(l.treeBasis ?? 'trees')}${l.treeM != null ? ', trees ${AppScope.unitsOf(context).distance(l.treeM!)}' : ''}' : 'no tree-adjusted odds'}'
            '${l.terrainOdds != null ? ' · terrain only ${oddsPct(l.terrainOdds!)}' : ''}',
          ),
          trailing: TierChip(l.treeTier ?? l.terrainTier ?? 'Stretch'),
        ),
      if (c.links.isEmpty) Text('No modelled links to live repeaters within ${radiusText(context, 30)}.', style: t.textTheme.bodyMedium),
      Text('Odds at ${mountName(33)} to live repeaters at ${heightText(context, 8)}. lidar = tree depth measured on USGS 3DEP point clouds; est. = estimated from ESA WorldCover; terrain = no trees.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ];
  }
}
