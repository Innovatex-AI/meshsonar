// Network > Nodes (AZ-3.4). Website twins: `/nodes` (the directory, every role) and `/observers`.
//
// - Nodes: every role (repeater, room, companion, sensor) from `GET /v1/nodes`, with role, status and last-heard filter
//   chips, a search field (name or key prefix), a "My nodes" chip (starred nodes plus claimed radios), favourites first,
//   cursor paging with infinite scroll, pull to refresh. Tap a row for the node page.
// - Observers: `GET /v1/observers`, favourites first, with kind and status; tap for the observer page.
// - Server states: `/v1` live; not live (today's region roster or observer list, filtered on the phone, with a note);
//   offline (the stored copy with "Offline - as of", or a no-connection view with Retry).
// No polling: the lists load when shown and on pull to refresh (battery rules).
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/region_lookup.dart';
import '../../../core/v1/nodes_api.dart';
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, agoText;
import '../../theme.dart';
import '../network_context.dart';
import '../packets/packet_ui.dart' show WebTwinLine;
import 'node_routes.dart';
import 'node_ui.dart';

/// Nodes | Observers, the two views of Network > Nodes.
class NetworkNodesSection extends StatelessWidget {
  final RegionIndexEntry region;

  /// 0 = the node directory (every role), 1 = observers.
  final int sub;
  final ValueChanged<int> onSub;
  const NetworkNodesSection({super.key, required this.region, required this.sub, required this.onSub});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Semantics(
            container: true,
            label: 'Nodes views',
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<int>(
                key: const Key('network-sub-nodes'),
                groupValue: sub,
                thumbColor: c.surfaceContainerHighest,
                backgroundColor: c.onSurface.withValues(alpha: 0.10),
                children: {
                  for (final (i, l) in [(0, 'Nodes'), (1, 'Observers')])
                    i: ConstrainedBox(constraints: const BoxConstraints(minHeight: 36), child: Center(child: Text(l, key: Key('network-sub-nodes-$i'), maxLines: 1))),
                },
                onValueChanged: (v) {
                  if (v != null) onSub(v);
                },
              ),
            ),
          ),
        ),
      ),
      Expanded(
        child: sub == 0
            ? NodeDirectoryView(key: ValueKey('nodes-dir-${region.code}'), baseUrl: region.url, regionSlug: region.slug)
            : ObserverListView(key: ValueKey('nodes-obs-${region.code}'), baseUrl: region.url, regionSlug: region.slug),
      ),
    ]);
  }
}

/// Favourites first, then the order the server (or the roster sort) gave.
List<T> favouritesFirst<T>(List<T> rows, bool Function(T) fav) => [...rows.where(fav), ...rows.where((r) => !fav(r))];

class NodeDirectoryView extends StatefulWidget {
  final String baseUrl, regionSlug;
  final NodeQuery initial;
  const NodeDirectoryView({super.key, required this.baseUrl, required this.regionSlug, this.initial = NodeQuery.all});
  @override
  State<NodeDirectoryView> createState() => _NodeDirectoryViewState();
}

enum _Load { loading, ready, error }

class _NodeDirectoryViewState extends State<NodeDirectoryView> {
  late NodeQuery _q = widget.initial;
  bool _mine = false;
  _Load _state = _Load.loading;
  V1Error? _error;
  final List<NodeRow> _rows = [];
  String? _next;
  bool _legacy = false, _loadingMore = false;
  DateTime? _asOf;
  String? _statusNote;
  Map<String, int> _roleCounts = const {}, _statusCounts = const {};
  int _gen = 0;
  Timer? _debounce;
  final _search = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) unawaited(_loadMore());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _state = _rows.isEmpty ? _Load.loading : _state;
      _error = null;
    });
    final api = nodesApiFactory(widget.baseUrl);
    try {
      final p = await api.nodes(_q);
      if (!mounted || gen != _gen) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(p.rows);
        _next = p.next;
        _legacy = p.source == NetworkReadSource.legacy;
        _asOf = p.offlineAsOf;
        _roleCounts = p.roleCounts;
        _statusCounts = p.statusCounts;
        final st = p.status;
        _statusNote = st != null && st.state.name != 'ready' ? (st.reason ?? 'The data is ${st.state.name}.') : null;
        _state = _Load.ready;
      });
    } on V1Error catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _state = _Load.error;
      });
    } finally {
      api.close();
    }
  }

  Future<void> _loadMore() async {
    if (_next == null || _loadingMore || _legacy) return;
    _loadingMore = true;
    final gen = _gen;
    final api = nodesApiFactory(widget.baseUrl);
    try {
      final p = await api.nodes(_q, cursor: _next);
      if (!mounted || gen != _gen) return;
      setState(() {
        _rows.addAll(p.rows);
        _next = p.next;
      });
    } catch (_) {
      // the next scroll tries again
    } finally {
      _loadingMore = false;
      api.close();
    }
  }

  void _set(NodeQuery q) {
    if (q == _q) return;
    _q = q;
    _rows.clear();
    _next = null;
    unawaited(_load());
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _set(_q.copyWith(q: v)));
  }

  Widget _chip(String label, bool on, VoidCallback tap, {Key? key}) => Padding(
        padding: const EdgeInsets.only(right: Gap.s),
        child: FilterChip(key: key, label: Text(label), selected: on, onSelected: (_) => tap()),
      );

  Widget _filters(BuildContext context) {
    String count(Map<String, int> m, String k) => m[k] == null ? '' : ' ${m[k]}';
    Set<String> toggle(Set<String> s, String v) => s.contains(v) ? ({...s}..remove(v)) : {...s, v};
    return SingleChildScrollView(
      key: const Key('nodes-filters'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
      child: Row(children: [
        _chip('My nodes', _mine, () => setState(() => _mine = !_mine), key: const Key('nodes-mine')),
        for (final r in nodeRoles)
          _chip('${nodeRoleLabel(r)}${count(_roleCounts, r)}', _q.roles.contains(r), () => _set(_q.copyWith(roles: toggle(_q.roles, r))), key: Key('nodes-role-$r')),
        for (final s in const ['active', 'degraded', 'silent'])
          _chip('${nodeStatusLabel(s)}${count(_statusCounts, s)}', _q.statuses.contains(s), () => _set(_q.copyWith(statuses: toggle(_q.statuses, s))),
              key: Key('nodes-status-$s')),
        for (final w in const ['1h', '24h', '7d'])
          _chip('Heard in $w', _q.lastHeard == w, () => _set(_q.lastHeard == w ? _q.copyWith(clearLastHeard: true) : _q.copyWith(lastHeard: w)),
              key: Key('nodes-heard-$w')),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FavouritesListener(builder: (context, store) {
      final mine = myNodesOf(context);
      var rows = _mine ? _rows.where((r) => mine.hasKey(r.key)).toList() : _rows;
      rows = favouritesFirst(rows, (r) => store.isFavourite(FavouriteKind.node, r.key));
      final header = <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.s),
          child: TextField(
            key: const Key('nodes-search'),
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name or key prefix', isDense: true, border: OutlineInputBorder()),
          ),
        ),
        _filters(context),
        if (_asOf != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: RegionOfflineAsOf(asOf: _asOf!, onRetry: _load)),
        if (_legacy || _statusNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
            child: Text(
              [
                if (_legacy) 'From the region roster: filters are applied on this phone, usefulness and clock come with the new node service.',
                ?_statusNote,
              ].join(' '),
              key: const Key('nodes-legacy-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
      ];
      Widget body;
      if (_state == _Load.loading && _rows.isEmpty) {
        body = const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
      } else if (_state == _Load.error && _rows.isEmpty) {
        body = _error?.offline == true
            ? RegionOfflineEmpty(what: 'the node list', onRetry: _load)
            : Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: Column(children: [
                  Text(_error?.message ?? 'The node list did not load.', key: const Key('nodes-error'), textAlign: TextAlign.center),
                  const SizedBox(height: Gap.m),
                  FilledButton(onPressed: _load, child: const Text('Try again')),
                ]),
              );
      } else if (rows.isEmpty) {
        body = Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Text(_mine ? 'None of your nodes is in this list. Star a node to add it to My nodes.' : 'No node matches these filters.',
              key: const Key('nodes-empty'), textAlign: TextAlign.center),
        );
      } else {
        body = const SizedBox.shrink();
      }
      final twin = WebTwinLine(Uri(scheme: 'https', host: '${widget.regionSlug}.meshsonar.com', path: '/nodes'));
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          key: const Key('nodes-list'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: header.length + 1 + rows.length + 1,
          itemBuilder: (context, i) {
            if (i < header.length) return header[i];
            i -= header.length;
            if (i == 0) return body;
            i -= 1;
            if (i < rows.length) {
              final r = rows[i];
              return _NodeTile(
                row: r,
                fav: store.isFavourite(FavouriteKind.node, r.key),
                onTap: () => openNetworkNode(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, nodeKey: r.key),
              );
            }
            return Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m), child: twin);
          },
        ),
      );
    });
  }
}

class _NodeTile extends StatelessWidget {
  final NodeRow row;
  final bool fav;
  final VoidCallback onTap;
  const _NodeTile({required this.row, required this.fav, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bits = [
      nodeRoleLabel(row.role),
      nodeStatusLabel(row.status),
      row.lastHeardAt == null ? 'never heard' : 'heard ${agoText(row.lastHeardAt)}',
      if (row.relayed24h != null) '${row.relayed24h} relayed in 24 h',
      if (row.usefulnessGrade != null) 'grade ${row.usefulnessGrade}',
    ];
    return ListTile(
      key: Key('node-row-${row.key}'),
      onTap: onTap,
      leading: Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(row.status)),
      title: Row(children: [
        Flexible(child: Text(row.label, maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (fav) ...[const SizedBox(width: Gap.xs), Icon(Icons.star, size: 16, color: MeshSonarColors.of(context).beacon, semanticLabel: 'Favourite')],
      ]),
      subtitle: Text(bits.join(' · '), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      trailing: Text(row.prefix, style: t.textTheme.labelMedium),
    );
  }
}

class ObserverListView extends StatefulWidget {
  final String baseUrl, regionSlug;
  const ObserverListView({super.key, required this.baseUrl, required this.regionSlug});
  @override
  State<ObserverListView> createState() => _ObserverListViewState();
}

class _ObserverListViewState extends State<ObserverListView> {
  late Future<ObserverListPage> _f = _fetch();

  Future<ObserverListPage> _fetch() async {
    final api = nodesApiFactory(widget.baseUrl);
    try {
      return await api.observers();
    } finally {
      api.close();
    }
  }

  Future<void> _reload() async {
    final f = _fetch();
    setState(() => _f = f);
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FutureBuilder<ObserverListPage>(
      future: _f,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) {
          final e = snap.error;
          if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'the observers', onRetry: _reload));
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(e is V1Error ? e.message : 'The observers did not load.', key: const Key('observers-error'), textAlign: TextAlign.center),
                const SizedBox(height: Gap.m),
                FilledButton(onPressed: _reload, child: const Text('Try again')),
              ]),
            ),
          );
        }
        final p = snap.data!;
        return FavouritesListener(builder: (context, store) {
          final rows = favouritesFirst(p.rows, (r) => store.isFavourite(FavouriteKind.observer, r.id));
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              key: const Key('observers-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (p.offlineAsOf != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: RegionOfflineAsOf(asOf: p.offlineAsOf!, onRetry: _reload)),
                if (p.source == NetworkReadSource.legacy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
                    child: Text('From the region observer list: airtime and clock come with the new observer service.',
                        key: const Key('observers-legacy-note'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ),
                if (rows.isEmpty) const Padding(padding: EdgeInsets.all(Gap.xl), child: Text('No observer hears this region yet.', key: Key('observers-empty'), textAlign: TextAlign.center)),
                for (final r in rows)
                  ListTile(
                    key: Key('observer-row-${r.id}'),
                    leading: Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(r.status)),
                    title: Row(children: [
                      Flexible(child: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      if (store.isFavourite(FavouriteKind.observer, r.id)) ...[
                        const SizedBox(width: Gap.xs),
                        Icon(Icons.star, size: 16, color: MeshSonarColors.of(context).beacon, semanticLabel: 'Favourite'),
                      ],
                    ]),
                    subtitle: Text(
                      [
                        observerKindLabel(r.kind),
                        observerStatusLabel(r.status),
                        if (r.lastSeen != null) 'seen ${agoText(r.lastSeen)}',
                        if (r.packets1h != null) '${r.packets1h} packets last hour',
                        if (r.noiseFloorDbm != null) 'noise ${r.noiseFloorDbm!.round()} dBm',
                      ].join(' · '),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    trailing: r.dutyCycleWarn ? Icon(Icons.warning_amber_rounded, color: MeshSonarColors.of(context).beacon, semanticLabel: 'Duty cycle high') : null,
                    onTap: () => openNetworkObserver(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, observerId: r.id),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                  child: WebTwinLine(Uri(scheme: 'https', host: '${widget.regionSlug}.meshsonar.com', path: '/observers')),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}
