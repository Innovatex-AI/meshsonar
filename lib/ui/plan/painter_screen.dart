// Plan > Coverage painter. Modelled coverage from any point: pick the point, the antenna height, power, gain, who is
// listening (a handheld or a repeater) and the radius; the website's coverage model (terrain tiles, diffraction, calibrated
// clutter) runs on the server (`POST /api/cmh/coverage`, the same call the website's painter makes) and the footprint is drawn
// on a map here with the area in each strength band, the people it reaches and the predicted links to live repeaters.
// Only the point and the model settings are sent. The last result is kept on disk and shown, labelled, when offline. Modelled,
// not measured: measured coverage is on the Drive tab. The server runs the model inside the viewed region's own boundary.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' show LatLng;

import '../../core/plan/link_model.dart' show ftM;
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_store.dart';
import '../app.dart';
import 'plan_common.dart';

class PainterScreen extends StatefulWidget {
  /// Test seams.
  final PlanStore? store;
  final http.Client Function()? client;
  final LatLng? initialPoint;
  const PainterScreen({super.key, this.store, this.client, this.initialPoint});

  @override
  State<PainterScreen> createState() => _PainterScreenState();
}

class _PainterScreenState extends State<PainterScreen> {
  LatLng? _p;
  double _ft = 33, _tx = 22, _gain = 3, _radius = 10;
  String _rx = 'handheld';
  bool _loading = false;
  PlanResult<PainterResult>? _res;
  final Latest _latest = Latest();
  late final PlanStore _store;
  bool _init = false;

  @override
  void initState() {
    super.initState();
    _p = widget.initialPoint;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    _store = widget.store ?? AppScope.read(context).planStore;
    if (_p != null) unawaited(_fromStore());
  }

  PainterParams get _params => PainterParams(lat: _p!.latitude, lon: _p!.longitude, antennaFt: _ft, txDbm: _tx, gainDbi: _gain, receiver: _rx, radiusKm: _radius);

  Future<void> _fromStore() async {
    final r = await planStored(_store, _params.cacheKey, PainterResult.parse);
    if (mounted && r != null && _res == null) setState(() => _res = r);
  }

  Future<void> _run() async {
    if (_p == null) return;
    final n = _latest.next();
    setState(() => _loading = true);
    final r = await CoveragePainterApi(AppScope.read(context).planBaseUrl, _store, client: widget.client).paint(_params);
    if (!mounted || !_latest.isCurrent(n)) return;
    setState(() {
      _loading = false;
      _res = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final units = AppScope.unitsOf(context);
    final res = _res;
    final d = res?.data;
    final stale = d != null && (_p == null || d.params.lat.toStringAsFixed(5) != _p!.latitude.toStringAsFixed(5) || d.params.lon.toStringAsFixed(5) != _p!.longitude.toStringAsFixed(5));
    final colors = {'fringe': m.levelWeak, 'usable': m.levelFair, 'solid': m.levelStrong};
    final repByKey = {for (final r in s.regionRepeaterSet.rows) r.key.toLowerCase(): r};
    final linkPins = <PlanPin>[];
    if (d != null) {
      for (final l in d.links.where((l) => l.marginDb >= 0)) {
        final r = repByKey[l.publicKey.toLowerCase()];
        if (r != null) linkPins.add(PlanPin(LatLng(r.lat, r.lon), l.name, PlanPinKind.repeater));
      }
    }
    return PlanPage(id: 'painter', title: 'Coverage painter', children: [
      Text(
        'Modelled coverage from any point, from terrain and the link model. It is a model, not a measurement: measured coverage is on the Drive tab. '
        'Only the point and the settings below are sent to ${s.viewingRegion?.name ?? 'the server'}.',
        style: t.textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.m),
      PlanCard(
        cardKey: const Key('painter-inputs'),
        title: 'Where and what',
        children: [
          PlanMap(
            height: 300,
            pins: [if (_p != null) PlanPin(_p!, 'A', PlanPinKind.point), ...linkPins],
            polygons: [
              if (d != null && !stale)
                for (final b in d.footprint)
                  if (colors[b.id] != null)
                    for (final ring in b.rings) PlanPolygon([for (final c in ring) LatLng(c.$1, c.$2)], colors[b.id]!),
            ],
            fitKey: d == null || stale ? _p : d.computedAt ?? d.params.lat,
            onTap: (p) => setState(() => _p = p),
            semanticLabel: 'Map of the modelled coverage. Tap to place the antenna. The point can also be typed below.',
          ),
          const SizedBox(height: Gap.m),
          PointField(id: 'painter-point', label: 'Antenna', value: _p, onChanged: (p) => setState(() => _p = p)),
          const SizedBox(height: Gap.s),
          PlanSlider(id: 'painter-ft', label: 'Antenna height', valueText: units.height(_ft * ftM), value: _ft, min: 6, max: 200, onChanged: (v) => setState(() => _ft = v.roundToDouble())),
          PlanSlider(id: 'painter-tx', label: 'Transmit power', valueText: '${_tx.round()} dBm', value: _tx, min: 0, max: 30, divisions: 30, onChanged: (v) => setState(() => _tx = v)),
          PlanSlider(id: 'painter-gain', label: 'Antenna gain', valueText: '${_gain.toStringAsFixed(1)} dBi', value: _gain, min: -3, max: 12, divisions: 30, onChanged: (v) => setState(() => _gain = v)),
          PlanSlider(
              id: 'painter-radius',
              label: 'Radius',
              valueText: units.distance(_radius * 1000),
              value: _radius,
              min: 5,
              max: 20,
              divisions: 30,
              onChanged: (v) => setState(() => _radius = v)),
          PlanSegments<String>(
            label: 'Who is listening',
            segKey: const Key('painter-rx'),
            selected: _rx,
            segments: const [ButtonSegment(value: 'handheld', label: Text('Handheld')), ButtonSegment(value: 'repeater', label: Text('Repeater'))],
            onChanged: (v) => setState(() => _rx = v),
          ),
          const SizedBox(height: Gap.m),
          FilledButton.icon(
            key: const Key('painter-run'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _p == null || _loading ? null : _run,
            icon: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.blur_on),
            label: Text(_p == null ? 'Place the antenna to paint' : _loading ? 'Painting coverage...' : 'Paint coverage'),
          ),
          if (_loading) const PlanNote('The model reads terrain tiles and sweeps the area; the first run for a place can take up to a minute.', icon: Icons.hourglass_empty),
        ],
      ),
      if (res != null && !res.ok) PlanCard(title: 'Could not paint coverage', children: [PlanError(res.error!, onRetry: _p == null ? null : _run)]),
      if (d != null) _result(context, res!, d, stale, colors),
    ]);
  }

  Widget _result(BuildContext context, PlanResult<PainterResult> res, PainterResult d, bool stale, Map<String, Color> colors) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    String area(double km2) => units.distanceImperial ? '${(km2 * 0.386102).toStringAsFixed(2)} sq mi' : '${km2.toStringAsFixed(2)} km2';
    final bandWords = {'below': 'No decode (below 0 dB margin)', 'fringe': 'Fringe (0 to 6 dB)', 'usable': 'Usable (6 to 12 dB)', 'solid': 'Solid (over 12 dB)'};
    final shown = d.links.where((l) => l.marginDb >= 0).toList();
    return PlanCard(
      cardKey: const Key('painter-result'),
      title: 'Modelled coverage',
      lead: 'Antenna ${units.height(d.params.antennaFt * ftM)} at ${d.params.lat.toStringAsFixed(4)}, ${d.params.lon.toStringAsFixed(4)}, ${d.params.txDbm.round()} dBm, ${d.params.gainDbi.toStringAsFixed(1)} dBi, '
          '${d.params.receiver == 'repeater' ? 'repeater' : 'handheld'} listening, ${units.distance(d.params.radiusKm * 1000)} radius.',
      children: [
        if (res.offlineAsOf != null) OfflineAsOf(res.offlineAsOf!),
        if (stale) const PlanNote('The antenna point changed. Paint again to update the map.', icon: Icons.refresh, key: Key('painter-stale')),
        Text(area(d.coveredKm2), key: const Key('painter-covered'), style: numberStyle(context, size: 30)),
        Text('with a signal that can be decoded', style: t.textTheme.bodySmall),
        const SizedBox(height: Gap.s),
        for (final b in d.bands)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: colors[b.id]?.withValues(alpha: 0.55) ?? Colors.transparent, border: Border.all(color: t.colorScheme.outline), borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: Gap.s),
              Expanded(child: Text(bandWords[b.id] ?? b.label, key: Key('painter-band-${b.id}'))),
              Text(area(b.areaKm2), style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
        if (d.peopleInRadius != null) ...[
          const Divider(),
          PlanFacts([
            ('People within the radius', '${d.peopleInRadius}'),
            if (d.peopleCovered != null) ('People in modelled coverage', '${d.peopleCovered}'),
            if (d.peopleNew != null) ('Not covered by a live repeater today', '${d.peopleNew}'),
          ]),
        ],
        if (shown.isNotEmpty) ...[
          const Divider(),
          Text('Predicted links to live repeaters', style: t.textTheme.titleSmall),
          for (final l in shown.take(12))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(l.name),
              subtitle: Text('${units.distance(l.km * 1000)} away'),
              trailing: Text(fmtDb(l.marginDb, signed: true), style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
        ] else
          const PlanNote('No live repeater is predicted to hear a node here.', key: Key('painter-nolinks')),
        const SizedBox(height: Gap.s),
        Text(
          '${d.note} Terrain: ${d.terrainSource}. Population: census block groups, where the region has them.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        if (d.serverCached) Text('The server answered from its stored run for these settings${d.computedAt == null ? '' : ' (computed ${d.computedAt!.toLocal().toString().substring(0, 16)})'}.', style: t.textTheme.bodySmall),
      ],
    );
  }
}
