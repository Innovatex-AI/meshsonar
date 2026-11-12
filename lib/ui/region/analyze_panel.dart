// The Analyze view of the Analyze tab (AN-1, app side of the website's /analysis?tab=analyze). Same four sections, same figures,
// same states: findings (E9, plain language), network health (E6 + E8 events), traffic (E3) with the source chip, node-list check (E4).
// Every section has its own honest state (docs/analyze-contract.md): loading, error (Try again), none ("Not available in {region}
// yet"), stale (older than 36 h: a banner, the older figures dimmed below it) and ready ("Updated {time}"). Times are in the region's
// own zone. The engine builds per region, so there is no union to show: the region switcher above picks the region (it lists every
// region, groups and the hub never appear as a region here). Model and rules: lib/core/analyze_model.dart.
import 'package:flutter/material.dart';

import '../../core/analyze_api.dart';
import '../../core/analyze_model.dart';
import '../../core/zone_time.dart';
import '../theme.dart';
import 'repeater_detail_screen.dart' show openRepeaterDetail;

class AnalyzePanel extends StatefulWidget {
  /// Region host (the server picks the region by host).
  final String baseUrl;
  final String regionSlug;
  final String regionName;

  /// The region's IANA zone; null shows UTC and says so.
  final String? timezone;

  /// Test seams.
  final AnalyzeApi? api;
  final DateTime Function() now;
  const AnalyzePanel({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
    required this.regionName,
    this.timezone,
    this.api,
    this.now = DateTime.now,
  });

  @override
  State<AnalyzePanel> createState() => _AnalyzePanelState();
}

class _AnalyzePanelState extends State<AnalyzePanel> {
  late AnalyzeApi _api;
  late Future<AnalyzeRead<List<DatasetStatus>>> _statuses;
  late Future<AnalyzeRead<InsightsRead>> _insights;
  late Future<AnalyzeRead<RepeaterHealthRead>> _health;
  late Future<AnalyzeRead<List<AnalyzeEvent>>> _events;
  late Future<AnalyzeRead<TrafficRead>> _traffic;
  late Future<AnalyzeRead<NodeGateRead>> _gate;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void didUpdateWidget(AnalyzePanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl) _loadAll();
  }

  void _loadAll() {
    _api = widget.api ?? AnalyzeApi(widget.baseUrl);
    _statuses = _api.statuses();
    _insights = _api.insights();
    _health = _api.health();
    _events = _api.events();
    _traffic = _api.traffic();
    _gate = _api.gate();
  }

  Future<void> _refresh() async {
    setState(_loadAll);
    await Future.wait<Object?>([_statuses, _insights, _health, _events, _traffic, _gate]);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.regionName;
    final tz = widget.timezone;
    final now = widget.now();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const Key('analyze-list'),
        padding: const EdgeInsets.all(Gap.m),
        children: [
          _Section<InsightsRead>(
            id: 'an-findings',
            title: 'What needs attention',
            lead: 'Findings the analysis engine rebuilds every night from this region\'s own figures. Nothing is listed unless the data backs it.',
            read: _insights,
            statuses: _statuses,
            datasetKey: 'network.findings',
            region: name,
            tz: tz,
            now: now,
            judge: (d) => (d.status, d.builtAt),
            onRetry: () {
              setState(() {
                _insights = _api.insights();
              });
            },
            body: (c, d) => _FindingsBody(d, widget.baseUrl, widget.regionSlug, tz),
          ),
          _Section<RepeaterHealthRead>(
            id: 'an-health',
            title: 'Network health',
            lead: 'Repeaters heard, which ones carry the traffic and how reliable they are, from every source.',
            read: _health,
            statuses: _statuses,
            datasetKey: 'network.snapshots',
            region: name,
            tz: tz,
            now: now,
            judge: (d) => (d.status, d.builtAt),
            onRetry: () => setState(() {
              _health = _api.health();
              _events = _api.events();
            }),
            body: (c, d) => _HealthBody(d, _events, widget.baseUrl, widget.regionSlug, tz),
          ),
          _Section<TrafficRead>(
            id: 'an-traffic',
            title: 'Traffic',
            lead: 'Packets heard in the last 24 closed hours by our observers, phones and outside feeds, each packet counted once.',
            read: _traffic,
            statuses: _statuses,
            datasetKey: 'network.packets',
            region: name,
            tz: tz,
            now: now,
            judge: (d) => (d.status, d.builtAt),
            onRetry: () {
              setState(() {
                _traffic = _api.traffic();
              });
            },
            body: (c, d) => _TrafficBody(d, tz),
          ),
          _Section<NodeGateRead>(
            id: 'an-gate',
            title: 'Node list check',
            lead: 'Whether the repeaters this page names are enough to place the relays seen in recent packets.',
            read: _gate,
            statuses: _statuses,
            datasetKey: null,
            region: name,
            tz: tz,
            now: now,
            // The gate has no status block of its own: it is judged on its newest stored day.
            judge: (d) => (
              EngineStatus(
                d.gate != null || d.history.isNotEmpty ? 'ready' : 'pending',
                d.gate != null ? null : 'The node-list check has not run for this region yet.',
              ),
              d.history.isNotEmpty ? d.history.last.builtAt : d.gate?.computedAt,
            ),
            onRetry: () {
              setState(() {
                _gate = _api.gate();
              });
            },
            body: (c, d) => _GateBody(d),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- the state shell shared by every section
class _Section<T extends Object> extends StatefulWidget {
  final String id, title, lead, region;
  final Future<AnalyzeRead<T>> read;
  final Future<AnalyzeRead<List<DatasetStatus>>> statuses;
  final String? datasetKey;
  final String? tz;
  final DateTime now;
  final (EngineStatus, DateTime?) Function(T data) judge;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) body;
  const _Section({
    required this.id,
    required this.title,
    required this.lead,
    required this.read,
    required this.statuses,
    required this.datasetKey,
    required this.region,
    required this.tz,
    required this.now,
    required this.judge,
    required this.onRetry,
    required this.body,
  });

  @override
  State<_Section<T>> createState() => _SectionState<T>();
}

class _SectionState<T extends Object> extends State<_Section<T>> {
  late Future<(AnalyzeRead<T>, List<DatasetStatus>)> _both = _join();

  Future<(AnalyzeRead<T>, List<DatasetStatus>)> _join() async =>
      (await widget.read, (await widget.statuses).data ?? const <DatasetStatus>[]);

  @override
  void didUpdateWidget(_Section<T> old) {
    super.didUpdateWidget(old);
    if (!identical(old.read, widget.read) || !identical(old.statuses, widget.statuses)) {
      _both = _join();
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final id = w.id,
        title = w.title,
        lead = w.lead,
        region = w.region,
        tz = w.tz,
        now = w.now,
        datasetKey = w.datasetKey,
        onRetry = w.onRetry;
    final judge = w.judge, body = w.body;
    final t = Theme.of(context);
    return Card(
      key: Key(id),
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: t.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(lead, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.m),
            FutureBuilder<(AnalyzeRead<T>, List<DatasetStatus>)>(
              future: _both,
              builder: (context, snap) {
                final r = snap.data;
                if (r == null) return _loading();
                final (rd, all) = r;
                final data = rd.data;
                final (st, built) = data == null ? (null, null) : judge(data);
                final v = sectionVerdict(
                  loading: false,
                  failed: rd.failed,
                  status: st,
                  builtAt: built,
                  dataset: datasetKey == null ? null : datasetFor(all, datasetKey),
                  now: now,
                );
                return switch (v.state) {
                  SectionState.loading => _loading(),
                  SectionState.error => _stateBox(
                    context,
                    'error',
                    'This did not load',
                    rd.error ?? v.reason ?? 'The analysis engine reported an error for this section.',
                    onRetry: onRetry,
                  ),
                  SectionState.none => _stateBox(
                    context,
                    'none',
                    'Not available in $region yet',
                    v.reason ??
                        'Nothing has been built for this region yet. It appears here after the next engine run.',
                  ),
                  SectionState.stale => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    key: Key('$id-stale'),
                    children: [
                      _stateBox(
                        context,
                        'stale-banner',
                        'Out of date: not shown as current',
                        'Last built ${v.builtAt == null ? 'a long time ago' : formatInZone(v.builtAt, tz)}, more than 36 hours ago. What follows is that older result, not the network as it is now.',
                      ),
                      const SizedBox(height: Gap.m),
                      Opacity(opacity: .55, child: body(context, data!)),
                    ],
                  ),
                  SectionState.ready => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    key: Key('$id-ready'),
                    children: [body(context, data!), if (v.builtAt != null) _updated(context, v.builtAt!, tz)],
                  ),
                };
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _loading() => SizedBox(
    key: Key('${widget.id}-loading'),
    height: 72,
    child: const Center(child: CircularProgressIndicator()),
  );

  Widget _stateBox(BuildContext context, String kind, String headline, String reason, {VoidCallback? onRetry}) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final isErr = kind == 'error';
    final isStale = kind == 'stale-banner';
    final fg = isErr ? c.onErrorContainer : c.onSurface;
    return Container(
      key: Key('${widget.id}-$kind'),
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: isErr
            ? c.errorContainer
            : isStale
            ? MeshSonarColors.of(context).beacon.withValues(alpha: .18)
            : c.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corners.chip),
        border: Border.all(color: isErr ? c.error : c.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: t.textTheme.titleSmall?.copyWith(color: fg)),
          const SizedBox(height: Gap.xs),
          Text(reason, style: t.textTheme.bodySmall?.copyWith(color: fg)),
          if (onRetry != null) ...[
            const SizedBox(height: Gap.s),
            OutlinedButton(key: Key('${widget.id}-retry'), onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}

Widget _updated(BuildContext context, DateTime at, String? tz) {
  final t = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(top: Gap.m),
    child: Text(
      'Updated ${formatInZone(at, tz)}',
      key: const Key('updated'),
      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
    ),
  );
}

// ---------------------------------------------------------------- small pieces
class _Stat extends StatelessWidget {
  final String label, value;
  final String? hint;
  const _Stat(this.label, this.value, {this.hint});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: Key('stat:$label'),
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corners.chip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          Text(value, key: Key('stat-value:$label'), style: t.textTheme.titleMedium),
          if (hint != null) Text(hint!, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

Widget _stats(List<Widget> chips) => Wrap(spacing: Gap.s, runSpacing: Gap.s, children: chips);

class _H3 extends StatelessWidget {
  final String text;
  const _H3(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _BarRow extends StatelessWidget {
  final String label, trailing;
  final double value, max;
  const _BarRow(this.label, this.value, this.max, this.trailing);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: max <= 0 ? 0 : (value / max).clamp(0.0, 1.0),
                minHeight: 10,
                color: t.colorScheme.primary,
              ),
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(trailing, textAlign: TextAlign.right, style: t.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// A compact column chart: one bar per value, the first and last label under it.
class _MiniBars extends StatelessWidget {
  final List<double> values;
  final String first, last;
  final String semantics;
  const _MiniBars({super.key, required this.values, required this.first, required this.last, required this.semantics});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final max = values.fold<double>(0, (a, b) => b > a ? b : a);
    return Semantics(
      label: semantics,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final v in values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: FractionallySizedBox(
                        heightFactor: max <= 0 ? 0.02 : (v / max).clamp(0.02, 1.0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: t.colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(first, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              Text(last, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _RepeaterLink extends StatelessWidget {
  final String repeaterKey;
  final String label;
  final String baseUrl, slug;
  const _RepeaterLink({required this.repeaterKey, required this.label, required this.baseUrl, required this.slug});
  @override
  Widget build(BuildContext context) => GestureDetector(
    key: Key('repeater-link:$repeaterKey'),
    behavior: HitTestBehavior.opaque,
    onTap: () => openRepeaterDetail(context, baseUrl: baseUrl, regionSlug: slug, repeaterKey: repeaterKey),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        label,
        style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline),
      ),
    ),
  );
}

// ---------------------------------------------------------------- E9
class _FindingsBody extends StatelessWidget {
  final InsightsRead d;
  final String baseUrl, slug;
  final String? tz;
  const _FindingsBody(this.d, this.baseUrl, this.slug, this.tz);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rows = sortFindings(d.rows);
    if (rows.isEmpty) {
      return Column(
        key: const Key('findings-none-needed'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Nothing needs attention', style: t.textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Text(d.status.reason ?? 'Nothing in this region\'s figures needs attention.', style: t.textTheme.bodySmall),
        ],
      );
    }
    final m = MeshSonarColors.of(context);
    Color tone(String s) => switch (s) {
      'alert' => t.colorScheme.error,
      'warn' => m.beacon,
      _ => t.colorScheme.outline,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++)
          Padding(
            key: Key('finding:${rows[i].code}'),
            padding: const EdgeInsets.only(bottom: Gap.m),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(right: Gap.s, top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: tone(rows[i].severity).withValues(alpha: .2),
                    borderRadius: BorderRadius.circular(Corners.chip),
                  ),
                  child: Text(
                    severityWord[rows[i].severity] ?? 'Note',
                    style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: rows[i].title,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            TextSpan(text: ' ${rows[i].detail}'),
                          ],
                        ),
                      ),
                      Text(
                        sectionWord[rows[i].section] ?? rows[i].section,
                        style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                      for (final k in rows[i].refs.take(5))
                        _RepeaterLink(
                          repeaterKey: k,
                          label: '${k.length > 8 ? k.substring(0, 8) : k}…',
                          baseUrl: baseUrl,
                          slug: slug,
                        ),
                      if (rows[i].refs.length > 5)
                        Text('and ${rows[i].refs.length - 5} more', style: t.textTheme.labelSmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- E6 + E8
class _HealthBody extends StatelessWidget {
  final RepeaterHealthRead d;
  final Future<AnalyzeRead<List<AnalyzeEvent>>> events;
  final String baseUrl, slug;
  final String? tz;
  const _HealthBody(this.d, this.events, this.baseUrl, this.slug, this.tz);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = d.counts;
    final top = busiest(d.rows), weak = leastReliable(d.rows);
    String name(RepeaterHealthRow r) => r.name ?? '${r.key.length > 8 ? r.key.substring(0, 8) : r.key}…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c != null)
          _stats([
            _Stat('Repeaters and rooms', formatInt(c.nodes)),
            _Stat('Heard in 24 h', formatInt(c.heard24h)),
            _Stat('Silent for 24 h', formatInt(c.silent24h)),
            _Stat('Relaying in 24 h', formatInt(c.relaying24h)),
          ]),
        if (top.isNotEmpty) ...[
          const _H3('Carrying the most traffic'),
          for (final r in top)
            Row(
              key: Key('busy:${r.key}'),
              children: [
                Expanded(
                  child: _RepeaterLink(repeaterKey: r.key, label: name(r), baseUrl: baseUrl, slug: slug),
                ),
                Text(
                  '${formatInt(r.relays24h)} relayed · ${uptimeText(r.uptime7d)} up · ${r.snrMean7d == null ? '—' : '${snrText(r.snrMean7d)} dB'}',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
          Text(
            'Relayed in the last 24 h · uptime over 7 days · mean SNR over 7 days.',
            style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
        if (weak.isNotEmpty) ...[
          const _H3('Least reliable'),
          for (final r in weak)
            Row(
              key: Key('weak:${r.key}'),
              children: [
                Expanded(
                  child: _RepeaterLink(repeaterKey: r.key, label: name(r), baseUrl: baseUrl, slug: slug),
                ),
                Text(
                  '${uptimeText(r.uptime7d)} up · last heard ${formatInZone(r.lastHeardAt, tz)}',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
        ],
        const _H3('Recent changes'),
        FutureBuilder<AnalyzeRead<List<AnalyzeEvent>>>(
          future: events,
          builder: (context, snap) {
            final r = snap.data;
            if (r == null) {
              return const SizedBox(
                height: 24,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              );
            }
            final list = r.data;
            if (list == null) {
              return Text(
                'Recent changes did not load: ${r.error}',
                key: const Key('events-error'),
                style: t.textTheme.bodySmall,
              );
            }
            if (list.isEmpty) {
              return Text(
                'No repeater or link changes were recorded recently.',
                key: const Key('events-empty'),
                style: t.textTheme.bodySmall,
              );
            }
            return Column(
              key: const Key('events-list'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: eventWord[e.type] ?? e.type,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: ': ${e.detail} '),
                          TextSpan(
                            text: formatInZone(e.at, tz),
                            style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- E3
class _TrafficBody extends StatelessWidget {
  final TrafficRead d;
  final String? tz;
  const _TrafficBody(this.d, this.tz);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = trafficFigures(d);
    final chip = sourceChip(d);
    final flood = floodShare(d.rows);
    final hops = hopHistogram(d.rows);
    final snr = snrBars(d.rows);
    final types = packetsByType(d.rows);
    final typeMax = types.values.fold<int>(0, (a, b) => b > a ? b : a);
    final hopMax = hops.fold<int>(0, (a, b) => b.n > a ? b.n : a);
    final series = allRows(d.rows).where((r) => r.at != null).toList()..sort((a, b) => a.at!.compareTo(b.at!));
    final abbr = series.isEmpty ? zoneAbbr(tz, DateTime.now()) : zoneAbbr(tz, series.first.at!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chip != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Text(
              'Heard by $chip',
              key: const Key('source-chip'),
              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        _stats([
          _Stat('Packets', f.packets, hint: 'Each counted once'),
          _Stat('Observations', f.observations, hint: 'Every observer\'s copy'),
          _Stat('Observers', f.observers),
          _Stat('Mean SNR', d.snrMeanDb == null ? f.snr : '${f.snr} dB'),
          _Stat('Flooded', flood == null ? '—' : formatPct(flood, 0), hint: 'Repeated by every repeater that hears it'),
        ]),
        if (series.length > 1) ...[
          _H3('Packets per ${d.bucket}'),
          _MiniBars(
            key: const Key('traffic-series'),
            values: [for (final r in series) r.packets.toDouble()],
            first: formatInZone(series.first.at, tz),
            last: formatInZone(series.last.at, tz),
            semantics: 'Packets per ${d.bucket}, time axis in $abbr',
          ),
          Text('Time axis in $abbr.', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
        if (types.isNotEmpty) ...[
          const _H3('Packets by type'),
          for (final e in types.entries)
            _BarRow(packetTypeName(e.key), e.value.toDouble(), typeMax.toDouble(), formatInt(e.value)),
        ],
        if (hops.isNotEmpty) ...[
          const _H3('Hops per packet'),
          for (final h in hops)
            _BarRow('${h.hops} ${h.hops == 1 ? 'hop' : 'hops'}', h.n.toDouble(), hopMax.toDouble(), formatInt(h.n)),
        ],
        if (snr.isNotEmpty) ...[
          const _H3('SNR of received packets (dB)'),
          _MiniBars(
            key: const Key('snr-bars'),
            values: [for (final b in snr) b.n.toDouble()],
            first: '${snr.first.snr} dB',
            last: '${snr.last.snr} dB',
            semantics: 'SNR histogram from ${snr.first.snr} to ${snr.last.snr} dB',
          ),
        ],
        if (d.obsFlagged > 0)
          Padding(
            padding: const EdgeInsets.only(top: Gap.m),
            child: Text(
              '${formatInt(d.obsFlagged)} observations come from observers with a data-quality flag. They are counted, not hidden.',
              style: t.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- E4
class _GateBody extends StatelessWidget {
  final NodeGateRead d;
  const _GateBody(this.d);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final g = d.gate;
    final days = d.history.length > 30 ? d.history.sublist(d.history.length - 30) : d.history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (g == null)
          Text(
            'The check could not be read. The stored daily record is below; today\'s check did not answer.',
            key: const Key('gate-unreadable'),
            style: t.textTheme.bodySmall,
          )
        else if (g.trusted)
          Text.rich(
            key: const Key('gate-verdict'),
            TextSpan(
              children: [
                const TextSpan(
                  text: 'Complete. ',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: g.reason),
              ],
            ),
          )
        else
          Text.rich(
            key: const Key('gate-verdict'),
            TextSpan(
              children: [
                TextSpan(
                  text: '${describeNodeList(g).title}. ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: describeNodeList(g).body),
              ],
            ),
          ),
        if (g != null) ...[
          const SizedBox(height: Gap.m),
          _stats([
            _Stat('Hop codes known', '${formatInt(g.known)} of ${formatInt(g.total)}', hint: 'Last ${g.windowH} h'),
            _Stat('Match rate', formatPct(g.ratio, 0)),
            _Stat('Placed on traffic', formatPct(g.packetRatio, 0)),
          ]),
        ],
        if (days.isNotEmpty) ...[
          const _H3('Match rate by day'),
          _MiniBars(
            key: const Key('gate-days'),
            values: [for (final x in days) (x.ratio ?? 0) * 100],
            first: days.first.day,
            last: days.last.day,
            semantics: 'Node list match rate by UTC day',
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(
            'Daily results are UTC days. ${d.hopsFrom == 'e3' ? 'Hop codes come from every source that heard the region.' : 'Hop codes come from this region\'s own observers only.'}',
            style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
