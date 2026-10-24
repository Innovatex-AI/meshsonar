// "Repeater detail": what the website shows when you open a repeater (`/repeaters/$key`), as a phone screen.
// Data: `region-repeater` on the region host (lib/core/repeater_detail_api.dart). Every state is honest: loading,
// not found in this region, offline/error with retry, and the server's own `Sourced` state (partial / pending /
// stale / unavailable) shown as a banner. Unknown values render as "unknown", never as zero.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/repeater_detail_api.dart';
import '../map/coverage_map.dart';
import '../theme.dart';

/// Pushes the detail screen for one repeater of the region served at [baseUrl].
Future<void> openRepeaterDetail(
  BuildContext context, {
  required String baseUrl,
  required String regionSlug,
  required String repeaterKey,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => RepeaterDetailScreen(
        baseUrl: baseUrl,
        regionSlug: regionSlug,
        repeaterKey: repeaterKey,
      ),
    ),
  );
}

class RepeaterDetailScreen extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  final String repeaterKey;

  /// Test seams.
  @visibleForTesting
  final http.Client? client;
  @visibleForTesting
  final bool mapTiles;
  @visibleForTesting
  final DateTime? now;

  const RepeaterDetailScreen({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
    required this.repeaterKey,
    this.client,
    this.mapTiles = true,
    this.now,
  });

  @override
  State<RepeaterDetailScreen> createState() => _RepeaterDetailScreenState();
}

class _RepeaterDetailScreenState extends State<RepeaterDetailScreen> {
  RepeaterDetailData? _data;
  RepeaterDetailException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await fetchRepeaterDetail(
        widget.baseUrl,
        widget.repeaterKey,
        client: widget.client,
      );
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } on RepeaterDetailException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final title = d?.row?.displayName ?? 'Repeater';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final d = _data;
    if (_loading && d == null) {
      return const Center(
        child: CircularProgressIndicator(key: Key('repdetail-loading')),
      );
    }
    if (_error != null && d == null) return _errorView(context, _error!);
    if (d == null || d.row == null) {
      return _message(
        context,
        Icons.help_outline,
        'No details',
        d?.status.reason ?? 'The server has no details for this repeater yet.',
        key: 'repdetail-empty',
      );
    }
    final row = d.row!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('repdetail-list'),
        padding: const EdgeInsets.all(Gap.l),
        children: [
          if (_error != null)
            _banner(
              context,
              'Could not refresh: ${_error!.message} Showing the last data.',
              warn: true,
            ),
          if (!d.status.isReady) _statusBanner(context, d.status),
          _identity(context, row),
          const SizedBox(height: Gap.l),
          _stats(context, row, d),
          const SizedBox(height: Gap.l),
          _position(context, row),
          _activity(context, d),
          _neighbours(context, d),
          _observers(context, d),
          _packetTypes(context, d),
          _events(context, d),
          const SizedBox(height: Gap.xl),
          Text(
            'Region ${widget.regionSlug}. Data: ${d.status.source ?? 'unknown source'}'
            '${d.status.computedAt != null ? ', computed ${_ago(d.status.computedAt, _now)}' : ''}.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: MeshSonarColors.of(context).textMuted),
          ),
        ],
      ),
    );
  }

  Widget _errorView(BuildContext context, RepeaterDetailException e) {
    final (icon, head) = switch (e.kind) {
      RepeaterDetailFailure.notFound => (
        Icons.search_off,
        'Not in this region',
      ),
      RepeaterDetailFailure.badKey => (
        Icons.error_outline,
        'Invalid repeater key',
      ),
      RepeaterDetailFailure.network => (
        Icons.cloud_off,
        'Can\'t reach the server',
      ),
      _ => (Icons.error_outline, 'Server problem'),
    };
    final retry =
        e.kind == RepeaterDetailFailure.network ||
        e.kind == RepeaterDetailFailure.server ||
        e.kind == RepeaterDetailFailure.unreadable;
    return _message(
      context,
      icon,
      head,
      e.message,
      key: 'repdetail-error',
      retry: retry,
    );
  }

  Widget _message(
    BuildContext context,
    IconData icon,
    String head,
    String text, {
    required String key,
    bool retry = false,
  }) {
    return Center(
      key: Key(key),
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: MeshSonarColors.of(context).textMuted),
            const SizedBox(height: Gap.m),
            Text(head, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.s),
            Text(text, textAlign: TextAlign.center),
            if (retry) ...[
              const SizedBox(height: Gap.l),
              FilledButton.icon(
                key: const Key('repdetail-retry'),
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _banner(BuildContext context, String text, {bool warn = false}) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.m),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: warn
            ? t.colorScheme.errorContainer
            : t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Corners.small),
      ),
      child: Text(text, style: t.textTheme.bodyMedium),
    );
  }

  Widget _statusBanner(BuildContext context, SourcedStatus s) {
    final label = switch (s.state) {
      'partial' => 'Partial data',
      'pending' => 'Data pending',
      'stale' => 'Data may be out of date',
      'unavailable' => 'Data unavailable',
      _ => 'Data status: ${s.state}',
    };
    return _banner(context, s.reason == null ? label : '$label. ${s.reason}');
  }

  // ------------------------------------------------------------ sections
  Widget _section(
    BuildContext context,
    String title,
    Widget child, {
    String? key,
  }) {
    return Padding(
      key: key == null ? null : Key(key),
      padding: const EdgeInsets.only(bottom: Gap.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.s),
          child,
        ],
      ),
    );
  }

  Widget _muted(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: MeshSonarColors.of(context).textMuted),
  );

  Widget _identity(BuildContext context, RepeaterRowInfo r) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      key: const Key('repdetail-identity'),
      children: [
        Text(r.displayName, style: t.textTheme.headlineSmall),
        const SizedBox(height: Gap.s),
        Wrap(
          spacing: Gap.s,
          runSpacing: Gap.xs,
          children: [
            Chip(label: Text(_roleLabel(r.role))),
            Chip(label: Text(_statusLabel(r.status))),
            if (r.ambiguous)
              const Chip(label: Text('Hash shared with another node')),
          ],
        ),
        const SizedBox(height: Gap.s),
        Row(
          children: [
            Text(
              'Hash ',
              style: t.textTheme.bodyMedium?.copyWith(color: m.textMuted),
            ),
            Text(
              r.hashPrefix,
              key: const Key('repdetail-hash'),
              style: t.textTheme.titleMedium,
            ),
            if (r.hashSizeBytes != null)
              Text(
                '  (${r.hashSizeBytes}-byte)',
                style: t.textTheme.bodyMedium?.copyWith(color: m.textMuted),
              ),
          ],
        ),
        const SizedBox(height: Gap.xs),
        InkWell(
          key: const Key('repdetail-copy-key'),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: r.key));
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Public key copied')));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    r.key,
                    style: t.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: m.textMuted,
                    ),
                  ),
                ),
                const Icon(Icons.copy, size: 16),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.s),
        Text(
          'Last heard: ${_ago(r.lastHeardAt, _now)}',
          key: const Key('repdetail-lastheard'),
          style: t.textTheme.bodyLarge,
        ),
        Text(
          'First seen: ${r.firstSeenAt == null ? 'unknown' : _date(r.firstSeenAt!)}',
          style: t.textTheme.bodyMedium?.copyWith(color: m.textMuted),
        ),
      ],
    );
  }

  Widget _stats(BuildContext context, RepeaterRowInfo r, RepeaterDetailData d) {
    String n(int? v) => v?.toString() ?? 'unknown';
    final items = <(String, String)>[
      ('Relayed (24 h)', n(r.relays24h)),
      ('Adverts (24 h)', n(r.adverts24h)),
      ('Neighbours', n(r.neighbours)),
      (
        'Heard by (24 h)',
        r.observers24h == null ? 'unknown' : '${r.observers24h} observers',
      ),
      (
        'Heard hours',
        r.heardHoursPct == null ? 'unknown' : '${r.heardHoursPct!.round()}%',
      ),
      (
        'Mean SNR',
        r.snrMeanDb == null
            ? 'unknown'
            : '${r.snrMeanDb!.toStringAsFixed(1)} dB',
      ),
      ('Signal grade', r.signalGrade ?? 'unknown'),
      (
        'Measured reach',
        d.reachMaxKm == null
            ? 'unknown'
            : '${d.reachMaxKm!.toStringAsFixed(1)} km',
      ),
    ];
    return Wrap(
      key: const Key('repdetail-stats'),
      spacing: Gap.m,
      runSpacing: Gap.m,
      children: [for (final (k, v) in items) _StatTile(label: k, value: v)],
    );
  }

  Widget _position(BuildContext context, RepeaterRowInfo r) {
    if (!r.hasPosition) {
      return _section(
        context,
        'Position',
        _muted(context, 'This repeater has not reported a position.'),
        key: 'repdetail-position',
      );
    }
    final p = LatLng(r.lat!, r.lon!);
    final m = MeshSonarColors.of(context);
    return _section(
      context,
      'Position',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${r.lat!.toStringAsFixed(5)}, ${r.lon!.toStringAsFixed(5)}',
            key: const Key('repdetail-coords'),
          ),
          const SizedBox(height: Gap.s),
          ClipRRect(
            borderRadius: BorderRadius.circular(Corners.small),
            child: SizedBox(
              height: 180,
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: p,
                  initialZoom: 13,
                  backgroundColor: m.mapBackground,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none,
                  ),
                ),
                children: [
                  if (widget.mapTiles)
                    TileLayer(
                      urlTemplate: CoverageMap.tileUrl,
                      userAgentPackageName: CoverageMap.userAgentPackageName,
                      maxNativeZoom: 19,
                      tileBuilder: (context, tile, _) => ColorFiltered(
                        colorFilter: ColorFilter.matrix(m.tileMatrix),
                        child: tile,
                      ),
                    ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: p,
                        width: 28,
                        height: 28,
                        child: Icon(
                          Icons.cell_tower,
                          color: m.beacon,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      key: 'repdetail-position',
    );
  }

  Widget _activity(BuildContext context, RepeaterDetailData d) {
    final hm = d.heatmap;
    final flat = hm == null ? <int>[] : [for (final r in hm) ...r];
    final snr = d.snrHourly;
    final snrKnown = snr.where((p) => p.mean != null).length;
    return _section(
      context,
      'Activity',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hm == null || flat.isEmpty)
            _muted(context, 'No packet history for this repeater yet.')
          else ...[
            Text(
              'Packets heard per hour, last ${hm.length} days (${flat.fold<int>(0, (a, b) => a + b)} total)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            SizedBox(
              height: 56,
              width: double.infinity,
              child: CustomPaint(
                key: const Key('repdetail-sparkline'),
                painter: SparklinePainter([
                  for (final v in flat) v.toDouble(),
                ], Theme.of(context).colorScheme.primary),
              ),
            ),
            const SizedBox(height: Gap.m),
            Text(
              'Heatmap by day and hour (UTC)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            _heatmap(context, d, hm),
          ],
          const SizedBox(height: Gap.m),
          if (snrKnown == 0)
            _muted(context, 'No SNR measurements in the last week.')
          else ...[
            Text(
              'SNR by hour (dB, mean)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            SizedBox(
              height: 56,
              width: double.infinity,
              child: CustomPaint(
                key: const Key('repdetail-snr-sparkline'),
                painter: SparklinePainter([
                  for (final p in snr) p.mean ?? double.nan,
                ], MeshSonarColors.of(context).snrStrong),
              ),
            ),
          ],
        ],
      ),
      key: 'repdetail-activity',
    );
  }

  Widget _heatmap(
    BuildContext context,
    RepeaterDetailData d,
    List<List<int>> hm,
  ) {
    final maxV = hm.expand((r) => r).fold<int>(0, math.max);
    final color = Theme.of(context).colorScheme.primary;
    final muted = MeshSonarColors.of(context).textMuted;
    const dow = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Column(
      key: const Key('repdetail-heatmap'),
      children: [
        for (var i = 0; i < hm.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(() {
                    final day = d.heatmapDay(i);
                    return day == null
                        ? 'Day ${i + 1}'
                        : '${dow[day.weekday - 1]} ${day.month}/${day.day}';
                  }(), style: TextStyle(fontSize: 11, color: muted)),
                ),
                for (var h = 0; h < 24; h++)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${h.toString().padLeft(2, '0')}:00 UTC, ${h < hm[i].length ? hm[i][h] : 0} packets',
                      child: Container(
                        height: 16,
                        margin: const EdgeInsets.symmetric(horizontal: 0.5),
                        color: (h < hm[i].length && hm[i][h] > 0 && maxV > 0)
                            ? color.withValues(
                                alpha: 0.12 + 0.88 * (hm[i][h] / maxV),
                              )
                            : muted.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _neighbours(BuildContext context, RepeaterDetailData d) {
    final nbs = [...d.neighbours]
      ..sort(
        (a, b) => (b.snrDb ?? -999).compareTo(a.snrDb ?? -999) != 0
            ? (b.snrDb ?? -999).compareTo(a.snrDb ?? -999)
            : (b.packets ?? 0).compareTo(a.packets ?? 0),
      );
    return _section(
      context,
      'Neighbours (${nbs.length})',
      nbs.isEmpty
          ? _muted(context, 'No neighbours known.')
          : Column(
              children: [
                for (final n in nbs)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      n.name?.trim().isNotEmpty == true
                          ? n.name!.trim()
                          : '${n.key.substring(0, math.min(8, n.key.length))}...',
                    ),
                    subtitle: Text(
                      [
                        _kindLabel(n.kind),
                        if (n.distanceKm != null)
                          '${n.distanceKm!.toStringAsFixed(1)} km',
                        if (n.packets != null) '${n.packets} packets',
                        if (n.lastAt != null) _ago(n.lastAt, _now),
                      ].join(' / '),
                    ),
                    trailing: Text(
                      n.snrDb == null
                          ? 'SNR unknown'
                          : '${n.snrDb!.toStringAsFixed(1)} dB',
                    ),
                  ),
              ],
            ),
      key: 'repdetail-neighbours',
    );
  }

  Widget _observers(BuildContext context, RepeaterDetailData d) {
    return _section(
      context,
      'Heard by observers (${d.observers.length})',
      d.observers.isEmpty
          ? _muted(context, 'No observers have heard it recently.')
          : Column(
              children: [
                for (final o in d.observers)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      o.name?.trim().isNotEmpty == true
                          ? o.name!.trim()
                          : '${o.key.substring(0, math.min(8, o.key.length))}...',
                    ),
                    subtitle: Text(
                      '${o.packets} packets / last ${_ago(o.lastAt, _now)}',
                    ),
                    trailing: Text(
                      o.bestSnrDb == null
                          ? 'SNR unknown'
                          : 'best ${o.bestSnrDb!.toStringAsFixed(1)} dB',
                    ),
                  ),
              ],
            ),
      key: 'repdetail-observers',
    );
  }

  Widget _packetTypes(BuildContext context, RepeaterDetailData d) {
    if (d.packetTypes.isEmpty) return const SizedBox.shrink();
    final types = [...d.packetTypes]..sort((a, b) => b.n.compareTo(a.n));
    return _section(
      context,
      'Packet types',
      Wrap(
        spacing: Gap.s,
        runSpacing: Gap.xs,
        children: [
          for (final t in types)
            Chip(label: Text('${packetTypeName(t.type)} ${t.n}')),
        ],
      ),
      key: 'repdetail-types',
    );
  }

  Widget _events(BuildContext context, RepeaterDetailData d) {
    if (d.events.isEmpty) return const SizedBox.shrink();
    return _section(
      context,
      'Recent events',
      Column(
        children: [
          for (final e in d.events)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.detail),
              subtitle: Text(_ago(e.at, _now)),
            ),
        ],
      ),
      key: 'repdetail-events',
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label, value;
  const _StatTile({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: 150,
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Corners.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: t.textTheme.bodySmall?.copyWith(
              color: MeshSonarColors.of(context).textMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: t.textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// Line sparkline; NaN values leave a gap (unknown is not zero).
class SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  SparklinePainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final known = values.where((v) => !v.isNaN).toList();
    if (known.length < 2 && values.length < 2) return;
    final lo = known.isEmpty ? 0.0 : known.reduce(math.min);
    final hi = known.isEmpty ? 1.0 : known.reduce(math.max);
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    var pen = false;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v.isNaN) {
        pen = false;
        continue;
      }
      final x = values.length == 1 ? 0.0 : size.width * i / (values.length - 1);
      final y = size.height - 3 - (size.height - 6) * ((v - lo) / span);
      if (pen) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        pen = true;
        if (i == values.length - 1 || values[i + 1].isNaN) {
          canvas.drawCircle(Offset(x, y), 1.5, Paint()..color = color);
        }
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.values != values || old.color != color;
}

String _roleLabel(String r) => switch (r) {
  'repeater' => 'Repeater',
  'room' => 'Room server',
  'companion' => 'Companion',
  'sensor' => 'Sensor',
  _ => 'Unknown role',
};

String _statusLabel(String s) => switch (s) {
  'active' => 'Active',
  'quiet' => 'Quiet',
  'new' => 'New',
  _ => 'Stale',
};

String _kindLabel(String k) => switch (k) {
  'reported' => 'reported',
  'inferred' => 'inferred',
  _ => 'observed',
};

String _date(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

String _ago(DateTime? t, DateTime now) {
  if (t == null) return 'unknown';
  final d = now.difference(t);
  if (d.isNegative || d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}
