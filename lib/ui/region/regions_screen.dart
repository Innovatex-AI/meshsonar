// "All regions": the website hub's /regions as a screen. Regions under their group headers with each region's public
// figures, a comparison table sortable by column, and tap-to-switch the viewed region. A region with no drives or whose
// numbers cannot be read is shown with that state, never with zeros.
//
// Figures: ONE read of `regions-figures` (the server's cached numbers for every active region) fills the whole list. Only
// when the server does not have that read (an older one, HTTP 404, or any other failure) does the screen fall back to the
// polite per-region reads of the earlier versions (rows on screen only, a few at a time, paused on a 429). A 429 on the
// single read waits and asks again; it never turns into 559 requests.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../core/region_lookup.dart';
import '../../core/region_search.dart';
import '../../core/region_stats_api.dart';
import '../../core/units.dart';
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

/// FALLBACK ONLY (a server without `regions-figures`): how many regions' figures are read at once, and how long a lane
/// waits between two reads. 559 regions each have their own host and the public reads are limited per IP (300/min);
/// only the rows on screen are read, newest first.
const int regionFigureLanes = 3;
const Duration regionFigureGap = Duration(milliseconds: 450);

/// A pause after a 429 before the next read.
const Duration regionFigurePause = Duration(seconds: 45);

/// The compare table lists at most this many regions (the biggest by the chosen column, among those read so far).
const int regionCompareRows = 25;

class RegionsScreen extends StatefulWidget {
  /// Test seams.
  final List<RegionIndexEntry>? regions;
  final Future<HubRegions> Function()? loadGroups;

  /// The one-read figures for every region (default: `regions-figures` on the app's server).
  final Future<RegionsFigures> Function()? loadFigures;
  final String? viewingCode;
  final void Function(RegionIndexEntry)? onPick;
  final int lanes;
  final Duration gap;
  final Duration pause;
  const RegionsScreen({
    super.key,
    this.regions,
    this.loadGroups,
    this.loadFigures,
    this.viewingCode,
    this.onPick,
    this.lanes = regionFigureLanes,
    this.gap = regionFigureGap,
    this.pause = regionFigurePause,
  });

  @override
  State<RegionsScreen> createState() => _RegionsScreenState();
}

sealed class _Item {
  const _Item();
}

class _Header extends _Item {
  final String key, label;
  const _Header(this.key, this.label);
}

class _Tile extends _Item {
  final RegionIndexEntry region;
  const _Tile(this.region);
}

/// Where the figures come from: not decided yet (the one read is in flight or backing off), the one read, or per region.
enum _FigureMode { pending, bulk, perRegion }

class _RegionsScreenState extends State<RegionsScreen> {
  _FigureMode _mode = _FigureMode.pending;
  DateTime? _figuresAsOf;
  final Map<String, RegionFigures> _figures = {};
  final Set<String> _asked = {};
  final LinkedHashSet<RegionIndexEntry> _queue = LinkedHashSet<RegionIndexEntry>();
  HubRegions _hub = const HubRegions();
  RegionSort _sort = RegionSort.km;
  bool _asc = false;
  int _gen = 0;
  int _lanesBusy = 0;
  DateTime? _pausedUntil;
  bool _started = false;
  bool _paused = false;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  List<RegionIndexEntry>? _itemsFor;
  HubRegions? _itemsHub;
  String _itemsQuery = '';
  List<_Item> _items = const [];

  List<RegionIndexEntry> _regions(BuildContext context) => widget.regions ?? AppScope.read(context).regionIndex;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_loadGroups());
    unawaited(_loadFigures());
  }

  final Set<Timer> _timers = {};

  void _later(Duration d, void Function() f) {
    late final Timer t;
    t = Timer(d, () {
      _timers.remove(t);
      f();
    });
    _timers.add(t);
  }

  @override
  void dispose() {
    _gen++;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _queue.clear();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadGroups() async {
    final gen = _gen;
    HubRegions hub;
    try {
      hub = await (widget.loadGroups ?? _defaultGroups)();
    } catch (_) {
      hub = const HubRegions();
    }
    if (!mounted || gen != _gen) return;
    setState(() => _hub = hub);
  }

  Future<HubRegions> _defaultGroups() async {
    final api = regionStatsApiFactory(AppScope.read(context).settings.serverUrl);
    try {
      return await api.hubRegions();
    } finally {
      api.close();
    }
  }

  // ---- figures: one read for all regions; per-region reads only as the fallback ----

  Future<RegionsFigures> _defaultFigures() async {
    final api = regionStatsApiFactory(AppScope.read(context).settings.serverUrl);
    try {
      return await api.regionsFigures();
    } finally {
      api.close();
    }
  }

  Future<void> _loadFigures() async {
    final gen = _gen;
    final RegionsFigures f;
    try {
      f = await (widget.loadFigures ?? _defaultFigures)();
    } on RegionStatsException catch (e) {
      if (!mounted || gen != _gen) return;
      if (e.status == 429) {
        // Asked too often: wait, then ask the same single question again.
        setState(() {
          _paused = true;
          _pausedUntil = DateTime.now().add(widget.pause);
        });
        _later(widget.pause, () {
          if (!mounted || gen != _gen) return;
          setState(() {
            _pausedUntil = null;
            _paused = false;
          });
          unawaited(_loadFigures());
        });
        return;
      }
      _fallBackToRows();
      return;
    } catch (_) {
      if (mounted && gen == _gen) _fallBackToRows();
      return;
    }
    if (!mounted || gen != _gen) return;
    final regions = _regions(context);
    setState(() {
      _mode = _FigureMode.bulk;
      _figuresAsOf = f.asOf;
      _queue.clear();
      for (final r in regions) {
        // A region the answer does not mention is shown as unavailable: never a zero, and never 559 more requests.
        _figures[r.code] = RegionFigures(r, f.byCode[r.code]);
        _asked.add(r.code);
      }
    });
  }

  void _fallBackToRows() {
    setState(() => _mode = _FigureMode.perRegion);
    _pump();
  }

  /// A tile came on screen: read its figures once (per-region fallback only).
  void _want(RegionIndexEntry r) {
    if (_mode == _FigureMode.bulk || _asked.contains(r.code)) return;
    _queue.remove(r);
    _queue.add(r);
    _pump();
  }

  /// A tile left the screen before its read started: drop it.
  void _unwant(RegionIndexEntry r) => _queue.remove(r);

  void _pump() {
    final gen = _gen;
    if (_mode != _FigureMode.perRegion) return;
    while (_lanesBusy < widget.lanes && _queue.isNotEmpty && _pausedUntil == null) {
      final r = _queue.last; // newest first: what the person is looking at now
      _queue.remove(r);
      _asked.add(r.code);
      _lanesBusy++;
      unawaited(_read(r, gen));
    }
  }

  Future<void> _read(RegionIndexEntry r, int gen) async {
    final api = regionStatsApiFactory(r.url);
    RegionFigures result;
    var rateLimited = false;
    try {
      result = RegionFigures(r, await api.stats());
    } on RegionStatsException catch (e) {
      rateLimited = e.status == 429;
      result = RegionFigures(r, null);
    } catch (_) {
      result = RegionFigures(r, null);
    } finally {
      api.close();
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _lanesBusy--;
      if (rateLimited) {
        _asked.remove(r.code); // read again after the pause
        _queue.add(r);
        _paused = true;
        _pausedUntil = DateTime.now().add(widget.pause);
      } else {
        _figures[r.code] = result;
      }
    });
    if (rateLimited) {
      _later(widget.pause, () {
        if (!mounted || gen != _gen) return;
        setState(() {
          _pausedUntil = null;
          _paused = false;
        });
        _pump();
      });
      return;
    }
    _later(widget.gap, () {
      if (mounted && gen == _gen) _pump();
    });
  }

  void _refresh() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    setState(() {
      _gen++;
      _figures.clear();
      _asked.clear();
      _queue.clear();
      _lanesBusy = 0;
      _pausedUntil = null;
      _paused = false;
      _mode = _FigureMode.pending;
      _figuresAsOf = null;
    });
    unawaited(_loadGroups());
    unawaited(_loadFigures());
  }

  bool get _busy => _mode == _FigureMode.pending || _lanesBusy > 0 || _queue.isNotEmpty;

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
    final items = _itemsOf(context, regions);
    final compare = _compareRows(regions);
    return Scaffold(
      appBar: AppBar(
        title: const Text('All regions'),
        actions: [IconButton(key: const Key('regions-refresh'), tooltip: 'Refresh', onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: regions.isEmpty
          ? const EmptyState(icon: Icons.map_outlined, title: 'No regions loaded yet', body: 'Connect to the internet once and they are remembered.')
          : Column(children: [
              if (regions.length > 8)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    key: const Key('regions-search'),
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search ${regions.length} regions',
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              key: const Key('regions-search-clear'),
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                    _search.clear();
                                    _query = '';
                                  })),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              if (_busy) const LinearProgressIndicator(key: Key('regions-loading')),
              if (_mode == _FigureMode.bulk && _figuresAsOf != null)
                Padding(
                  key: const Key('regions-figures-asof'),
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Text(
                    'Numbers as of ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_figuresAsOf!.toLocal()))}'
                    ' (the server refreshes them every few minutes).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_paused)
                const Padding(
                  key: Key('regions-paused'),
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('The server asked for a pause (too many requests). Numbers continue in a minute.'),
                ),
              Expanded(
                child: ListView.builder(
                  key: const Key('regions-screen'),
                  padding: const EdgeInsets.all(12),
                  itemCount: (compare == null ? 0 : 1) + items.length + (items.isEmpty ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (compare != null) {
                      if (i == 0) return compare;
                      i--;
                    }
                    if (items.isEmpty) {
                      return Padding(
                        key: const Key('regions-no-match'),
                        padding: const EdgeInsets.all(Gap.xl),
                        child: Text('No region matches "$_query".'),
                      );
                    }
                    return switch (items[i]) {
                      _Header(:final key, :final label) => Padding(
                          padding: const EdgeInsets.fromLTRB(4, Gap.m, 4, Gap.xs),
                          child: Text(label, key: Key(key), style: Theme.of(context).textTheme.titleMedium),
                        ),
                      _Tile(:final region) => _FigureTile(
                          key: ValueKey('regions-row-${region.code}'),
                          region: region,
                          viewing: region.code == viewing,
                          figures: _figures[region.code],
                          asked: _asked.contains(region.code),
                          onWant: _want,
                          onUnwant: _unwant,
                          onTap: _open,
                        ),
                    };
                  },
                ),
              ),
            ]),
    );
  }

  /// The flat list the builder walks: hub group headers then their regions, then countries; or ranked search results.
  List<_Item> _itemsOf(BuildContext context, List<RegionIndexEntry> regions) {
    if (identical(_itemsFor, regions) && identical(_itemsHub, _hub) && _itemsQuery == _query) return _items;
    final out = <_Item>[];
    if (_query.trim().isNotEmpty) {
      for (final r in RegionSearchIndex.of(regions).search(_query)) {
        out.add(_Tile(r));
      }
    } else {
      final sorted = [...regions]..sort((a, b) => foldForSearch(a.name).compareTo(foldForSearch(b.name)));
      // Hub groups first (in group order), then every other region by country.
      for (final g in _hub.groups) {
        final members = [for (final r in sorted) if (_hub.groupOf[r.code] == g.code) r];
        if (members.isEmpty) continue;
        out.add(_Header('regions-group-${g.code}', g.name));
        out.addAll([for (final r in members) _Tile(r)]);
      }
      final loose = [for (final r in sorted) if (!_hub.groupOf.containsKey(r.code)) r];
      final byCountry = groupByCountry(loose);
      for (final c in byCountry) {
        final label = c.code == null ? (_hub.groups.isNotEmpty ? 'Other regions' : 'Regions') : c.label;
        // One country with no group above it needs no heading of its own when it is the only thing listed.
        if (c.code == null && byCountry.length == 1 && _hub.groups.isEmpty) {
          out.addAll([for (final r in c.regions) _Tile(r)]);
          continue;
        }
        out.add(_Header('regions-country-${c.code ?? 'other'}', '$label (${c.regions.length})'));
        out.addAll([for (final r in c.regions) _Tile(r)]);
      }
    }
    _itemsFor = regions;
    _itemsHub = _hub;
    _itemsQuery = _query;
    _items = out;
    return out;
  }

  /// The comparison table over the regions whose figures have been read and hold drives (at most [regionCompareRows]),
  /// or null when there are none. It says how many regions it covers: it is never "all regions" unless it is.
  Widget? _compareRows(List<RegionIndexEntry> regions) {
    final loaded = [for (final f in _figures.values) if (f.hasData) f];
    if (loaded.isEmpty) return null;
    final t = Theme.of(context);
    final sorted = sortFigures(loaded, _sort, ascending: _asc);
    final rows = sorted.take(regionCompareRows).toList();
    String n(num? v) => v == null ? '—' : groupInt(v.round());
    String p(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';
    final viewing = widget.regions != null ? widget.viewingCode : AppScope.read(context).viewingRegion?.code;
    return Card(
      child: ExpansionTile(
        key: const Key('regions-compare-tile'),
        title: const Text('Compare regions'),
        subtitle: Text(
          _mode == _FigureMode.bulk
              ? '${loaded.length} of ${regions.length} regions have drives${loaded.length > rows.length ? ' (top ${rows.length} shown)' : ''}.'
              : 'Among the ${loaded.length} of ${regions.length} regions read so far that have drives'
                  '${loaded.length > rows.length ? ' (top ${rows.length})' : ''}. Scroll the list to read more.',
          key: const Key('regions-compare-scope'),
          style: t.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, Gap.s),
        children: [
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
                cells: [
                  DataCell(Text(f.region.name)),
                  DataCell(Text(n(f.stats!.km))),
                  DataCell(Text(n(f.stats!.drives))),
                  DataCell(Text(n(f.stats!.drivers))),
                  DataCell(Text(n(f.stats!.pings))),
                  DataCell(Text(p(f.stats!.heardPct))),
                  DataCell(Text(p(f.stats!.cellsHeardPct))),
                  DataCell(Text(n(f.stats!.repeatersHeard))),
                ],
              ),
          ],
        ),
      ),
        ],
      ),
    );
  }
}

/// One region row. It asks for its figures when it is built (on screen) and withdraws the ask when it leaves.
class _FigureTile extends StatefulWidget {
  final RegionIndexEntry region;
  final bool viewing;
  final RegionFigures? figures;
  final bool asked;
  final void Function(RegionIndexEntry) onWant;
  final void Function(RegionIndexEntry) onUnwant;
  final void Function(RegionIndexEntry) onTap;
  const _FigureTile({
    super.key,
    required this.region,
    required this.viewing,
    required this.figures,
    required this.asked,
    required this.onWant,
    required this.onUnwant,
    required this.onTap,
  });

  @override
  State<_FigureTile> createState() => _FigureTileState();
}

class _FigureTileState extends State<_FigureTile> {
  @override
  void initState() {
    super.initState();
    // After this frame: the ask may call setState on the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onWant(widget.region);
    });
  }

  @override
  void dispose() {
    widget.onUnwant(widget.region);
    super.dispose();
  }

  String _line(Units units) {
    final f = widget.figures;
    if (f == null) return widget.asked ? 'Loading numbers…' : 'Numbers load when this row is on screen';
    final s = f.stats;
    if (s == null) return 'Numbers unavailable right now';
    if (s.isEmpty) return 'No drives yet';
    return '${s.km == null ? '—' : units.total(s.km! * 1000, groupInt)} · ${s.drives == null ? '—' : groupInt(s.drives!)} drives · '
        '${s.drivers == null ? '—' : groupInt(s.drivers!)} drivers · ${s.repeatersHeard == null ? '—' : groupInt(s.repeatersHeard!)} repeaters heard';
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.region;
    return Card(
      child: ListTile(
        key: Key('regions-tile-${r.code}'),
        title: Text(r.name),
        subtitle: Text('${r.code} · ${_line(AppScope.unitsOf(context))}'),
        trailing: widget.viewing ? const Chip(label: Text('Viewing')) : const Icon(Icons.chevron_right),
        onTap: () => widget.onTap(r),
      ),
    );
  }
}
