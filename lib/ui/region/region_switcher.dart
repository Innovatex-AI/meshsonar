// The region switcher (Andy, Oct 21): lists ALL regions, the phone's GPS region first, then nearest; picking one
// swaps the whole Region tab, the coverage layer and the radio preset shown. "Follow my location" goes back to GPS.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/region_lookup.dart';
import '../../core/region_search.dart';
import '../app.dart';
import '../onboarding/ui_prefs.dart';
import 'region_switch_sheet.dart' show switchViewedRegion;
import 'regions_screen.dart';

Future<void> showRegionSwitcher(BuildContext context) {
  final state = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => RegionSwitcherSheet(state: state),
  );
}

/// How many "near you" shortcuts sit above the country list.
const int regionNearCount = 6;

/// The regions list is a lazily built list (559 and growing: a `ListView(children:)` of radio tiles built them all at
/// once), with a search box that matches accents ("dusseldorf" finds "Düsseldorf"), codes and country names, the
/// phone's region and the nearest ones first, then every region by country.
class RegionSwitcherSheet extends StatefulWidget {
  final AppState state;
  const RegionSwitcherSheet({super.key, required this.state});

  @override
  State<RegionSwitcherSheet> createState() => _RegionSwitcherSheetState();
}

sealed class _Row {
  const _Row();
}

class _RowHeader extends _Row {
  final String key, label;
  const _RowHeader(this.key, this.label);
}

enum _RowKind { plain, near, recent }

class _RowRegion extends _Row {
  final RegionIndexEntry region;
  final _RowKind kind; // a "near" or "recent" shortcut: its own widget key, the same region again below
  const _RowRegion(this.region, {this.kind = _RowKind.plain});
}

class _RegionSwitcherSheetState extends State<RegionSwitcherSheet> {
  String _query = '';
  final TextEditingController _controller = TextEditingController();

  List<RegionIndexEntry>? _rowsFor;
  List<RegionIndexEntry>? _rowsSwitcher;
  String _rowsQuery = '';
  String _rowsRecent = '';
  String _rowsViewing = '';
  List<_Row> _rows = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_Row> _rowsOf(List<RegionIndexEntry> index, List<RegionIndexEntry> nearestFirst) {
    final recentCodes = uiPrefsFor(widget.state).recentRegions;
    final recentKey = recentCodes.join(',');
    final viewingCode = widget.state.viewingRegion?.code ?? '';
    if (identical(_rowsFor, index) &&
        identical(_rowsSwitcher, nearestFirst) &&
        _rowsQuery == _query &&
        _rowsRecent == recentKey &&
        _rowsViewing == viewingCode) {
      return _rows;
    }
    final out = <_Row>[];
    if (_query.trim().isNotEmpty) {
      for (final r in RegionSearchIndex.of(index).search(_query)) {
        out.add(_RowRegion(r));
      }
    } else {
      // The last regions switched to by hand, most recent first (website parity: "recents kept").
      final byCode = {for (final r in index) r.code: r};
      final recents = [for (final c in recentCodes) ?byCode[c]];
      if (recents.isNotEmpty) {
        out.add(const _RowHeader('regions-recent', 'Recent'));
        for (final r in recents) {
          out.add(_RowRegion(r, kind: _RowKind.recent));
        }
      }
      if (widget.state.regionFixKnown && nearestFirst.length > regionNearCount + 4) {
        out.add(const _RowHeader('regions-near', 'Near you'));
        for (final r in nearestFirst.take(regionNearCount)) {
          out.add(_RowRegion(r, kind: _RowKind.near));
        }
      } else if (widget.state.regionNeighbours case final set? when !set.isEmpty) {
        // No fix (or none useful): the regions next to the one on screen.
        out.add(_RowHeader('regions-near-view', 'Near ${shortNameOf(set.viewing)}'));
        for (final n in set.neighbours.take(regionNearCount)) {
          out.add(_RowRegion(n.region, kind: _RowKind.near));
        }
      }
      final sorted = [...index]..sort((a, b) => foldForSearch(a.name).compareTo(foldForSearch(b.name)));
      // A short list needs no country headings.
      final groups = groupByCountry(sorted);
      if (groups.length <= 1) {
        for (final r in sorted) {
          out.add(_RowRegion(r));
        }
      } else {
        for (final g in groups) {
          out.add(_RowHeader('region-country-${g.code ?? 'other'}', '${g.label} (${g.regions.length})'));
          for (final r in g.regions) {
            out.add(_RowRegion(r));
          }
        }
      }
    }
    _rowsFor = index;
    _rowsSwitcher = nearestFirst;
    _rowsQuery = _query;
    _rowsRecent = recentKey;
    _rowsViewing = viewingCode;
    _rows = out;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final t = Theme.of(context);
        final viewing = state.viewingRegion;
        final gps = state.currentRegion;
        final index = state.regionIndex;
        final rows = _rowsOf(index, state.switcherRegions);
        final searching = _query.trim().isNotEmpty;
        final fixed = <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Choose a region', style: t.textTheme.titleLarge),
          ),
          if (index.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const Key('region-search'),
                controller: _controller,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search ${index.length} regions',
                  suffixIcon: searching
                      ? IconButton(
                          key: const Key('region-search-clear'),
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _controller.clear();
                            _query = '';
                          }),
                        )
                      : null,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
        ];
        final mq = MediaQuery.of(context);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: mq.viewInsets.bottom), // above the keyboard while searching
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.85),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ...fixed,
              Flexible(
                child: ListView.builder(
                  key: const Key('region-switcher'),
                  shrinkWrap: true,
                  itemCount: rows.length + (searching ? 0 : 2) + (index.isEmpty ? 1 : 0) + (searching && rows.isEmpty ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (!searching) {
                      if (i == 0) return _allRegionsTile(context);
                      if (i == 1) return _followTile(gps, state);
                      i -= 2;
                    }
                    if (i >= rows.length) {
                      return Padding(
                        key: const Key('region-switcher-empty'),
                        padding: const EdgeInsets.all(20),
                        child: Text(index.isEmpty
                            ? 'No regions loaded yet. Connect to the internet once and they will be remembered.'
                            : 'No region matches "$_query".'),
                      );
                    }
                    return switch (rows[i]) {
                      _RowHeader(:final key, :final label) => Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                          child: Text(label, key: Key(key), style: t.textTheme.titleSmall),
                        ),
                      _RowRegion(:final region, :final kind) => _tile(context, region, gps, viewing, state, kind: kind),
                    };
                  },
                ),
              ),
            ]),
            ),
          ),
        );
      },
    );
  }

  Widget _allRegionsTile(BuildContext context) => ListTile(
        key: const Key('region-all'),
        leading: const Icon(Icons.public),
        title: const Text('All regions'),
        subtitle: const Text('Compare every region and switch'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          final nav = Navigator.of(context);
          nav.pop();
          unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const RegionsScreen())));
        },
      );

  Widget _followTile(RegionIndexEntry? gps, AppState state) {
    final following = !state.viewingIsManual;
    return ListTile(
      key: const Key('region-follow'),
      leading: Icon(following ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      selected: following,
      title: const Text('Follow my location'),
      subtitle: Text(gps != null
          ? 'You are in ${gps.name}${state.regionAlsoIn.isEmpty ? '' : ' (also ${state.regionAlsoIn.map((r) => r.code).join(', ')})'}'
          : state.regionFixKnown
              ? 'Outside every region: showing the nearest'
              : 'Waiting for a GPS fix'),
      onTap: () {
        unawaited(state.setViewingRegion(null));
        Navigator.of(context).pop();
      },
    );
  }

  Widget _tile(BuildContext context, RegionIndexEntry r, RegionIndexEntry? gps, RegionIndexEntry? viewing, AppState state, {required _RowKind kind}) {
    final picked = state.viewingIsManual && viewing?.code == r.code;
    final here = r.code == gps?.code;
    final also = state.regionAlsoIn.any((x) => x.code == r.code);
    return ListTile(
      key: Key('${switch (kind) { _RowKind.near => 'region-near', _RowKind.recent => 'region-recent', _RowKind.plain => 'region-option' }}-${r.code}'),
      leading: Icon(picked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      selected: picked,
      title: Text(r.name),
      subtitle: Text(here ? '${r.code} · you are here' : also ? '${r.code} · you are also here (shared border)' : r.code),
      onTap: () {
        unawaited(switchViewedRegion(state, r));
        Navigator.of(context).pop();
      },
    );
  }
}

/// A tappable chip with the viewed region; opens the switcher.
class RegionSwitcherChip extends StatelessWidget {
  const RegionSwitcherChip({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.viewingRegion;
    final gps = s.currentRegion;
    final differs = v != null && gps != null && gps.code != v.code;
    return ActionChip(
      key: const Key('region-switch-chip'),
      avatar: const Icon(Icons.map_outlined, size: 18),
      label: Text(v == null ? 'Region' : differs ? '${v.code} · you are in ${gps.code}' : v.code),
      onPressed: () => showRegionSwitcher(context),
    );
  }
}
