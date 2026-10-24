// "All regions": the website hub's /regions as a screen. Regions under their group headers with each region's public
// figures, a comparison table sortable by column, and tap-to-switch the viewed region. A region with no drives or whose
// numbers cannot be read is shown with that state, never with zeros.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/region_lookup.dart';
import '../../core/region_stats_api.dart';
import '../app.dart';
import '../widgets.dart';
import 'region_common.dart';
import 'stats_panel.dart' show regionStatsApiFactory;

/// One region with its figures: [stats] null = unavailable (see [failed]).
class RegionFigures {
  final RegionIndexEntry region;
  final RegionPublicStats? stats;
  const RegionFigures(this.region, this.stats);
  bool get hasData => stats != null && !stats!.isEmpty;
}

enum RegionSort { name, km, drives, drivers, pings, heardPct, cellsHeardPct, repeatersHeard }

const _sortLabels = {
  RegionSort.name: 'Name',
  RegionSort.km: 'Km',
  RegionSort.drives: 'Drives',
  RegionSort.drivers: 'Drivers',
  RegionSort.pings: 'Pings',
  RegionSort.heardPct: 'Heard',
  RegionSort.cellsHeardPct: 'Squares',
  RegionSort.repeatersHeard: 'Repeaters',
};

num? _sortValue(RegionFigures f, RegionSort s) {
  final st = f.stats;
  if (st == null || st.isEmpty) return null;
  return switch (s) {
    RegionSort.name => null,
    RegionSort.km => st.km,
    RegionSort.drives => st.drives,
    RegionSort.drivers => st.drivers,
    RegionSort.pings => st.pings,
    RegionSort.heardPct => st.heardPct,
    RegionSort.cellsHeardPct => st.cellsHeardPct,
    RegionSort.repeatersHeard => st.repeatersHeard,
  };
}

/// Sorts for the comparison table: numbers descending (names ascending); regions without numbers go last, by name.
List<RegionFigures> sortFigures(List<RegionFigures> rows, RegionSort by, {bool ascending = false}) {
  final out = [...rows];
  out.sort((a, b) {
    int byName() => a.region.name.toLowerCase().compareTo(b.region.name.toLowerCase());
    if (by == RegionSort.name) return ascending ? byName() : -byName();
    final x = _sortValue(a, by), y = _sortValue(b, by);
    if (x == null && y == null) return byName();
    if (x == null) return 1;
    if (y == null) return -1;
    final c = x.compareTo(y);
    return (ascending ? c : -c) != 0 ? (ascending ? c : -c) : byName();
  });
  return out;
}

Future<void> showRegionsScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RegionsScreen()));

class RegionsScreen extends StatefulWidget {
  /// Test seams.
  final List<RegionIndexEntry>? regions;
  final Future<HubRegions> Function()? loadGroups;
  final String? viewingCode;
  final void Function(RegionIndexEntry)? onPick;
  const RegionsScreen({super.key, this.regions, this.loadGroups, this.viewingCode, this.onPick});

  @override
  State<RegionsScreen> createState() => _RegionsScreenState();
}

class _RegionsScreenState extends State<RegionsScreen> {
  Map<String, RegionFigures> _figures = {};
  HubRegions _hub = const HubRegions();
  bool _loading = true;
  RegionSort _sort = RegionSort.km;
  bool _asc = false;
  int _gen = 0;
  bool _started = false;

  List<RegionIndexEntry> _regions(BuildContext context) => widget.regions ?? AppScope.read(context).regionIndex;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load(_regions(context)));
  }

  Future<void> _load(List<RegionIndexEntry> regions) async {
    final gen = ++_gen;
    setState(() => _loading = true);
    final hubF = (widget.loadGroups ?? _defaultGroups)().catchError((_) => const HubRegions());
    final figs = await Future.wait([
      for (final r in regions)
        () async {
          final api = regionStatsApiFactory(r.url);
          try {
            return RegionFigures(r, await api.stats());
          } catch (_) {
            return RegionFigures(r, null);
          } finally {
            api.close();
          }
        }(),
    ]);
    final hub = await hubF;
    if (!mounted || gen != _gen) return;
    setState(() {
      _figures = {for (final f in figs) f.region.code: f};
      _hub = hub;
      _loading = false;
    });
  }

  Future<HubRegions> _defaultGroups() async {
    final api = regionStatsApiFactory(AppScope.read(context).settings.serverUrl);
    try {
      return await api.hubRegions();
    } finally {
      api.close();
    }
  }

  void _open(RegionIndexEntry r) {
    if (widget.onPick != null) {
      widget.onPick!(r);
      return;
    }
    final nav = Navigator.of(context);
    unawaited(AppScope.read(context).setViewingRegion(r.code));
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final regions = _regions(context);
    final viewing = widget.regions != null ? widget.viewingCode : AppScope.read(context).viewingRegion?.code;
    return Scaffold(
      appBar: AppBar(
        title: const Text('All regions'),
        actions: [IconButton(tooltip: 'Refresh', onPressed: _loading ? null : () => unawaited(_load(regions)), icon: const Icon(Icons.refresh))],
      ),
      body: regions.isEmpty
          ? const EmptyState(icon: Icons.map_outlined, title: 'No regions loaded yet', body: 'Connect to the internet once and they are remembered.')
          : ListView(
              key: const Key('regions-screen'),
              padding: const EdgeInsets.all(12),
              children: [
                if (_loading) const LinearProgressIndicator(key: Key('regions-loading')),
                ..._groupedList(context, regions, viewing),
                if (!_loading && regions.length > 1) ..._compare(context, regions, viewing),
              ],
            ),
    );
  }

  List<Widget> _groupedList(BuildContext context, List<RegionIndexEntry> regions, String? viewing) {
    final t = Theme.of(context);
    final sorted = [...regions]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final out = <Widget>[];
    // Group headers first (in group order), then regions that belong to no group.
    for (final g in _hub.groups) {
      final members = [for (final r in sorted) if (_hub.groupOf[r.code] == g.code) r];
      if (members.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, Gap.m, 4, Gap.xs),
        child: Text(g.name, key: Key('regions-group-${g.code}'), style: t.textTheme.titleMedium),
      ));
      out.addAll([for (final r in members) _tile(context, r, viewing)]);
    }
    final loose = [for (final r in sorted) if (!_hub.groupOf.containsKey(r.code)) r];
    if (loose.isNotEmpty) {
      if (_hub.groups.isNotEmpty) {
        out.add(Padding(padding: const EdgeInsets.fromLTRB(4, Gap.m, 4, Gap.xs), child: Text('Other regions', style: t.textTheme.titleMedium)));
      }
      out.addAll([for (final r in loose) _tile(context, r, viewing)]);
    }
    return out;
  }

  String _figureLine(RegionFigures? f) {
    if (_loading && f == null) return 'Loading numbers…';
    if (f == null || f.stats == null) return 'Numbers unavailable right now';
    final s = f.stats!;
    if (s.isEmpty) return 'No drives yet';
    return '${s.km == null ? '—' : groupInt(s.km!.round())} km · ${s.drives == null ? '—' : groupInt(s.drives!)} drives · '
        '${s.drivers == null ? '—' : groupInt(s.drivers!)} drivers · ${s.repeatersHeard == null ? '—' : groupInt(s.repeatersHeard!)} repeaters heard';
  }

  Widget _tile(BuildContext context, RegionIndexEntry r, String? viewing) {
    final isViewing = r.code == viewing;
    return Card(
      child: ListTile(
        key: Key('regions-tile-${r.code}'),
        title: Text(r.name),
        subtitle: Text('${r.code} · ${_figureLine(_figures[r.code])}'),
        trailing: isViewing ? const Chip(label: Text('Viewing')) : const Icon(Icons.chevron_right),
        onTap: () => _open(r),
      ),
    );
  }

  List<Widget> _compare(BuildContext context, List<RegionIndexEntry> regions, String? viewing) {
    final t = Theme.of(context);
    final rows = sortFigures([for (final r in regions) _figures[r.code] ?? RegionFigures(r, null)], _sort, ascending: _asc);
    String n(num? v) => v == null ? '—' : groupInt(v.round());
    String p(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';
    return [
      Padding(padding: const EdgeInsets.fromLTRB(4, Gap.l, 4, Gap.xs), child: Text('Compare regions', style: t.textTheme.titleMedium)),
      Wrap(spacing: Gap.xs, children: [
        for (final s in RegionSort.values)
          ChoiceChip(
            key: Key('regions-sort-${s.name}'),
            label: Text(_sortLabels[s]! + (s == _sort ? (_asc ? ' ▲' : ' ▼') : '')),
            selected: s == _sort,
            onSelected: (_) => setState(() {
              if (s == _sort) {
                _asc = !_asc;
              } else {
                _sort = s;
                _asc = s == RegionSort.name;
              }
            }),
          ),
      ]),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          key: const Key('regions-compare'),
          columnSpacing: 16,
          columns: const [
            DataColumn(label: Text('Region')),
            DataColumn(label: Text('Km'), numeric: true),
            DataColumn(label: Text('Drives'), numeric: true),
            DataColumn(label: Text('Drivers'), numeric: true),
            DataColumn(label: Text('Pings'), numeric: true),
            DataColumn(label: Text('Heard'), numeric: true),
            DataColumn(label: Text('Squares'), numeric: true),
            DataColumn(label: Text('Repeaters'), numeric: true),
          ],
          rows: [
            for (final f in rows)
              DataRow(
                selected: f.region.code == viewing,
                onSelectChanged: (_) => _open(f.region),
                cells: f.hasData
                    ? [
                        DataCell(Text(f.region.name)),
                        DataCell(Text(n(f.stats!.km))),
                        DataCell(Text(n(f.stats!.drives))),
                        DataCell(Text(n(f.stats!.drivers))),
                        DataCell(Text(n(f.stats!.pings))),
                        DataCell(Text(p(f.stats!.heardPct))),
                        DataCell(Text(p(f.stats!.cellsHeardPct))),
                        DataCell(Text(n(f.stats!.repeatersHeard))),
                      ]
                    : [
                        DataCell(Text(f.region.name)),
                        DataCell(Text(f.stats == null ? 'unavailable' : 'no drives yet')),
                        for (var i = 0; i < 6; i++) const DataCell(Text('')),
                      ],
              ),
          ],
        ),
      ),
    ];
  }
}
