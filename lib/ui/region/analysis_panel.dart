// "Analysis" panel for one region, mirroring the website's /analysis page: role mix, hash-size mix, busiest-hour
// heatmap (last 7 days, phone-local time), hop spread and top carrying repeaters. Data: lib/core/region_analysis_api.dart.
// Honest states: loading, error (retry), empty, and per-section partial/pending notices that quote the server's
// status.reason. Firmware mix is omitted: no public endpoint serves it yet.
import 'package:flutter/material.dart';

import '../../core/region_analysis_api.dart';
import '../charts/heatmap.dart';
import '../theme.dart';

class AnalysisPanel extends StatefulWidget {
  /// Region host, the region's own subdomain (the server picks the region by host).
  final String baseUrl;
  final String regionSlug;

  /// Test seam; production builds the API from [baseUrl].
  final RegionAnalysisApi? api;
  const AnalysisPanel({super.key, required this.baseUrl, required this.regionSlug, this.api});

  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  late Future<RegionAnalysis> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(AnalysisPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) _retry();
  }

  Future<RegionAnalysis> _load() => (widget.api ?? RegionAnalysisApi(widget.baseUrl)).fetch();
  void _retry() => setState(() {
        _future = _load();
      });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RegionAnalysis>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(key: Key('analysis-loading'), child: CircularProgressIndicator());
        }
        final a = snap.data;
        if (a == null || a.allFailed) {
          final why = a?.activity.error ?? 'Could not load analysis.';
          return _Notice(
            key: const Key('analysis-error'),
            icon: Icons.cloud_off,
            text: 'Analysis for ${widget.regionSlug.toUpperCase()} is unavailable. $why',
            onRetry: _retry,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            _retry();
            await _future;
          },
          child: ListView(
            key: const Key('analysis-list'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Text('${widget.regionSlug.toUpperCase()} analysis', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.m),
              if (a.anyFailed)
                _Notice(
                  key: const Key('analysis-partial'),
                  icon: Icons.warning_amber,
                  text: 'Some sections could not load. Showing the rest.',
                  onRetry: _retry,
                ),
              _roles(a.roles),
              _hash(a.hash),
              _heat(a.activity),
              _paths(a.paths),
            ],
          ),
        );
      },
    );
  }

  Widget _roles(Section<RoleMix> s) => _Card(
        title: 'Role mix',
        section: s,
        status: s.data?.status,
        empty: s.data != null && s.data!.total == 0,
        builder: (d) => Column(children: [
          for (final e in (d.roles.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            _BarRow(label: _cap(e.key), value: e.value, max: d.total, trailing: '${e.value}'),
          if (d.states.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(d.states.entries.map((e) => '${e.value} ${e.key}').join(' · '),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
        ]),
      );

  Widget _hash(Section<HashStats> s) => _Card(
        title: 'Hash sizes',
        section: s,
        status: s.data?.status,
        empty: s.data != null && s.data!.sizes.isEmpty,
        builder: (d) {
          final total = d.sizes.fold(0, (a, h) => a + h.nodes);
          return Column(children: [
            for (final h in d.sizes)
              _BarRow(label: '${h.bytes}-byte', value: h.nodes, max: total, trailing: '${h.nodes} nodes'),
            if (d.collisionPrefixes > 0)
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('${d.collisionPrefixes} shared prefixes (collisions)',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
          ]);
        },
      );

  Widget _heat(Section<RegionActivity> s) => _Card(
        title: 'Busiest hours',
        section: s,
        status: s.data?.status,
        empty: s.data != null && s.data!.total == 0,
        builder: (d) => _Heatmap(grid: d.heatmap()),
      );

  Widget _paths(Section<PathStats> s) => _Card(
        title: 'Hops and top repeaters',
        section: s,
        status: s.data?.status,
        empty: s.data != null && s.data!.totalPackets == 0 && s.data!.carriers.isEmpty,
        builder: (d) {
          final hist = d.hopHistogram.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
          final maxN = hist.fold(0, (a, e) => e.value > a ? e.value : a);
          final mean = d.meanHops;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              [
                if (mean != null) 'Average ${mean.toStringAsFixed(1)} hops',
                if (d.floodShare != null) '${(d.floodShare! * 100).round()}% flooded',
              ].join(' · '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.s),
            for (final e in hist.take(12))
              _BarRow(label: '${e.key} hop${e.key == 1 ? '' : 's'}', value: e.value, max: maxN, trailing: '${e.value}'),
            if (hist.length > 12)
              Text('${hist.length - 12} longer paths not shown', style: Theme.of(context).textTheme.bodySmall),
            if (d.carriers.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              Text('Carry the most traffic', style: Theme.of(context).textTheme.titleSmall),
              for (final c in d.carriers.take(8))
                _BarRow(
                    label: c.name ?? '${c.key.substring(0, c.key.length < 8 ? c.key.length : 8)}…',
                    value: (c.share * 1000).round(),
                    max: 1000,
                    trailing: '${(c.share * 100).round()}%'),
            ],
          ]);
        },
      );
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onRetry;
  const _Notice({super.key, required this.icon, required this.text, required this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Row(children: [
          Icon(icon),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );
}

class _Card<T> extends StatelessWidget {
  final String title;
  final Section<T> section;
  final RegionStatus? status;
  final bool empty;
  final Widget Function(T data) builder;
  const _Card({required this.title, required this.section, required this.status, required this.empty, required this.builder});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = status;
    final d = section.data;
    Widget body;
    if (d == null) {
      body = Text('Could not load: ${section.error}', key: Key('section-error-$title'));
    } else if (empty) {
      body = Text(
        st != null && !st.isReady && st.reason != null ? 'No data yet. ${st.reason}' : 'No data yet.',
        key: Key('section-empty-$title'),
      );
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (st != null && !st.isReady)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Text(
              '${st.state[0].toUpperCase()}${st.state.substring(1)}${st.reason != null ? ': ${st.reason}' : ''}',
              key: Key('section-status-$title'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.tertiary),
            ),
          ),
        builder(d),
      ]);
    }
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.s),
          body,
        ]),
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  final String label, trailing;
  final int value, max;
  const _BarRow({required this.label, required this.value, required this.max, required this.trailing});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 110, child: Text(label, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: f, minHeight: 10, color: t.colorScheme.primary),
          ),
        ),
        SizedBox(width: 72, child: Text(trailing, textAlign: TextAlign.right, style: t.textTheme.bodySmall)),
      ]),
    );
  }
}

class _Heatmap extends StatelessWidget {
  final List<List<int>> grid;
  const _Heatmap({required this.grid});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    var peak = 0, pd = 0, ph = 0;
    for (var d = 0; d < 7; d++) {
      for (var h = 0; h < 24; h++) {
        if (grid[d][h] > peak) {
          peak = grid[d][h];
          pd = d;
          ph = h;
        }
      }
    }
    const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        label: 'Packets by weekday and hour, busiest ${days[pd]} ${_hour(ph)}',
        child: SizedBox(
          height: 7 * 18.0 + 16,
          width: double.infinity,
          child: CustomPaint(
            key: const Key('analysis-heatmap'),
            painter: HeatmapPainter(grid, t.colorScheme.primary, t.colorScheme.surfaceContainerHighest, t.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
      const SizedBox(height: Gap.s),
      Text('Last 7 days, your phone\'s local time. Busiest: ${days[pd]} ${_hour(ph)} ($peak packets).',
          style: t.textTheme.bodySmall),
    ]);
  }

  static String _hour(int h) => '${h % 12 == 0 ? 12 : h % 12} ${h < 12 ? 'AM' : 'PM'}';
}

