// Network > Nodes (AZ-3.4). Website twins: `/nodes` (the directory, every role) and `/observers`. The Network tab's
// section strip hosts NodeDirectoryView and the observers list directly (the old Nodes | Observers switch is gone).
//
// - Nodes: every role (repeater, room, companion, sensor) from `GET /v1/nodes`, with role, status and last-heard filter
//   chips, a search field (name or key prefix), a "My nodes" chip (starred nodes plus claimed radios), favourites first,
//   cursor paging with infinite scroll, pull to refresh. Tap a row for the node page.
// - Observers: `GET /v1/observers`, favourites first, with kind and status; tap for the observer page.
// - Server states: `/v1` live; not live (today's region roster or observer list, filtered on the phone, with a note);
//   offline (the stored copy with "Offline - as of", or a no-connection view with Retry).
// No polling: the lists load when shown and on pull to refresh (battery rules).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/time_format.dart';
import '../../../core/v1/nodes_api.dart';
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty;
import '../../theme.dart';
import '../network_context.dart';
import '../packets/packet_ui.dart' show WebTwinLine, dotJoin, plainServerText, stillCountingText;
import 'node_routes.dart';
import 'node_ui.dart';
import 'observers_directory.dart';

export 'observers_directory.dart';

/// The observers list lives in observers_directory.dart (its own Network section since build 71); the old name stays
/// for callers that still use it.
typedef ObserverListView = ObserversDirectoryView;

class NodeDirectoryView extends StatefulWidget {
  final String baseUrl, regionSlug;
  final NodeQuery initial;

  /// Test seam for "Updated X ago".
  final DateTime Function() clock;
  const NodeDirectoryView({super.key, required this.baseUrl, required this.regionSlug, this.initial = NodeQuery.all, this.clock = DateTime.now});
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

  /// When the first page of the list on screen was loaded (for "Updated X ago").
  DateTime? _loadedAt;
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
        _loadedAt = widget.clock().toUtc();
        _roleCounts = p.roleCounts;
        _statusCounts = p.statusCounts;
        final st = p.status;
        _statusNote = st != null && st.state.name != 'ready' ? (plainServerText(st.reason) ?? stillCountingText) : null;
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

  bool get _filtered => _mine || _q.roles.isNotEmpty || _q.statuses.isNotEmpty || _q.lastHeard != null;

  /// Back to every node: the chips off (the search text stays).
  void _clearFilters() {
    setState(() => _mine = false);
    _set(_q.copyWith(roles: const {}, statuses: const {}, clearLastHeard: true));
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() {});
    _set(_q.copyWith(q: ''));
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
        if (_filtered)
          Padding(
            padding: const EdgeInsets.only(right: Gap.s),
            child: ActionChip(key: const Key('nodes-clear-filters'), avatar: const Icon(Icons.close, size: 18), label: const Text('Clear'), onPressed: _clearFilters),
          ),
        _chip('My nodes', _mine, () => setState(() => _mine = !_mine), key: const Key('nodes-mine')),
        for (final r in nodeRoles)
          _chip('${nodeRoleLabel(r)}${count(_roleCounts, r)}', _q.roles.contains(r), () => _set(_q.copyWith(roles: toggle(_q.roles, r))), key: Key('nodes-role-$r')),
        for (final s in const ['active', 'degraded', 'silent'])
          _chip('${nodeStatusLabel(s)}${count(_statusCounts, s)}', _q.statuses.contains(s), () => _set(_q.copyWith(statuses: toggle(_q.statuses, s))),
              key: Key('nodes-status-$s')),
        for (final w in const ['1h', '24h', '7d'])
          _chip(const {'1h': 'Heard last hour', '24h': 'Heard today', '7d': 'Heard this week'}[w]!, _q.lastHeard == w, () => _set(_q.lastHeard == w ? _q.copyWith(clearLastHeard: true) : _q.copyWith(lastHeard: w)),
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
            onChanged: (v) {
              setState(() {}); // the clear button shows with the first letter
              _onSearch(v);
            },
            textInputAction: TextInputAction.search,
            autocorrect: false,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search nodes by name or ID',
              isDense: true,
              suffixIcon: _search.text.isEmpty ? null : IconButton(key: const Key('nodes-search-clear'), tooltip: 'Clear the search', icon: const Icon(Icons.close), onPressed: _clearSearch),
            ),
          ),
        ),
        _filters(context),
        // An offline copy says its own age below; a fresh list says when it was loaded.
        if (_asOf == null && _state == _Load.ready) KeyedSubtree(key: const Key('nodes-updated'), child: UpdatedLine(at: _loadedAt, clock: widget.clock)),
        if (_asOf != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: RegionOfflineAsOf(asOf: _asOf!, onRetry: _load)),
        if (_legacy || _statusNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
            child: Text(
              [
                if (_legacy) 'A simpler list for this region: grades and clock figures are not available here yet.',
                ?_statusNote,
              ].join(' '),
              key: const Key('nodes-legacy-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
      ];
      Widget body;
      if (_state == _Load.loading && _rows.isEmpty) {
        body = Padding(
            key: const Key('nodes-loading'),
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.m),
              Text('Loading the nodes of this region…', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]));
      } else if (_state == _Load.error && _rows.isEmpty) {
        body = _error?.offline == true
            ? RegionOfflineEmpty(what: 'the node list', onRetry: _load)
            : Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: Column(children: [
                  Text(_error?.message ?? 'The node list did not load.', key: const Key('nodes-error'), textAlign: TextAlign.center),
                  const SizedBox(height: Gap.m),
                  FilledButton(key: const Key('nodes-retry'), onPressed: _load, child: const Text('Try again')),
                ]),
              );
      } else if (rows.isEmpty) {
        body = Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(children: [
            Text(
                _mine
                    ? 'None of your nodes is in this list. Open a node and tap the star to add it to My nodes.'
                    : _search.text.isNotEmpty
                        ? 'No node matches "${_search.text}".'
                        : 'No node matches these filters.',
                key: const Key('nodes-empty'),
                textAlign: TextAlign.center),
            if (_filtered || _search.text.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              OutlinedButton(
                key: const Key('nodes-empty-clear'),
                onPressed: () {
                  if (_search.text.isNotEmpty) _clearSearch();
                  if (_filtered) _clearFilters();
                },
                child: const Text('Show every node'),
              ),
            ],
          ]),
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
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    // One line that is kept whole (a separator never starts a line), and the relays on their own short line under
    // it, so a row is the same height whether or not the node relayed anything (Round 2 N-V5).
    final bits = dotJoin([
      nodeRoleLabel(row.role),
      nodeStatusLabel(row.status, label: row.statusLabel),
      row.lastHeardAt == null ? 'never heard' : 'heard ${relativeTime(row.lastHeardAt)}',
      if (row.usefulnessGrade != null) 'grade ${row.usefulnessGrade}',
    ]);
    final relayed = row.relayed24h != null && row.relayed24h! > 0 ? 'relayed ${row.relayed24h} today' : null;
    return ListTile(
      key: Key('node-row-${row.key}'),
      onTap: onTap,
      leading: Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(row.status)),
      minTileHeight: 76,
      title: Row(children: [
        Flexible(child: Text(readableName(row.label), maxLines: 1, overflow: TextOverflow.ellipsis)),
        // A favourite is a choice, not a warning: the accent, never amber.
        if (fav) ...[const SizedBox(width: Gap.xs), Icon(Icons.star, size: 16, color: t.colorScheme.primary, semanticLabel: 'Favourite')],
      ]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(bits, key: Key('node-row-line-${row.key}'), maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
        if (relayed != null) Text(relayed, key: Key('node-row-relayed-${row.key}'), maxLines: 1, style: muted),
      ]),
      // The short ID stays (radio people read it), small; the chevron says a tap opens the node.
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(row.prefix, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant), semanticsLabel: 'ID ${row.prefix}'),
        const Icon(Icons.chevron_right),
      ]),
    );
  }
}
