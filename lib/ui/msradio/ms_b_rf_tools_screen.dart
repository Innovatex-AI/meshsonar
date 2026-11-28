// MeshSonar radio > RF tools (brief C.10).
// Spectrum: the radio listens across a band (presets US 902-928, around the mesh frequency +-2 MHz, EU 863-870) in steps for a
// while, never transmitting; mesh receive pauses in short bursts meanwhile. A bar per step of the newest sweep (`last`), a
// tick for the highest seen (`peak`), the mesh frequency marked; a step not measured yet is drawn empty. Polled every 2 s
// while it runs and the screen is open. Firmware without scan data says so.
// Signal probe: "Probe now", then the newest results from `/probes`, read again about 10 s and 20 s later.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../charts/chart_scale.dart';
import '../design/tokens.dart';
import 'ms_b_common.dart';

/// A band preset.
class MsBBand {
  final String id, label;
  final double f0, f1;
  const MsBBand(this.id, this.label, this.f0, this.f1);
}

/// The radio's scan limits (APP-INTEGRATION.md "Spectrum").
abstract final class MsBScanLimits {
  static const double minMhz = 150, maxMhz = 960;
  static const int maxSteps = 1024;
  static const int minSeconds = 5, maxSeconds = 600;
  static const List<double> steps = [0.025, 0.05, 0.1, 0.2, 0.5, 1.0];
  static const List<int> durations = [5, 10, 15, 30, 60, 120, 300, 600];

  /// Steps the band [f0]..[f1] takes at [step] MHz.
  static int stepsFor(double f0, double f1, double step) => ((f1 - f0) / step).floor() + 1;
}

/// The presets; "around the mesh" only when the radio's frequency is known.
List<MsBBand> msBBands(double? meshMhz) => [
      const MsBBand('us', 'US 902-928', 902, 928),
      if (meshMhz != null)
        MsBBand('mesh', 'Around the mesh frequency', math.max(MsBScanLimits.minMhz, meshMhz - 2), math.min(MsBScanLimits.maxMhz, meshMhz + 2)),
      const MsBBand('eu', 'EU 863-870', 863, 870),
    ];

String _mhz(double f) => tickLabel(double.parse(f.toStringAsFixed(3)));

class MsBRfToolsScreen extends StatefulWidget {
  final MsRadioController c;

  /// When a probe's results are read again after "Probe now" (tests shorten nothing: fake time).
  final List<Duration> probeReads;
  const MsBRfToolsScreen({super.key, required this.c, this.probeReads = const [Duration(seconds: 10), Duration(seconds: 20)]});
  @override
  State<MsBRfToolsScreen> createState() => _MsBRfToolsScreenState();
}

class _MsBRfToolsScreenState extends State<MsBRfToolsScreen> {
  MsSpectrum? _spec;
  MsProbes? _probes;
  double? _meshMhz;
  String? _specError, _probeError, _probeNote;
  bool _loading = true, _specActing = false, _probing = false;
  String _band = 'us';
  double _step = 0.2;
  int _seconds = 15;
  final List<Timer> _probeTimers = [];
  late final MsBPoller _poll = MsBPoller(tick: _loadSpectrum, want: () => mounted && (_spec?.scanning ?? false));

  MsRadioApi? get _api => widget.c.api;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _poll.dispose();
    for (final t in _probeTimers) {
      t.cancel();
    }
    super.dispose();
  }

  Future<void> _loadAll() async {
    final api = _api;
    if (api == null) return;
    final err = await msBTry(() async {
      final st = await api.status();
      _meshMhz = st.radio?.freqMhz;
    });
    if (err != null && mounted) setState(() => _specError = err);
    await _loadSpectrum();
    await _loadProbes();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadSpectrum() async {
    final api = _api;
    if (api == null) return;
    MsSpectrum? s;
    final err = await msBTry(() async => s = await api.spectrum());
    if (!mounted) return;
    setState(() {
      if (s != null) _spec = s;
      if (err != null) _specError = err;
    });
    _poll.kick();
  }

  Future<void> _loadProbes() async {
    final api = _api;
    if (api == null) return;
    MsProbes? p;
    final err = await msBTry(() async => p = await api.probes(limit: 5));
    if (!mounted) return;
    setState(() {
      if (p != null) _probes = p;
      if (err != null) _probeError = err;
    });
  }

  MsBBand get _bandNow => msBBands(_meshMhz).firstWhere((b) => b.id == _band, orElse: () => msBBands(_meshMhz).first);

  /// Steps that keep the band within the radio's 1024-step limit.
  List<double> _stepsFor(MsBBand b) => [for (final s in MsBScanLimits.steps) if (MsBScanLimits.stepsFor(b.f0, b.f1, s) <= MsBScanLimits.maxSteps) s];

  void _chooseBand(String id) {
    setState(() {
      _band = id;
      final ok = _stepsFor(_bandNow);
      if (!ok.contains(_step) && ok.isNotEmpty) _step = ok.contains(0.2) ? 0.2 : ok.first;
    });
  }

  Future<void> _start() async {
    final api = _api;
    if (api == null) return;
    final b = _bandNow;
    setState(() {
      _specActing = true;
      _specError = null;
    });
    final err = await msBTry(() => api.spectrumStart(f0: b.f0, f1: b.f1, step: _step, seconds: _seconds.clamp(MsBScanLimits.minSeconds, MsBScanLimits.maxSeconds)));
    if (!mounted) return;
    setState(() {
      _specActing = false;
      _specError = err;
    });
    await _loadSpectrum();
  }

  Future<void> _stop() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _specActing = true;
      _specError = null;
    });
    final err = await msBTry(() => api.spectrumStop());
    if (!mounted) return;
    setState(() {
      _specActing = false;
      _specError = err;
    });
    await _loadSpectrum();
  }

  Future<void> _probeNow() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _probing = true;
      _probeError = null;
      _probeNote = null;
    });
    MsProbeStart? r;
    final err = await msBTry(() async => r = await api.probeNow());
    if (!mounted) return;
    setState(() {
      _probeError = err;
      if (err != null) _probing = false;
      if (err == null) _probeNote = 'Probe sent. The radio listens for answers for ${r?.listenS ?? 8} s; results show here.';
    });
    if (err != null) return;
    for (final t in _probeTimers) {
      t.cancel();
    }
    _probeTimers.clear();
    final reads = widget.probeReads;
    for (var i = 0; i < reads.length; i++) {
      final last = i == reads.length - 1;
      _probeTimers.add(Timer(reads[i], () async {
        if (!mounted) return;
        await _loadProbes();
        if (last && mounted) setState(() => _probing = false);
      }));
    }
  }

  // ---------------------------------------------------------------- spectrum

  List<Widget> _spectrum(BuildContext context) {
    final t = Theme.of(context);
    final s = _spec;
    final scanning = s?.scanning ?? false;
    final b = _bandNow;
    final steps = _stepsFor(b);
    final busy = _specActing;
    final scan = s?.scan;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin + 16, 0, Layout.screenMargin, 8),
        child: Semantics(header: true, child: Text('Spectrum', style: t.textTheme.titleMedium)),
      ),
      MsBError(_specError, noteKey: const Key('msb-rf-spec-error')),
      if (s != null && !s.binsAvailable)
        const MsBBlock(child: NoteCard('This firmware does not report scan data yet.', key: Key('msb-rf-no-bins'))),
      MsBBlock(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Band', style: t.textTheme.bodyLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final band in msBBands(_meshMhz))
              ChoiceChip(
                key: Key('msb-rf-band-${band.id}'),
                // a chip never clips: its label wraps within the screen width (the range is in the line under the pickers)
                label: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: math.max(80, MediaQuery.sizeOf(context).width - 2 * Layout.screenMargin - 64)),
                  child: Text(band.label, softWrap: true),
                ),
                selected: _band == band.id,
                onSelected: scanning || busy ? null : (_) => _chooseBand(band.id),
              ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
              child: DropdownButtonFormField<double>(
                key: Key('msb-rf-step-${b.id}'),
                initialValue: steps.contains(_step) ? _step : (steps.isEmpty ? null : steps.first),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Step', border: OutlineInputBorder()),
                items: [for (final st in steps) DropdownMenuItem(value: st, child: Text('${_mhz(st)} MHz'))],
                onChanged: scanning || busy ? null : (v) => setState(() => _step = v ?? _step),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
              child: DropdownButtonFormField<int>(
                key: const Key('msb-rf-duration'),
                initialValue: _seconds,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'For', border: OutlineInputBorder()),
                items: [for (final d in MsBScanLimits.durations) DropdownMenuItem(value: d, child: Text(d < 60 ? '$d s' : '${d ~/ 60} min'))],
                onChanged: scanning || busy ? null : (v) => setState(() => _seconds = v ?? _seconds),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${MsBScanLimits.stepsFor(b.f0, b.f1, _step)} steps from ${_mhz(b.f0)} to ${_mhz(b.f1)} MHz.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
      MsBButtons([
        if (!scanning)
          FilledButton.icon(
            key: const Key('msb-rf-start'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: busy ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          )
        else
          FilledButton.tonalIcon(
            key: const Key('msb-rf-stop'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: busy ? null : _stop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
      ]),
      const MsBBlock(
        child: NoteCard(
          'While a scan runs the radio stops listening to the mesh in short bursts (a few thousandths of a second each), so it '
          'can miss a packet now and then. It never transmits for the scan.',
          key: Key('msb-rf-pause-note'),
        ),
      ),
      if (scan != null && scan.last.isNotEmpty)
        MsBBlock(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${scanning ? 'Scanning' : 'Last scan'}: ${_mhz(scan.f0)} to ${_mhz(scan.f1)} MHz, ${scan.sweeps} sweep${scan.sweeps == 1 ? '' : 's'}.',
              key: const Key('msb-rf-scan-line'),
              style: t.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            MsBSpectrumChart(scan: scan, meshMhz: _meshMhz),
            const SizedBox(height: 4),
            Wrap(spacing: 16, runSpacing: 4, children: [
              _legend(context, t.colorScheme.primary, 'Newest sweep'),
              _legend(context, t.colorScheme.onSurface, 'Highest seen', tick: true),
              if (_meshMhz != null) _legend(context, t.colorScheme.error, 'Mesh ${_mhz(_meshMhz!)} MHz', tick: true),
            ]),
          ]),
        ),
    ];
  }

  Widget _legend(BuildContext context, Color c, String text, {bool tick = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: tick ? 12 : 10, height: tick ? 3 : 10, color: c),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: Theme.of(context).textTheme.labelSmall)),
      ]);

  // ---------------------------------------------------------------- probe

  List<Widget> _probe(BuildContext context) {
    final t = Theme.of(context);
    final recs = _probes?.records ?? const <MsLogRecord>[];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin + 16, Gap.l, Layout.screenMargin, 8),
        child: Semantics(header: true, child: Text('Signal probe', style: t.textTheme.titleMedium)),
      ),
      MsBBlock(
        child: Text('The radio sends one short probe and listens for the nodes that answer, and pings a repeater.',
            style: t.textTheme.bodyMedium),
      ),
      MsBError(_probeError, noteKey: const Key('msb-rf-probe-error')),
      if (_probeNote != null) MsBBlock(child: NoteCard(_probeNote!, key: const Key('msb-rf-probe-note'))),
      MsBButtons([
        FilledButton.icon(
          key: const Key('msb-rf-probe'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _probing ? null : _probeNow,
          icon: const Icon(Icons.radar),
          label: const Text('Probe now'),
        ),
      ]),
      if (recs.isEmpty)
        const MsBBlock(child: NoteCard('No probe results yet.', key: Key('msb-rf-probes-empty')))
      else
        for (final (i, r) in recs.take(5).indexed) _probeGroup(context, r, newest: i == 0),
    ];
  }

  Widget _probeGroup(BuildContext context, MsLogRecord r, {required bool newest}) {
    final p = r.probe;
    final nodes = p?.nodes ?? const <MsProbeNode>[];
    String db(double? v) => v == null ? 'unknown' : '${v >= 0 ? '+' : ''}${tickLabel(double.parse(v.toStringAsFixed(2)))} dB';
    final ping = switch (p?.ping) {
      'answered' => 'Repeater ${p?.pingRepeater ?? ''} answered${p?.pingMs == null ? '' : ' in ${p!.pingMs} ms'}',
      'silent' => 'Repeater ${p?.pingRepeater ?? ''} did not answer',
      'none' || null => 'No repeater to ping',
      _ => p!.ping!,
    };
    final when = r.time == null ? null : TimeOfDay.fromDateTime(r.time!.toLocal()).format(context);
    return InsetGroup(
      header: newest ? 'Newest result${when == null ? '' : ', $when'}' : (when ?? 'Earlier'),
      groupKey: Key('msb-rf-probe-${r.seq ?? r.ms}'),
      rows: [
        MsBValueRow(title: 'Answered', value: '${p?.answered ?? 0} node${(p?.answered ?? 0) == 1 ? '' : 's'}'),
        MsBValueRow(title: 'Best SNR', value: db(r.bestSnr)),
        MsBValueRow(title: 'Best RSSI', value: r.bestRssi == null ? 'unknown' : '${r.bestRssi} dBm'),
        InsetRow(title: 'Repeater ping', subtitle: ping.trim(), chevron: false),
        for (final n in nodes)
          InsetRow(
            title: 'Node ${n.key.length > 8 ? n.key.substring(0, 8) : n.key}${n.type == 2 ? ' (repeater)' : ''}',
            subtitle: 'We heard it at ${db(n.snr)}${n.snrThem == null ? '' : ', it heard us at ${db(n.snrThem)}'}${n.rssi == null ? '' : ', ${n.rssi} dBm'}',
            chevron: false,
          ),
      ],
    );
  }

  List<Widget> _rows(BuildContext context) {
    if (_loading && _spec == null && _probes == null) return [const MsBBlock(child: Center(child: CircularProgressIndicator()))];
    return [..._spectrum(context), ..._probe(context)];
  }

  @override
  Widget build(BuildContext context) => MsBPage(c: widget.c, id: 'rf', title: 'RF tools', onRefresh: _loadAll, builder: _rows);
}

/// Bars of [scan]'s newest sweep (dBm, standing on the lowest value), a tick at each step's peak, a line at [meshMhz].
class MsBSpectrumChart extends StatelessWidget {
  final MsSpectrumScan scan;
  final double? meshMhz;
  const MsBSpectrumChart({super.key, required this.scan, this.meshMhz});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final measured = scan.last.whereType<double>().toList();
    final best = measured.isEmpty ? null : measured.reduce(math.max);
    final label = 'Spectrum from ${_mhz(scan.f0)} to ${_mhz(scan.f1)} MHz. '
        '${best == null ? 'Nothing measured yet.' : 'Strongest ${best.toStringAsFixed(1)} dBm.'}';
    final text = (t.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(color: t.colorScheme.onSurfaceVariant);
    // the chart grows with the text size so the axis labels keep their room
    final h = 160.0 + MediaQuery.textScalerOf(context).scale(14) * 2;
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        key: const Key('msb-rf-chart'),
        height: h,
        width: double.infinity,
        child: CustomPaint(
          painter: _SpectrumPainter(
            scan: scan,
            meshMhz: meshMhz,
            bar: t.colorScheme.primary,
            peak: t.colorScheme.onSurface,
            empty: t.colorScheme.outlineVariant,
            mesh: t.colorScheme.error,
            grid: t.colorScheme.outlineVariant,
            text: text,
            scale: MediaQuery.textScalerOf(context),
          ),
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final MsSpectrumScan scan;
  final double? meshMhz;
  final Color bar, peak, empty, mesh, grid;
  final TextStyle text;
  final TextScaler scale;
  _SpectrumPainter(
      {required this.scan, this.meshMhz, required this.bar, required this.peak, required this.empty, required this.mesh, required this.grid, required this.text, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final style = text.copyWith(fontSize: scale.scale(text.fontSize ?? 11));
    final left = 12.0 + scale.scale(30), bottom = 6.0 + scale.scale(14), top = 6.0 + scale.scale(8), right = 6.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    if (w <= 0 || h <= 0) return;
    final n = math.max(scan.last.length, scan.peak.length);
    if (n == 0) return;
    final vals = [...scan.last.whereType<double>(), ...scan.peak.whereType<double>()];
    var lo = vals.isEmpty ? -130.0 : vals.reduce(math.min);
    var hi = vals.isEmpty ? -80.0 : vals.reduce(math.max);
    lo = (lo / 10).floor() * 10.0 - 5;
    hi = (hi / 10).ceil() * 10.0;
    if (hi - lo < 10) hi = lo + 10;
    double y(double v) => top + h * (1 - (v - lo) / (hi - lo));

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in niceTicks(lo, hi, minStep: 1)) {
      if (v < lo || v > hi) continue;
      canvas.drawLine(Offset(left, y(v)), Offset(left + w, y(v)), gp);
      drawChartText(canvas, tickLabel(v), Offset(left - 4, y(v)), style, align: 1);
    }
    drawChartText(canvas, 'dBm', Offset(left - 4, top - scale.scale(6)), style, align: 1);

    final slot = w / n;
    final bw = math.max(1.0, slot * 0.8);
    final bp = Paint()..color = bar;
    final ep = Paint()
      ..color = empty
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final pp = Paint()
      ..color = peak
      ..strokeWidth = math.max(1.5, math.min(3, slot * 0.6));
    for (var i = 0; i < n; i++) {
      final x0 = left + i * slot + (slot - bw) / 2;
      final v = i < scan.last.length ? scan.last[i] : null;
      if (v == null) {
        // not measured yet: an empty outline, never a bar of zero
        if (slot >= 3) canvas.drawRect(Rect.fromLTRB(x0, top + h - h * 0.12, x0 + bw, top + h), ep);
      } else {
        canvas.drawRect(Rect.fromLTRB(x0, y(v.clamp(lo, hi)), x0 + bw, top + h), bp);
      }
      final p = i < scan.peak.length ? scan.peak[i] : null;
      if (p != null) {
        final yy = y(p.clamp(lo, hi));
        canvas.drawLine(Offset(x0, yy), Offset(x0 + bw, yy), pp);
      }
    }
    canvas.drawLine(Offset(left, top + h), Offset(left + w, top + h), gp);

    // x labels: the two ends
    drawChartText(canvas, _mhz(scan.f0), Offset(left, size.height - bottom / 2), style);
    drawChartText(canvas, _mhz(scan.f1), Offset(left + w, size.height - bottom / 2), style, align: 1);

    final m = meshMhz;
    final span = scan.step * (n - 1 <= 0 ? 1 : n - 1);
    if (m != null && span > 0 && m >= scan.f0 && m <= scan.f0 + span) {
      final x = left + ((m - scan.f0) / scan.step) * slot + slot / 2;
      final mp = Paint()
        ..color = mesh
        ..strokeWidth = 1.5;
      for (var yy = top; yy < top + h; yy += 7) {
        canvas.drawLine(Offset(x, yy), Offset(x, math.min(yy + 4, top + h)), mp);
      }
      drawChartText(canvas, 'Mesh', Offset(x, top - scale.scale(6)), style.copyWith(color: mesh), align: 0);
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter o) => o.scan != scan || o.meshMhz != meshMhz || o.bar != bar || o.text != text || o.scale != scale;
}
