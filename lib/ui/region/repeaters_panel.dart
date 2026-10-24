// Repeaters panel: a region's repeater roster (GET region-repeaters) as a searchable, sortable list with status
// filters. Loading / empty / error states are explicit; the server's "partial / pending" honesty note is shown.
//
//   RepeatersPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh')
import 'repeater_detail_screen.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_repeaters_api.dart';
import '../theme.dart';

enum RepeaterSort { lastHeard, name, snr, neighbours }

extension on RepeaterSort {
  String get label => switch (this) {
    RepeaterSort.lastHeard => 'Last heard',
    RepeaterSort.name => 'Name',
    RepeaterSort.snr => 'SNR',
    RepeaterSort.neighbours => 'Neighbours',
  };
}

/// "just now", "5m ago", "3h ago", "2d ago", or "never" for null.
String lastSeenLabel(DateTime? t, {DateTime? now}) {
  if (t == null) return 'never';
  final d = (now ?? DateTime.now()).toUtc().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Filters by [query] (name, hash prefix or key), by [only] activity, then sorts.
List<RegionRepeater> filterAndSort(
  List<RegionRepeater> rows, {
  String query = '',
  RepeaterActivity? only,
  RepeaterSort sort = RepeaterSort.lastHeard,
}) {
  final q = query.trim().toLowerCase();
  final out = [
    for (final r in rows)
      if ((only == null || r.status == only) &&
          (q.isEmpty ||
              r.displayName.toLowerCase().contains(q) ||
              r.hashPrefix.startsWith(q) ||
              r.key.startsWith(q)))
        r,
  ];
  int cmpNullLast<T extends Comparable>(T? a, T? b, {bool desc = true}) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return desc ? b.compareTo(a) : a.compareTo(b);
  }

  out.sort((a, b) {
    final c = switch (sort) {
      RepeaterSort.lastHeard => cmpNullLast(a.lastHeardAt, b.lastHeardAt),
      RepeaterSort.name => a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      ),
      RepeaterSort.snr => cmpNullLast(a.snrMeanDb, b.snrMeanDb),
      RepeaterSort.neighbours => cmpNullLast(a.neighbours, b.neighbours),
    };
    return c != 0
        ? c
        : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
  return out;
}

class RepeatersPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seam: the HTTP client used for the fetch.
  final http.Client? client;

  const RepeatersPanel({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
    this.client,
  });

  @override
  State<RepeatersPanel> createState() => _RepeatersPanelState();
}

class _RepeatersPanelState extends State<RepeatersPanel> {
  RegionRepeaters? _data;
  Object? _error;
  bool _loading = true;
  int _gen = 0;
  String _query = '';
  RepeaterActivity? _only;
  RepeaterSort _sort = RepeaterSort.lastHeard;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RepeatersPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) {
      _data = null;
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await fetchRegionRepeaters(
        widget.baseUrl,
        widget.regionSlug,
        client: widget.client,
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (_loading && _data == null) {
      return const Center(
        key: Key('repeaters-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null && _data == null) {
      return Center(
        key: const Key('repeaters-error'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: t.colorScheme.outline,
              ),
              const SizedBox(height: Gap.m),
              Text("Couldn't load repeaters", style: t.textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall,
              ),
              const SizedBox(height: Gap.m),
              FilledButton.tonal(
                key: const Key('repeaters-retry'),
                onPressed: _load,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final data = _data!;
    if (data.rows.isEmpty) {
      return Center(
        key: const Key('repeaters-empty'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cell_tower_rounded,
                size: 40,
                color: t.colorScheme.outline,
              ),
              const SizedBox(height: Gap.m),
              Text('No repeaters yet', style: t.textTheme.titleMedium),
              if (data.status.reason != null) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  data.status.reason!,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      );
    }
    final shown = filterAndSort(
      data.rows,
      query: _query,
      only: _only,
      sort: _sort,
    );
    return Column(
      key: const Key('repeaters-panel'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('repeaters-search'),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search name or hash',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              PopupMenuButton<RepeaterSort>(
                key: const Key('repeaters-sort'),
                tooltip: 'Sort',
                icon: const Icon(Icons.sort_rounded),
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => [
                  for (final s in RepeaterSort.values)
                    PopupMenuItem(value: s, child: Text('Sort: ${s.label}')),
                ],
              ),
            ],
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.m,
              vertical: Gap.xs,
            ),
            children: [
              _chip('All', data.rows.length, null),
              _chip(
                'Active',
                data.counts[RepeaterActivity.active] ?? 0,
                RepeaterActivity.active,
              ),
              _chip(
                'Quiet',
                data.counts[RepeaterActivity.quiet] ?? 0,
                RepeaterActivity.quiet,
              ),
              _chip(
                'New',
                data.counts[RepeaterActivity.fresh] ?? 0,
                RepeaterActivity.fresh,
              ),
              _chip(
                'Stale',
                data.counts[RepeaterActivity.stale] ?? 0,
                RepeaterActivity.stale,
              ),
            ],
          ),
        ),
        if (data.status.state != 'ready' && data.status.reason != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.xs),
            child: Text(
              data.status.reason!,
              key: const Key('repeaters-status-note'),
              style: t.textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: shown.isEmpty
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(Gap.xl),
                        child: Text(
                          'No repeaters match.',
                          key: const Key('repeaters-no-match'),
                          textAlign: TextAlign.center,
                          style: t.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) => _RepeaterTile(
                      shown[i],
                      baseUrl: widget.baseUrl,
                      regionSlug: widget.regionSlug,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, int n, RepeaterActivity? v) => Padding(
    padding: const EdgeInsets.only(right: Gap.s),
    child: ChoiceChip(
      key: Key('repeaters-filter-${v?.name ?? 'all'}'),
      label: Text('$label $n'),
      selected: _only == v,
      onSelected: (_) => setState(() => _only = v),
    ),
  );
}

class _RepeaterTile extends StatelessWidget {
  final RegionRepeater r;
  final String baseUrl;
  final String regionSlug;
  const _RepeaterTile(
    this.r, {
    required this.baseUrl,
    required this.regionSlug,
  });

  Color _dot(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    return switch (r.status) {
      RepeaterActivity.active => Colors.green,
      RepeaterActivity.quiet => mc.beacon,
      RepeaterActivity.fresh => Colors.blue,
      RepeaterActivity.stale => Theme.of(context).colorScheme.outline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bits = <String>[
      r.role == 'repeater'
          ? 'Repeater'
          : (r.role == 'room' ? 'Room server' : r.role),
      lastSeenLabel(r.lastHeardAt),
      if (r.snrMeanDb != null)
        'SNR ${r.snrMeanDb!.toStringAsFixed(1)} dB${r.signalGrade == null ? '' : ' (${r.signalGrade})'}',
      if (r.neighbours != null) '${r.neighbours} nbr',
    ];
    return ListTile(
      key: Key('repeater-row-${r.key}'),
      leading: Icon(Icons.circle, size: 12, color: _dot(context)),
      title: Text(r.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(bits.join(' · ')),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            r.hashPrefix,
            style: t.textTheme.labelLarge?.copyWith(fontFamily: 'monospace'),
          ),
          if (r.ambiguous) Text('shared', style: t.textTheme.labelSmall),
        ],
      ),
      onTap: () => openRepeaterDetail(
        context,
        baseUrl: baseUrl,
        regionSlug: regionSlug,
        repeaterKey: r.key,
      ),
      onLongPress: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(child: _RepeaterDetail(r)),
      ),
    );
  }
}

class _RepeaterDetail extends StatelessWidget {
  final RegionRepeater r;
  const _RepeaterDetail(this.r);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String v(Object? x, [String unit = '']) =>
        x == null ? 'unknown' : '$x$unit';
    final rows = <(String, String)>[
      (
        'Hash',
        '${r.hashPrefix}${r.hashSizeBytes == null ? '' : ' (${r.hashSizeBytes}-byte)'}${r.ambiguous ? ', shared with another node' : ''}',
      ),
      ('Status', r.status.name == 'fresh' ? 'new' : r.status.name),
      ('Last heard', lastSeenLabel(r.lastHeardAt)),
      (
        'SNR (24 h mean)',
        r.snrMeanDb == null
            ? 'unknown'
            : '${r.snrMeanDb!.toStringAsFixed(1)} dB',
      ),
      ('Neighbours', v(r.neighbours)),
      ('Relays / adverts (24 h)', '${v(r.relays24h)} / ${v(r.adverts24h)}'),
      (
        'Heard hours',
        r.heardHoursPct == null
            ? 'unknown'
            : '${r.heardHoursPct!.toStringAsFixed(0)}%',
      ),
      (
        'Position',
        r.hasPosition
            ? '${r.lat!.toStringAsFixed(5)}, ${r.lon!.toStringAsFixed(5)}'
            : 'not advertised',
      ),
      ('Key', r.key),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.displayName, style: t.textTheme.titleLarge),
          const SizedBox(height: Gap.s),
          for (final (k, val) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: Text(k, style: t.textTheme.bodySmall),
                  ),
                  Expanded(child: Text(val, style: t.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
