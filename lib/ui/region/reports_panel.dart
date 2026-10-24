// "Reports" panel for one region: the website's /reports page as a phone view. Daily trend, last-24-hour figures,
// notable events (new repeaters and links), network health, coverage, and which outside data sources (CoreScope,
// MeshCore Map) cover the region. Data: `region-report` + `region-sources` (lib/core/region_reports_api.dart).
//
// Honest states: loading; a region the server does not publish yet (404); network/server errors with Retry; a dataset
// the server marks partial/pending/stale is labelled as such; the two requests fail independently, so a failed
// Sources request never hides the report (and the reverse).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/region_reports_api.dart';
import '../theme.dart';

class ReportsPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seam: a client with a fake HTTP layer. Defaults to one built from [baseUrl].
  final RegionReportsApi? api;

  /// Test seam: "now" for relative times and for dropping future-dated buckets.
  final DateTime Function()? clock;

  const ReportsPanel({super.key, required this.baseUrl, required this.regionSlug, this.api, this.clock});

  @override
  State<ReportsPanel> createState() => _ReportsPanelState();
}

class _ReportsPanelState extends State<ReportsPanel> {
  late RegionReportsApi _api;
  bool _ownsApi = false;
  bool _loading = true;
  int _gen = 0;
  FetchResult<RegionReportData>? _report;
  FetchResult<RegionSourcesData>? _sources;

  DateTime _now() => (widget.clock ?? DateTime.now)().toUtc();

  @override
  void initState() {
    super.initState();
    _makeApi();
    _load();
  }

  void _makeApi() {
    _ownsApi = widget.api == null;
    _api = widget.api ?? RegionReportsApi(widget.baseUrl);
  }

  @override
  void didUpdateWidget(ReportsPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.api != widget.api) {
      if (_ownsApi) _api.close();
      _makeApi();
    }
    if (old.regionSlug != widget.regionSlug || old.baseUrl != widget.baseUrl || old.api != widget.api) _load();
  }

  @override
  void dispose() {
    if (_ownsApi) _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _report = null;
      _sources = null;
    });
    final slug = widget.regionSlug;
    final r = _api.fetchReport(slug);
    final s = _api.fetchSources(slug);
    final results = await Future.wait<Object>([r, s]);
    // A newer load (region switched) owns the screen now.
    if (!mounted || gen != _gen) return;
    setState(() {
      _report = results[0] as FetchResult<RegionReportData>;
      _sources = results[1] as FetchResult<RegionSourcesData>;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(key: Key('reports-loading')));
    }
    final report = _report!;
    final sources = _sources!;
    final children = <Widget>[];
    if (report.ok) {
      final d = report.data!;
      if (d.isEmpty) {
        children.add(const _Note(
            key: Key('reports-empty'),
            icon: Icons.hourglass_empty,
            text: 'No report data for this region yet. Nothing has been measured here, so there is nothing to show.'));
      } else {
        children.addAll(_reportSections(d));
      }
    } else {
      children.add(_ErrorCard(
        key: const Key('reports-error'),
        what: 'the report',
        error: report.error!,
        onRetry: _load,
      ));
    }
    children.add(_SourcesSection(result: sources, onRetry: _load, now: _now()));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('reports-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(Gap.l),
        children: children,
      ),
    );
  }

  List<Widget> _reportSections(RegionReportData d) {
    final now = _now();
    final out = <Widget>[
      _Header(d: d, now: now),
      const SizedBox(height: Gap.m),
    ];

    // Last 24 hours.
    out.add(_Section(
      title: 'Last 24 hours',
      status: d.overviewStatus,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          _Stat('Packets', _n(d.packets24h), key: const Key('stat-packets')),
          _Stat('Observers online', d.observersOnline == null ? '—' : '${d.observersOnline}${d.observersTotal == null ? '' : ' / ${d.observersTotal}'}',
              key: const Key('stat-observers')),
          _Stat('Repeaters heard', d.repeatersHeard24h == null ? '—' : '${d.repeatersHeard24h}${d.repeaters == null ? '' : ' / ${d.repeaters}'}',
              key: const Key('stat-repeaters')),
        ]),
        if (d.lastPacketAt != null) ...[
          const SizedBox(height: Gap.s),
          _Muted('Last packet ${_ago(d.lastPacketAt!, now)}'),
        ],
        if (d.packetsPerHour.isNotEmpty) ...[
          const SizedBox(height: Gap.m),
          const _Muted('Packets per hour'),
          const SizedBox(height: Gap.xs),
          _Bars(key: const Key('bars-hourly'), values: [for (final p in d.packetsPerHour) p.n]),
        ],
      ]),
    ));

    // Daily trend.
    final trend = _trend(d, now);
    out.add(_Section(
      title: 'Trend',
      status: d.activityStatus,
      child: trend.isEmpty
          ? const _Muted('No daily activity recorded yet.', key: Key('trend-empty'))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Muted('Packets per ${d.activityBucket}, last ${trend.length} ${d.activityBucket == 'hour' ? 'hours' : 'days'}'),
              const SizedBox(height: Gap.xs),
              _Bars(key: const Key('bars-trend'), values: [for (final p in trend) p.n]),
              const SizedBox(height: Gap.xs),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                _Muted(_dayLabel(trend.first.at)),
                _Muted('${_n(trend.fold<int>(0, (a, b) => a + b.n))} total'),
                _Muted(_dayLabel(trend.last.at)),
              ]),
            ]),
    ));

    // Notable events.
    out.add(_Section(
      title: 'Notable events',
      status: d.overviewStatus,
      child: d.events.isEmpty
          ? const _Muted('No new repeaters or links reported recently.', key: Key('events-empty'))
          : Column(key: const Key('events-list'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final e in d.events.take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(_eventIcon(e.type), size: 18),
                    const SizedBox(width: Gap.s),
                    Expanded(child: Text(e.detail)),
                    if (e.at != null) Padding(padding: const EdgeInsets.only(left: Gap.s), child: _Muted(_ago(e.at!, now))),
                  ]),
                ),
              if (d.events.length > 8) _Muted('and ${d.events.length - 8} more'),
            ]),
    ));

    // Network health.
    final c = d.repeaterCounts;
    final haveCounts = c.active != null || c.quiet != null || c.fresh != null || c.stale != null;
    out.add(_Section(
      title: 'Network health',
      status: _worst([d.repeatersStatus, d.pathsStatus, d.hashStatus, d.rfStatus]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (haveCounts)
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            _Stat('Active', _n(c.active), key: const Key('stat-active')),
            _Stat('Quiet', _n(c.quiet)),
            _Stat('New', _n(c.fresh)),
            _Stat('Stale', _n(c.stale)),
          ])
        else
          const _Muted('Repeater activity not available.'),
        const SizedBox(height: Gap.m),
        if (d.floodShare != null) _Line('Flood-routed packets', '${(d.floodShare! * 100).round()}%'),
        if (d.noiseMeanDbm != null) _Line('Mean noise floor', '${d.noiseMeanDbm!.round()} dBm'),
        if (d.hashSizes.isNotEmpty)
          _Line('Hash sizes', [for (final h in d.hashSizes) '${h.bytes}-byte: ${h.nodes}'].join('  ·  ')),
        if (d.hashCollisions != null) _Line('Hash collisions', '${d.hashCollisions}'),
      ]),
    ));

    // Coverage.
    out.add(_Section(
      title: 'Drive coverage',
      status: null,
      child: !d.coverageKnown
          ? const _Muted('No coverage measured yet.', key: Key('coverage-empty'))
          : Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              _Stat('Cells', _n(d.coverageCells)),
              _Stat('Drives', _n(d.coverageDrives)),
              if (d.coverageKm != null) _Stat('Distance', '${d.coverageKm!.round()} km'),
              if (d.coverageHeardPct != null) _Stat('Heard', '${d.coverageHeardPct!.round()}%'),
            ]),
    ));
    return out;
  }

  /// Last 14 buckets that have started (the server pads the series with future-dated empty buckets).
  List<TimeCount> _trend(RegionReportData d, DateTime now) {
    final past = d.activity.where((p) => !p.at.isAfter(now)).toList()..sort((a, b) => a.at.compareTo(b.at));
    final n = d.activityBucket == 'hour' ? 24 : 14;
    return past.length <= n ? past : past.sublist(past.length - n);
  }
}

// ---------------------------------------------------------------- sources
class _SourcesSection extends StatelessWidget {
  final FetchResult<RegionSourcesData> result;
  final VoidCallback onRetry;
  final DateTime now;
  const _SourcesSection({required this.result, required this.onRetry, required this.now});

  @override
  Widget build(BuildContext context) {
    if (!result.ok) {
      final e = result.error!;
      return _Section(
        title: 'Sources',
        status: null,
        child: e.kind == FetchErrorKind.notFound
            ? const _Muted('Source coverage is not published for this region.', key: Key('sources-unavailable'))
            : _ErrorCard(key: const Key('sources-error'), what: 'source coverage', error: e, onRetry: onRetry),
      );
    }
    final data = result.data!;
    return _Section(
      title: 'Sources',
      status: data.status,
      child: data.sources.isEmpty
          ? const _Muted('No outside data sources are configured for this region. Figures above come from MeshSonar observers only.',
              key: Key('sources-empty'))
          : Column(key: const Key('sources-list'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              const _Muted('Other services that report nodes in this region.'),
              const SizedBox(height: Gap.s),
              for (final s in data.sources) _SourceTile(s: s, now: now),
            ]),
    );
  }
}

class _SourceTile extends StatelessWidget {
  final RegionSource s;
  final DateTime now;
  const _SourceTile({required this.s, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final warn = <String>[
      if (!s.enabled) 'Disabled',
      if (s.neverSucceeded && s.enabled) 'No successful pull yet, so the counts are not real',
      if (s.stale && !s.neverSucceeded) 'Stale: last good data ${_ago(s.lastOkAt!, now)}',
      if (s.prototypeOnly) 'Prototype only: verify with the operator before public release',
    ];
    return Padding(
      key: ValueKey('source-${s.name}'),
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(s.name, style: t.textTheme.titleSmall)),
          _Chip(s.kindLabel),
        ]),
        const SizedBox(height: Gap.xs),
        Text(
          s.neverSucceeded && s.nodes == 0 && s.observers == 0
              ? 'Nodes —   Observers —'
              : 'Nodes ${s.nodes}   Observers ${s.observers}   Links ${s.edges}',
          style: t.textTheme.bodyMedium,
        ),
        if (!s.neverSucceeded && !s.stale) _Muted('Updated ${_ago(s.lastOkAt!, now)}'),
        for (final w in warn) _Muted(w, color: t.colorScheme.error),
        if (s.attribution != null) _Muted('Data: ${s.attribution}'),
      ]),
    );
  }
}

// ---------------------------------------------------------------- pieces
class _Header extends StatelessWidget {
  final RegionReportData d;
  final DateTime now;
  const _Header({required this.d, required this.now});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(d.name.isEmpty ? 'Region report' : d.name, style: t.textTheme.titleLarge),
      if (d.generatedAt != null) _Muted('Generated ${_ago(d.generatedAt!, now)}'),
    ]);
  }
}

class _Section extends StatelessWidget {
  final String title;
  final DataStatus? status;
  final Widget child;
  const _Section({required this.title, required this.status, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: t.textTheme.titleMedium)),
            if (status != null && status!.degraded) _StatusBadge(status!),
          ]),
          if (status != null && status!.degraded && status!.reason != null) _Muted(status!.reason!),
          const SizedBox(height: Gap.s),
          child,
        ]),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final DataStatus s;
  const _StatusBadge(this.s);
  @override
  Widget build(BuildContext context) => _Chip(
        switch (s.state) {
          DataState.partial => 'Partial',
          DataState.pending => 'Pending',
          DataState.unavailable => 'Unavailable',
          DataState.stale => 'Stale',
          _ => 'Unverified',
        },
        key: Key('status-${s.state.name}'),
        warn: true,
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final bool warn;
  const _Chip(this.text, {super.key, this.warn = false});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 2),
      decoration: BoxDecoration(
        color: warn ? cs.errorContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Corners.chip),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: warn ? cs.onErrorContainer : null)),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  const _Stat(this.label, this.value, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.small)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: t.textTheme.titleLarge),
        Text(label, style: t.textTheme.labelSmall),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  final String label, value;
  const _Line(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _Muted(label)),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ]),
      );
}

class _Muted extends StatelessWidget {
  final String text;
  final Color? color;
  const _Muted(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(text, style: t.textTheme.bodySmall?.copyWith(color: color ?? t.colorScheme.onSurfaceVariant));
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Note({super.key, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xl),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text)),
        ]),
      );
}

class _ErrorCard extends StatelessWidget {
  final String what;
  final RegionFetchError error;
  final VoidCallback onRetry;
  const _ErrorCard({super.key, required this.what, required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final notFound = error.kind == FetchErrorKind.notFound;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(notFound ? Icons.info_outline : Icons.cloud_off, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: Gap.m),
          Expanded(
              child: Text(notFound
                  ? 'The server has not published $what for this region yet.'
                  : 'Could not load $what: ${error.message}.')),
        ]),
        const SizedBox(height: Gap.s),
        TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
      ]),
    );
  }
}

/// Plain bar strip; the tallest bar fills the height. A value of 0 still draws a hairline so the axis reads.
class _Bars extends StatelessWidget {
  final List<int> values;
  const _Bars({super.key, required this.values});
  @override
  Widget build(BuildContext context) {
    final max = values.fold<int>(0, (a, b) => b > a ? b : a);
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 56,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final v in values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: FractionallySizedBox(
                heightFactor: max == 0 ? 0.03 : (v / max).clamp(0.03, 1.0),
                alignment: Alignment.bottomCenter,
                child: ColoredBox(color: color),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- formatting
DataStatus? _worst(List<DataStatus> all) {
  const order = [DataState.unavailable, DataState.pending, DataState.partial, DataState.stale, DataState.unknown];
  for (final s in order) {
    for (final x in all) {
      if (x.state == s) return x;
    }
  }
  return null;
}

String _n(int? v) {
  if (v == null) return '—';
  final s = v.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return v < 0 ? '-$b' : b.toString();
}

String _ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.isNegative || d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 60) return '${d.inDays} d ago';
  return _dayLabel(t);
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _dayLabel(DateTime t) => '${_months[t.month - 1]} ${t.day}';

IconData _eventIcon(String type) {
  if (type.startsWith('repeater')) return Icons.cell_tower;
  if (type.startsWith('link')) return Icons.link;
  return Icons.notifications_none;
}
