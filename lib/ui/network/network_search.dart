// The one search field of the Network header (AZ-3.5; website twin: the Cmd-K search of AZ-2.1). It searches node
// names and key prefixes, packet hashes, observers and regions on `GET /v1/search`, or, while `/v1` is not live or the
// phone is offline, over what the app already has: the node roster kept for the map, the region list, the observers
// of the viewed region (their stored copy works offline). A result opens its page through the same NetworkRequest a
// link would use.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/region_lookup.dart';
import '../../core/v1/nodes_api.dart' show nodesApiFactory;
import '../../core/v1/search_api.dart';
import '../app.dart';
import '../design/app_surfaces.dart' show showAppSheet;

/// The header's search field: a tap opens the search sheet with the keyboard up.
class NetworkSearchField extends StatelessWidget {
  final RegionIndexEntry region;
  const NetworkSearchField({super.key, required this.region});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Search nodes, keys, packets, observers and regions',
      excludeSemantics: true,
      child: Material(
        color: t.colorScheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: const Key('network-search'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => openNetworkSearch(context, region),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Icon(Icons.search, size: 20, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Search nodes, keys, packets, regions',
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the search sheet for [region]; a chosen result opens its Network page.
Future<void> openNetworkSearch(BuildContext context, RegionIndexEntry region) async {
  final shell = ShellController.of(context);
  final app = AppScope.maybeOf(context);
  final nodes = <({String key, String? name, String role})>[];
  final seen = <String>{};
  if (app != null) {
    for (final r in [...app.regionRepeaterSet.rows, ...app.globalRepeaterSet.rows]) {
      if (seen.add(r.key.toLowerCase())) nodes.add((key: r.key.toLowerCase(), name: r.name, role: r.type == 3 ? 'room' : 'repeater'));
    }
  }
  final regions = [for (final r in app?.regionIndex ?? const <RegionIndexEntry>[]) (slug: r.slug, name: r.name)];
  final picked = await showAppSheet<SearchHit>(
    context,
    detents: const [0.92],
    builder: (ctx, sc) => NetworkSearchSheet(
      controller: sc,
      region: region,
      local: LocalSearchIndex(nodes: nodes, regions: regions, region: region.slug),
    ),
  );
  final req = picked?.request;
  if (req != null) shell?.openNetwork(req);
}

class NetworkSearchSheet extends StatefulWidget {
  final ScrollController controller;
  final RegionIndexEntry region;
  final LocalSearchIndex local;

  /// Debounce of typing before a search runs.
  final Duration debounce;
  const NetworkSearchSheet({super.key, required this.controller, required this.region, required this.local, this.debounce = const Duration(milliseconds: 300)});

  @override
  State<NetworkSearchSheet> createState() => _NetworkSearchSheetState();
}

class _NetworkSearchSheetState extends State<NetworkSearchSheet> {
  final TextEditingController _text = TextEditingController();
  Timer? _debounce;
  SearchRead? _read;
  String? _error;
  bool _loading = false;
  int _gen = 0;
  late LocalSearchIndex _local = widget.local;

  @override
  void initState() {
    super.initState();
    unawaited(_loadObservers());
  }

  Future<void> _loadObservers() async {
    final api = nodesApiFactory(widget.region.url);
    try {
      final page = await api.observers();
      if (!mounted) return;
      setState(() => _local = LocalSearchIndex(
            nodes: _local.nodes,
            regions: _local.regions,
            region: _local.region,
            observers: [for (final o in page.rows) (id: o.id, name: o.name)],
          ));
    } catch (_) {
      // Observers are simply not searched locally then.
    } finally {
      api.close();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () => _run(q));
  }

  Future<void> _run(String q) async {
    final gen = ++_gen;
    if (q.trim().length < 2) {
      setState(() {
        _read = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final api = searchApiFactory(widget.region.url);
    try {
      final r = await api.search(q, local: _local);
      if (!mounted || gen != _gen) return;
      setState(() {
        _read = r;
        _error = null;
      });
    } on V1Error catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e.rateLimited ? 'Too many searches just now. Try again in a minute.' : e.message;
        _read = SearchRead(query: q, hits: localSearch(q, _local), local: true, localReason: 'error');
      });
    } finally {
      api.close();
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  static IconData _icon(SearchKind k) => switch (k) {
        SearchKind.node => Icons.cell_tower,
        SearchKind.packet => Icons.podcasts,
        SearchKind.observer => Icons.sensors,
        SearchKind.channel => Icons.forum_outlined,
        SearchKind.message => Icons.chat_bubble_outline,
        SearchKind.region => Icons.public,
        SearchKind.other => Icons.search,
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _read;
    final note = r == null || !r.local
        ? null
        : switch (r.localReason) {
            'offline' => 'Offline: searching what this phone already has.',
            'error' => 'The server search did not answer; showing what this phone already has.',
            _ => 'Searching what this phone already has (the server search arrives with the new API).',
          };
    return ListView(
      key: const Key('network-search-sheet'),
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        TextField(
          key: const Key('network-search-input'),
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Name, key prefix, packet hash, region',
            suffixIcon: _text.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _text.clear();
                      _run('');
                    }),
          ),
          onChanged: _changed,
          onSubmitted: (q) {
            _debounce?.cancel();
            _run(q);
          },
        ),
        if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(key: Key('network-search-loading'))),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(note, key: const Key('network-search-local'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error))),
        if (r != null && r.hits.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text('Nothing matches "${r.query}".', key: const Key('network-search-empty'), textAlign: TextAlign.center),
          ),
        if (r == null && !_loading)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text('Type at least 2 characters: a node or observer name, the start of a key (a7, 3cd0), a packet hash, or a region.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        for (final h in r?.hits ?? const <SearchHit>[])
          ListTile(
            key: ValueKey('network-search-hit-${h.kind.name}-${h.title}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(_icon(h.kind)),
            title: Text(h.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: h.subtitle == null ? null : Text(h.subtitle!),
            trailing: h.request == null ? null : const Icon(Icons.chevron_right),
            enabled: h.request != null,
            onTap: h.request == null ? null : () => Navigator.of(context).pop(h),
          ),
      ],
    );
  }
}
