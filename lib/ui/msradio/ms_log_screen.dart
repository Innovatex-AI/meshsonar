// Build 78 (builder A), brief C.4: Log and backlog (GET /log, refreshed every 5 s while open and in front): waiting to
// upload, sent from backlog, oldest waiting, dropped, logged, log size, a 24-hour bar chart from `hourly`, the files and
// their sizes.
//   - "Save log to phone": downloads `log/file` old + current into the app's documents and opens the share sheet.
//   - "Show on map" ([MsLogMapScreen]): GPS points and probe results from paged `log/records` on the small map.
// These records stay on the phone and the radio: the app never uploads them (the radio sends what it shared itself) and
// never treats them as the app's own pings.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/msradio/msradio.dart';
import '../../core/time_format.dart' as tf;
import '../../platform/share.dart' show shareRadioLogFiles;
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../design/app_surfaces.dart' show showAppToast, AppToastKind;
import '../design/tokens.dart';
import '../radio/inset_list.dart';
import '../theme.dart' show MeshSonarColors;
import '../tools/tool_kit.dart' show ToolMap, MapPin, MapLine;
import 'ms_common.dart';

class MsLogScreen extends StatelessWidget {
  final MsRadioController c;
  const MsLogScreen(this.c, {super.key});

  /// Tests: where "Save log to phone" writes (default: the app's documents) and what it does with the files (default: the
  /// share sheet).
  static Future<Directory> Function()? debugDocs;
  static Future<void> Function(List<File> files)? debugShare;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('ms-log-screen'),
        appBar: AppBar(title: const Text('Log and backlog')),
        body: MsLive<MsLog>(
          c: c,
          every: const Duration(seconds: 5),
          load: (api) => api.log(),
          builder: (context, live) => _LogBody(c: c, live: live),
        ),
      );
}

String _two(int n) => n.toString().padLeft(2, '0');

class _LogBody extends StatefulWidget {
  final MsRadioController c;
  final MsLiveData<MsLog> live;
  const _LogBody({required this.c, required this.live});

  @override
  State<_LogBody> createState() => _LogBodyState();
}

class _LogBodyState extends State<_LogBody> {
  String? _saving;

  List<MsLogWhich> get _which {
    final files = widget.live.data.files;
    if (files.isEmpty) return const [MsLogWhich.current];
    return [for (final w in const [MsLogWhich.old, MsLogWhich.current]) if (files.any((f) => f.which == w)) w];
  }

  Future<void> _save() async {
    final api = widget.c.api;
    if (api == null) return;
    final out = <File>[];
    try {
      final base = await (MsLogScreen.debugDocs ?? getApplicationDocumentsDirectory)();
      final dir = Directory('${base.path}${Platform.pathSeparator}MeshSonar radio logs');
      await dir.create(recursive: true);
      final now = DateTime.now();
      final stamp = '${now.year}${_two(now.month)}${_two(now.day)}-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final pk = widget.c.radioKey.substring(0, 8);
      for (final w in _which) {
        final label = w == MsLogWhich.old ? 'older' : 'current';
        if (mounted) setState(() => _saving = 'Saving the $label log…');
        final bytes = await api.logFile(w, onProgress: (got, total) {
          if (!mounted || total == null || total <= 0) return;
          setState(() => _saving = 'Saving the $label log… ${(got * 100 / total).clamp(0, 100).round()} %');
        });
        final f = File('${dir.path}${Platform.pathSeparator}meshsonar-$pk-$stamp-${w == MsLogWhich.old ? 'old' : 'current'}.mslog');
        await f.writeAsBytes(bytes, flush: true);
        out.add(f);
      }
      if (!mounted) return;
      setState(() => _saving = null);
      await (MsLogScreen.debugShare ?? shareRadioLogFiles)(out);
    } on MsRadioError catch (e) {
      if (mounted) msShowError(context, e);
    } on FileSystemException {
      if (mounted) showAppToast(context, 'The log could not be saved on this phone.', kind: AppToastKind.error);
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.live.data;
    final l = d.log;
    final m = MeshSonarColors.of(context);
    final hourly = d.hourly;
    final n = hourly.length;
    String hourLabel(int i) => i == n - 1 ? 'now' : '-${n - 1 - i}h';
    final total = hourly.fold<int>(0, (a, b) => a + b);
    return MsBody(listKey: const Key('ms-log-list'), children: [
      if (widget.live.refreshError != null) MsBanner('Not updated: ${widget.live.refreshError}'),
      InsetGroup(header: 'Backlog', rows: [
        InsetRow(title: 'Waiting to upload', value: msCount(l?.pending), chevron: false),
        InsetRow(title: 'Sent from backlog', value: msCount(l?.backlogSent), chevron: false),
        InsetRow(title: 'Oldest waiting', value: l?.backlogMaxS == null || (l?.pending ?? 0) == 0 ? '—' : msDuration(l!.backlogMaxS), chevron: false),
        InsetRow(title: 'Dropped', value: msCount(l?.dropped), chevron: false),
      ]),
      InsetGroup(header: 'Log', rows: [
        InsetRow(title: 'Logged', value: msCount(l?.logged), chevron: false),
        InsetRow(title: 'GPS points', value: msCount(l?.gpsPoints), chevron: false),
        InsetRow(title: 'Log size', value: msBytes(l?.logBytes), chevron: false),
        if (d.spiffsUsed != null && d.spiffsTotal != null)
          InsetRow(title: 'Radio storage', value: '${msBytes(d.spiffsUsed)} of ${msBytes(d.spiffsTotal)} used', chevron: false),
      ]),
      if (n > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Layout.sectionGap - 8),
          child: ChartFrame(
            id: 'ms-log-hourly',
            title: 'Packets heard per hour, last $n hours',
            summary: '${msCount(total)} packets in the last $n hours; the busiest hour had ${msCount(hourly.reduce((a, b) => a > b ? a : b))}.',
            table: ChartTable(head: const ['Hour', 'Packets'], rows: [
              for (var i = 0; i < n; i++) [hourLabel(i), msCount(hourly[i])],
            ]),
            chart: BarChart(
              labels: [for (var i = 0; i < n; i++) hourLabel(i)],
              series: [BarSeries(name: 'Packets', values: [for (final h in hourly) h.toDouble()], color: m.snrStrong)],
              labelEvery: 6,
              yLabel: 'Packets',
            ),
          ),
        ),
      InsetGroup(header: 'Files', rows: [
        for (final f in d.files)
          InsetRow(
            key: Key('ms-log-file-${f.which.name}'),
            title: f.which == MsLogWhich.old ? 'Older log' : 'Current log',
            subtitle: f.path.isEmpty ? null : f.path,
            value: msBytes(f.size),
            chevron: false,
          ),
      ]),
      if (_saving != null) MsNote(_saving!),
      MsButton('Save log to phone',
          key: const Key('ms-log-save'), icon: Icons.download_rounded, primary: true, busy: _saving != null, onPressed: _save),
      MsButton('Show on map',
          key: const Key('ms-log-map'),
          icon: Icons.map_outlined,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MsLogMapScreen(widget.c, which: _which)))),
      const MsNote('The log stays on the radio and on this phone. This app never uploads it: what the radio shared, it sent '
          'to MeshSonar itself.'),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ map of the log
/// GPS points (a line) and probe results (pins) from the radio's log, read page by page from `log/records`.
class MsLogMapScreen extends StatefulWidget {
  final MsRadioController c;
  final List<MsLogWhich> which;

  /// Pages read per file before "Load more" (100 records a page).
  final int pagesPerStep;
  const MsLogMapScreen(this.c, {super.key, this.which = const [MsLogWhich.old, MsLogWhich.current], this.pagesPerStep = 40});

  @override
  State<MsLogMapScreen> createState() => _MsLogMapScreenState();
}

class _MsLogMapScreenState extends State<MsLogMapScreen> {
  final List<MsLogRecord> _gps = [];
  final List<MsLogRecord> _probes = [];

  /// Where each (file, kind) pass stopped; null = done.
  final Map<(MsLogWhich, MsRecordKind), int?> _next = {};
  bool _loading = false;
  MsRadioError? _error;

  @override
  void initState() {
    super.initState();
    for (final w in widget.which) {
      _next[(w, MsRecordKind.gps)] = 0;
      _next[(w, MsRecordKind.probe)] = 0;
    }
    unawaited(_more());
  }

  bool get _hasMore => _next.values.any((v) => v != null);

  Future<void> _more() async {
    final api = widget.c.api;
    if (api == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      for (final k in _next.keys.toList()) {
        var pages = 0;
        while (_next[k] != null && pages < widget.pagesPerStep) {
          final p = await api.logRecords(which: k.$1, kind: k.$2, off: _next[k]!, limit: 100);
          pages++;
          for (final r in p.records) {
            if (r.kind == MsRecordKind.gps && r.hasPosition) _gps.add(r);
            if (r.kind == MsRecordKind.probe && k.$2 == MsRecordKind.probe) _probes.add(r);
          }
          _next[k] = p.hasMore ? p.next : null;
          if (!mounted) return;
          setState(() {});
        }
      }
    } on MsRadioError catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final gps = [for (final r in _gps) LatLng(r.lat!, r.lon!)];
    final placed = [for (final r in _probes) if (r.hasPosition) r];
    final probes = _probes.reversed.toList(); // newest first
    return Scaffold(
      key: const Key('ms-log-map-screen'),
      appBar: AppBar(title: const Text('Log on the map')),
      body: MsBody(listKey: const Key('ms-log-map-list'), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
          child: ToolMap(
            key: const Key('ms-log-map'),
            height: 280,
            semanticLabel: gps.isEmpty && placed.isEmpty
                ? (_loading ? 'Reading the radio\'s log…' : 'No GPS points or probe results with a position in the log.')
                : 'Map of ${gps.length} GPS points and ${placed.length} probe results from the radio\'s log.',
            lines: [if (gps.length > 1) MapLine(gps, t.colorScheme.primary, width: 3)],
            pins: [
              for (final r in placed)
                MapPin(
                  point: LatLng(r.lat!, r.lon!),
                  label: 'Probe, ${r.probe?.answered ?? 0} answered',
                  icon: Icons.radar,
                  color: (r.probe?.answered ?? 0) > 0 ? m.snrStrong : m.noReply,
                ),
            ],
          ),
        ),
        if (_error != null) MsBanner(msErrorText(_error!)),
        MsNote('${msCount(gps.length)} GPS points and ${msCount(_probes.length)} probe results'
            '${_loading ? ', still reading the log…' : (_hasMore ? ' so far.' : '.')}'),
        if (_hasMore && !_loading)
          MsButton('Load more', key: const Key('ms-log-map-more'), icon: Icons.expand_more_rounded, onPressed: _more),
        InsetGroup(header: 'Probe results', rows: [
          for (final (i, r) in probes.take(50).indexed) _ProbeRow(key: Key('ms-probe-$i'), r: r),
        ]),
        const MsNote('These records come from the radio\'s own log and stay on this phone. They are not uploaded.'),
      ]),
    );
  }
}

class _ProbeRow extends StatelessWidget {
  final MsLogRecord r;
  const _ProbeRow({super.key, required this.r});

  @override
  Widget build(BuildContext context) {
    final p = r.probe;
    final parts = <String>[
      '${p?.answered ?? 0} answered',
      if (r.bestSnr != null) 'best SNR ${r.bestSnr!.toStringAsFixed(1)} dB',
      if (r.bestRssi != null) 'RSSI ${r.bestRssi} dBm',
    ];
    final nodes = p == null || p.nodes.isEmpty ? null : 'Nodes: ${p.nodes.map((n) => n.key.toUpperCase()).join(', ')}';
    final ping = p?.ping == null
        ? null
        : p!.ping == 'answered'
            ? 'Repeater ${p.pingRepeater?.toUpperCase() ?? ''} answered${p.pingMs == null ? '' : ' in ${p.pingMs} ms'}'
            : 'Repeater ping: ${p.ping}';
    return InsetRow(
      title: r.time == null ? 'Probe' : tf.shortDateTime(r.time),
      subtitle: [parts.join(' · '), ?nodes, ?ping].join('\n'),
      chevron: false,
    );
  }
}
