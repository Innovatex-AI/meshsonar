// Shared pieces of the native Plan tools (airtime, presets, link, painter, coverage check, field data): the page frame,
// section cards, the offline "as of" row, a labelled slider, the point picker (typed coordinates + "my location" + map tap)
// and the small tap-to-place map. Same look as the Tools screens: plain words, icon AND text for every state.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../app.dart';
import '../map/coverage_map.dart' show CoverageMap;
import '../map/region_center.dart';

/// A Plan tool page: app bar, safe area, a reading column (an iPad would otherwise stretch the cards across 1,100 dp).
class PlanPage extends StatelessWidget {
  /// Key: the scaffold is `plan-page-<id>`.
  final String id;
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  const PlanPage({super.key, required this.id, required this.title, required this.children, this.actions});

  @override
  Widget build(BuildContext context) => Scaffold(
        key: Key('plan-page-$id'),
        appBar: AppBar(title: Text(title), actions: actions),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                key: Key('plan-list-$id'),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: children,
              ),
            ),
          ),
        ),
      );
}

/// A titled card.
class PlanCard extends StatelessWidget {
  final String title;
  final String? lead;
  final List<Widget> children;
  final Key? cardKey;
  const PlanCard({super.key, required this.title, this.lead, required this.children, this.cardKey});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: cardKey,
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium)),
          if (lead != null) ...[
            const SizedBox(height: Gap.xs),
            Text(lead!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.m),
          ...children,
        ]),
      ),
    );
  }
}

/// A note with an icon AND words (colour never carries the meaning alone).
class PlanNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warn;
  const PlanNote(this.text, {super.key, this.icon = Icons.info_outline, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = warn ? t.colorScheme.error : t.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: warn ? c : null))),
      ]),
    );
  }
}

/// "Offline - as of 3h ago. Showing your last result." when a stored answer is on screen.
class OfflineAsOf extends StatelessWidget {
  final DateTime asOf;
  final DateTime Function() now;
  const OfflineAsOf(this.asOf, {super.key, this.now = DateTime.now});

  @override
  Widget build(BuildContext context) => PlanNote(
        '${asOfLabel(asOf, now().toUtc(), offline: true)}. Showing the last result; it refreshes when you are back online.',
        icon: Icons.cloud_off,
      );
}

class PlanError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const PlanError(this.message, {super.key, this.onRetry});

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(message, key: const Key('plan-error'))),
        if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
      ]);
}

/// Label + value rows for a result.
class PlanFacts extends StatelessWidget {
  final List<(String, String)> rows;
  const PlanFacts(this.rows, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Semantics(
            container: true,
            label: '${r.$1}: ${r.$2}',
            excludeSemantics: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: Text(r.$1, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
              Expanded(flex: 6, child: Text(r.$2, textAlign: TextAlign.end, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
    ]);
  }
}

/// A slider with its name and current value said in words (so it reads out the same way it looks).
class PlanSlider extends StatelessWidget {
  final String id, label, valueText;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final String? hint;
  const PlanSlider({
    super.key,
    required this.id,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
        const SizedBox(width: Gap.s),
        Flexible(child: Text(valueText, key: Key('$id-value'), textAlign: TextAlign.end, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700))),
      ]),
      Slider(
        key: Key(id),
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: valueText,
        semanticFormatterCallback: (_) => '$label, $valueText',
        onChanged: onChanged,
      ),
      if (hint != null) Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text(hint!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
    ]);
  }
}

/// A dropdown with its label.
class PlanDropdown<T> extends StatelessWidget {
  final String id, label;
  final T value;
  final List<T> items;
  final String Function(T) text;
  final ValueChanged<T> onChanged;
  const PlanDropdown({super.key, required this.id, required this.label, required this.value, required this.items, required this.text, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        key: Key(id),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        items: [for (final i in items) DropdownMenuItem<T>(value: i, child: Text(text(i), overflow: TextOverflow.ellipsis))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
}

/// A label above a segmented choice that scrolls sideways instead of overflowing at large text sizes.
class PlanSegments<T> extends StatelessWidget {
  final String label;
  final Key? segKey;
  final T selected;
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onChanged;
  const PlanSegments({super.key, required this.label, this.segKey, required this.selected, required this.segments, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: Gap.xs),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<T>(key: segKey, showSelectedIcon: false, segments: segments, selected: {selected}, onSelectionChanged: (v) => onChanged(v.first)),
        ),
      ]);
}

// ================================================================ coordinates
/// "39.96, -82.99" (also "39.96 -82.99", "N39.96 W82.99" is not understood on purpose). Null when it is not a place.
LatLng? parseLatLon(String text) {
  final m = RegExp(r'^\s*(-?\d{1,2}(?:\.\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:\.\d+)?)\s*$').firstMatch(text);
  if (m == null) return null;
  final lat = double.parse(m.group(1)!), lon = double.parse(m.group(2)!);
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return LatLng(lat, lon);
}

String formatLatLon(LatLng p) => '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

/// One point of a tool: typed coordinates, "Use my location" (the fix the app already holds; never a permission prompt)
/// and, when [placing] is on, the next tap on the map. [label] names it ("Point A").
class PointField extends StatefulWidget {
  final String id, label;
  final LatLng? value;
  final ValueChanged<LatLng?> onChanged;

  /// True while a map tap will set this point.
  final bool placing;
  final VoidCallback? onPlace;
  const PointField({super.key, required this.id, required this.label, required this.value, required this.onChanged, this.placing = false, this.onPlace});

  @override
  State<PointField> createState() => _PointFieldState();
}

class _PointFieldState extends State<PointField> {
  late final TextEditingController _c = TextEditingController(text: widget.value == null ? '' : formatLatLon(widget.value!));
  String? _err;

  @override
  void didUpdateWidget(PointField old) {
    super.didUpdateWidget(old);
    final v = widget.value;
    if (v != old.value) {
      // A pick on the map, "my location" or a swap rewrites the text; typing in the field does not fight itself.
      final typed = parseLatLon(_c.text);
      if (v == null ? _c.text.isNotEmpty : (typed == null || formatLatLon(typed) != formatLatLon(v))) {
        _c.text = v == null ? '' : formatLatLon(v);
      }
      _err = null;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _commit(String text) {
    if (text.trim().isEmpty) {
      setState(() => _err = null);
      widget.onChanged(null);
      return;
    }
    final p = parseLatLon(text);
    setState(() => _err = p == null ? 'Type latitude, longitude, for example 39.96, -82.99.' : null);
    if (p != null) widget.onChanged(p);
  }

  void _here() {
    final f = AppScope.read(context).phoneFix;
    if (f == null) {
      setState(() => _err = 'The phone has no position yet. Turn on location in Settings, or tap the map.');
      return;
    }
    widget.onChanged(LatLng(f.fix.lat, f.fix.lon));
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        key: Key('${widget.id}-field'),
        controller: _c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: '${widget.label}: latitude, longitude',
          border: const OutlineInputBorder(),
          isDense: true,
          errorText: _err,
        ),
        onSubmitted: _commit,
        onTapOutside: (_) => _commit(_c.text),
        onEditingComplete: () => _commit(_c.text),
      ),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        OutlinedButton.icon(
          key: Key('${widget.id}-here'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
          onPressed: _here,
          icon: const Icon(Icons.my_location, size: 18),
          label: const Text('My location'),
        ),
        if (widget.onPlace != null)
          FilterChip(
            key: Key('${widget.id}-place'),
            selected: widget.placing,
            onSelected: (_) => widget.onPlace!(),
            avatar: const Icon(Icons.touch_app_outlined, size: 18),
            label: Text(widget.placing ? 'Tap the map' : 'Pick on map'),
          ),
        if (widget.value != null)
          TextButton(key: Key('${widget.id}-clear'), onPressed: () => widget.onChanged(null), child: const Text('Clear')),
      ]),
    ]);
  }
}

// ================================================================ map
enum PlanPinKind { a, b, point, repeater }

class PlanPin {
  final LatLng at;
  final String label;
  final PlanPinKind kind;
  const PlanPin(this.at, this.label, this.kind);
}

class PlanPolygon {
  final List<LatLng> ring;
  final Color color;
  const PlanPolygon(this.ring, this.color);
}

/// The small tap-to-place map of the Plan tools: OSM tiles graded to the theme (blank background offline), pins, polygons and
/// a line. Not the full map; no layers, no offline pack. [fitKey] re-frames the camera when it changes.
class PlanMap extends StatefulWidget {
  final double height;
  final List<PlanPin> pins;
  final List<PlanPolygon> polygons;
  final List<LatLng> line;
  final ValueChanged<LatLng>? onTap;
  final Object? fitKey;
  final String semanticLabel;
  const PlanMap({super.key, this.height = 280, this.pins = const [], this.polygons = const [], this.line = const [], this.onTap, this.fitKey, required this.semanticLabel});

  @override
  State<PlanMap> createState() => _PlanMapState();
}

class _PlanMapState extends State<PlanMap> {
  final MapController _map = MapController();
  bool _ready = false;

  List<LatLng> get _fitPoints => [
        for (final p in widget.pins.where((p) => p.kind != PlanPinKind.repeater)) p.at,
        for (final g in widget.polygons) ...g.ring,
      ];

  @override
  void didUpdateWidget(PlanMap old) {
    super.didUpdateWidget(old);
    if (_ready && old.fitKey != widget.fitKey) _fit();
  }

  void _fit() {
    final pts = _fitPoints;
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, math.max(_map.camera.zoom, 12));
      return;
    }
    _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(36), maxZoom: 16));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final m = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final pts = _fitPoints;
    final bounds = pts.isEmpty ? viewedRegionBounds(s) : null;
    final centre = pts.isEmpty && bounds == null ? (idleMapPosition(s) ?? viewedRegionCenter(s) ?? continentalCenter) : null;
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Corners.small),
        child: SizedBox(
          key: const Key('plan-map'),
          height: widget.height,
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: centre ?? (pts.length == 1 ? pts.first : const LatLng(0, 0)),
              initialZoom: centre != null ? (centre == continentalCenter ? continentalZoom : 11) : (pts.length == 1 ? 12 : 3),
              initialCameraFit: pts.length > 1
                  ? CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(36), maxZoom: 16)
                  : (bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(24), maxZoom: 14)),
              minZoom: 2,
              maxZoom: 18,
              backgroundColor: m.mapBackground,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onMapReady: () => _ready = true,
              onTap: widget.onTap == null ? null : (_, p) => widget.onTap!(p),
            ),
            children: [
              TileLayer(
                urlTemplate: CoverageMap.tileUrl,
                userAgentPackageName: CoverageMap.userAgentPackageName,
                maxNativeZoom: 19,
                tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(m.tileMatrix), child: tile),
              ),
              if (widget.polygons.isNotEmpty)
                PolygonLayer(polygons: [
                  for (final g in widget.polygons) Polygon(points: g.ring, color: g.color.withValues(alpha: 0.45), borderStrokeWidth: 0, hitValue: null),
                ]),
              if (widget.line.length > 1) PolylineLayer(polylines: [Polyline(points: widget.line, color: t.colorScheme.primary, strokeWidth: 3)]),
              MarkerLayer(markers: [
                for (final p in widget.pins)
                  Marker(
                    point: p.at,
                    width: p.kind == PlanPinKind.repeater ? 14 : 34,
                    height: p.kind == PlanPinKind.repeater ? 14 : 34,
                    child: p.kind == PlanPinKind.repeater
                        ? DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: m.beacon, border: Border.all(color: Colors.white, width: 1.5)))
                        : CircleAvatar(
                            backgroundColor: t.colorScheme.primary,
                            foregroundColor: t.colorScheme.onPrimary,
                            child: p.kind == PlanPinKind.point
                                ? const Icon(Icons.place, size: 18)
                                : Text(p.label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onPrimary, fontWeight: FontWeight.w700)),
                          ),
                  ),
              ]),
              const RichAttributionWidget(alignment: AttributionAlignment.bottomLeft, attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================ formatting
String fmtMs(double ms) => ms >= 1000 ? '${(ms / 1000).toStringAsFixed(2)} s' : '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms';
String fmtSeconds(double s) => s >= 60 ? '${(s / 60).toStringAsFixed(1)} min' : '${s.toStringAsFixed(1)} s';
String fmtPct(double p, [int d = 1]) => !p.isFinite ? '-' : (p > 0 && p < math.pow(10, -d) ? '<${math.pow(10, -d).toStringAsFixed(d)}%' : '${p.toStringAsFixed(d)}%');
String fmtDb(double v, {bool signed = false}) => '${signed && v > 0 ? '+' : v < 0 ? '-' : ''}${v.abs().toStringAsFixed(1)} dB';

/// Runs [fn] when the widget is still mounted.
void whenMounted(State s, VoidCallback fn) {
  if (s.mounted) fn();
}

/// Keeps an in-flight future from setting state after a newer request.
class Latest {
  int _n = 0;
  int next() => ++_n;
  bool isCurrent(int n) => n == _n;
}

Timer? debounce(Timer? t, Duration d, VoidCallback fn) {
  t?.cancel();
  return Timer(d, fn);
}

AppState planState(BuildContext context) => AppScope.of(context);
