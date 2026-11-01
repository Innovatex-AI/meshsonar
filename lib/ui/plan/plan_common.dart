// Shared pieces of the native planning screens (Plan tab): the loader that shows loading, an honest failure with Retry, the
// offline "as of" label and "nothing for this region", the small map, tier chips and figure formatting.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../core/plan/plan_native_api.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../../core/region_dataset_fetch.dart';
import '../app.dart';
import '../map/coverage_map.dart' show CoverageMap;

/// The API for the region being viewed (the region's own host picks the region).
PlanNativeApi planApiFor(BuildContext context) {
  final s = AppScope.of(context);
  final region = s.viewingRegion;
  return PlanNativeApi(region?.url ?? s.settings.serverUrl);
}

String planRegionName(BuildContext context) => AppScope.of(context).viewingRegion?.name ?? 'this region';

/// Loads one answer and builds the screen body. [available] says whether the answer holds anything (the server answers
/// `available: false` for a region with no planning data); [unavailableText] then explains it.
class PlanFetchView<T extends Object> extends StatefulWidget {
  final String id;
  final Future<RegionFetch<T>> Function() load;
  final Object reloadKey;
  final bool Function(T data) available;
  final String Function(T data) unavailableText;
  final Widget Function(BuildContext context, T data, VoidCallback reload) build;
  final DateTime Function() now;
  const PlanFetchView({
    super.key,
    required this.id,
    required this.load,
    required this.available,
    required this.unavailableText,
    required this.build,
    this.reloadKey = '',
    this.now = DateTime.now,
  });

  @override
  State<PlanFetchView<T>> createState() => _PlanFetchViewState<T>();
}

class _PlanFetchViewState<T extends Object> extends State<PlanFetchView<T>> {
  late Future<RegionFetch<T>> _future = widget.load();

  @override
  void didUpdateWidget(PlanFetchView<T> old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) _reload();
  }

  void _reload() => setState(() {
        _future = widget.load();
      });

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    final t = Theme.of(context);
    return FutureBuilder<RegionFetch<T>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(key: Key('$id-loading'), child: const CircularProgressIndicator());
        }
        final r = snap.data;
        if (r == null || !r.ok) {
          final nf = r?.notFound ?? false;
          return Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Row(key: Key(nf ? '$id-notfound' : '$id-error'), children: [
              Icon(nf ? Icons.info_outline : Icons.cloud_off),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(nf ? 'The planning engine is not published for this region.' : 'This could not load. ${r?.error ?? snap.error ?? ''}')),
              if (!nf) TextButton(key: Key('$id-retry'), onPressed: _reload, child: const Text('Retry')),
            ]),
          );
        }
        final d = r.data!;
        if (!widget.available(d)) {
          return Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Text(widget.unavailableText(d), key: Key('$id-unavailable'), style: t.textTheme.bodyLarge),
          );
        }
        return Column(children: [
          if (r.offlineAsOf != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
              child: Row(key: Key('$id-offline'), children: [
                Icon(Icons.cloud_off, size: 16, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${asOfLabel(r.offlineAsOf!, widget.now().toUtc(), offline: true)}. Pull to refresh when back online.',
                      style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              ]),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                _reload();
                await _future;
              },
              child: widget.build(context, d, _reload),
            ),
          ),
        ]);
      },
    );
  }
}

/// A reading column: on an iPad the cards would otherwise stretch across 1,100 dp.
Widget planColumn(List<Widget> children, {Key? key, EdgeInsets? padding}) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(key: key, padding: padding ?? const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl), physics: const AlwaysScrollableScrollPhysics(), children: children),
      ),
    );

Color tierColor(BuildContext context, String tier) {
  final m = MeshSonarColors.of(context);
  switch (tier) {
    case 'Strong':
      return m.levelStrong;
    case 'Likely':
      return m.levelGood;
    case 'Possible':
      return m.levelFair;
    default:
      return m.levelWeak;
  }
}

/// Tier as a word with a dot: never colour alone.
class TierChip extends StatelessWidget {
  final String tier;
  const TierChip(this.tier, {super.key});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 10, color: tierColor(context, tier)),
        const SizedBox(width: 4),
        Text(tier, style: Theme.of(context).textTheme.labelMedium),
      ]);
}

String oddsPct(double p) => '${(p * 100).toStringAsFixed(1)}%';
String signedInt(int n) => n > 0 ? '+${_g(n)}' : (n < 0 ? '−${_g(-n)}' : '±0');
String _g(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// A distance in the person's units (Settings > Units). [km] is kilometres.
String kmText(BuildContext c, double km) => AppScope.unitsOf(c).distance(km * 1000);

/// A model radius ("within 3 km") in the person's units.
String radiusText(BuildContext c, num km) => AppScope.unitsOf(c).distance(km * 1000.0);

/// An elevation or antenna height given in metres, in the person's units.
String heightText(BuildContext c, double metres) => AppScope.unitsOf(c).height(metres);

/// The plan's two mounting scenarios are named by their pole height (20 ft = 6 m, 33 ft = 10 m), the same on the website and in every unit system.
String mountName(int h) => ['$h', 'ft'].join('\u00a0');

/// A figure with a label under it (and an optional change line).
class PlanFigure extends StatelessWidget {
  final String label, value;
  final String? hint;
  const PlanFigure(this.label, this.value, {super.key, this.hint});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 130),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelMedium),
        Text(value, style: t.textTheme.titleMedium),
        if (hint != null) Text(hint!, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class PlanMarker {
  final LatLng at;
  final String? label;
  final Color color;
  final bool ring;
  final double size;
  const PlanMarker(this.at, {this.label, required this.color, this.ring = false, this.size = 22});
}

class PlanLine {
  final LatLng a, b;
  final Color color;
  final double width;
  const PlanLine(this.a, this.b, this.color, {this.width = 2});
}

typedef PlanMapBuilder = Widget Function(BuildContext context, List<PlanMarker> markers, List<PlanLine> lines);

/// The planning map: the app's own base map with numbered sites, repeaters and link lines. Pan and zoom are on.
class PlanMap extends StatelessWidget {
  /// Tiles never load in widget tests: tests replace the map for every instance.
  @visibleForTesting
  static PlanMapBuilder? testMap;

  final List<PlanMarker> markers;
  final List<PlanLine> lines;
  final double height;
  const PlanMap({super.key, required this.markers, this.lines = const [], this.height = 280});

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) return const SizedBox.shrink();
    final tm = testMap;
    if (tm != null) return SizedBox(key: const Key('plan-map'), height: height, child: tm(context, markers, lines));
    final m = MeshSonarColors.of(context);
    final pts = [for (final x in markers) x.at, for (final l in lines) ...[l.a, l.b]];
    return ClipRRect(
      key: const Key('plan-map'),
      borderRadius: BorderRadius.circular(Corners.small),
      child: SizedBox(
        height: height,
        child: FlutterMap(
          options: MapOptions(
            initialCameraFit: CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(36), maxZoom: 14),
            backgroundColor: m.mapBackground,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom),
          ),
          children: [
            TileLayer(
              urlTemplate: CoverageMap.tileUrl,
              userAgentPackageName: CoverageMap.userAgentPackageName,
              maxNativeZoom: 19,
              tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(m.tileMatrix), child: tile),
            ),
            PolylineLayer(polylines: [for (final l in lines) Polyline(points: [l.a, l.b], color: l.color, strokeWidth: l.width)]),
            MarkerLayer(markers: [
              for (final x in markers)
                Marker(
                  point: x.at,
                  width: x.size,
                  height: x.size,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: x.ring ? Colors.transparent : x.color,
                      border: Border.all(color: x.ring ? x.color : Colors.white, width: 2),
                    ),
                    child: x.label == null
                        ? null
                        : Center(
                            child: Text(x.label!, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700), textScaler: TextScaler.noScaling),
                          ),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

Widget planHeader(BuildContext context, String title, String lead) {
  final t = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: Gap.m),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(header: true, child: Text(title, style: t.textTheme.titleLarge)),
      const SizedBox(height: Gap.xs),
      Text(lead, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]),
  );
}

Widget planSection(BuildContext context, String title, {String? lead, required List<Widget> children, Key? key}) {
  final t = Theme.of(context);
  return Card(
    key: key,
    margin: const EdgeInsets.only(bottom: Gap.m),
    child: Padding(
      padding: const EdgeInsets.all(Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium)),
        if (lead != null) ...[
          const SizedBox(height: Gap.xs),
          Text(lead, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: Gap.s),
        ...children,
      ]),
    ),
  );
}

/// Two small series on a shared axis: the engine's sequence (a line per site built) and the original plan (a few points joined by a
/// dashed line). Drawn, with a text table under it by the caller, so nothing is colour-only.
class SeriesChartPainter extends CustomPainter {
  final List<(int, double)> engine;
  final List<(int, double)> original;
  final Color engineColor, originalColor, axisColor;
  final TextStyle labelStyle;
  const SeriesChartPainter(this.engine, this.original, this.engineColor, this.originalColor, this.axisColor, this.labelStyle);

  @override
  void paint(Canvas canvas, Size size) {
    if (engine.isEmpty) return;
    const left = 44.0, bottom = 22.0, top = 8.0, right = 8.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    final all = [...engine, ...original];
    final maxX = all.map((e) => e.$1).reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
    var lo = all.map((e) => e.$2).reduce((a, b) => a < b ? a : b), hi = all.map((e) => e.$2).reduce((a, b) => a > b ? a : b);
    if (hi - lo < 1) hi = lo + 1;
    final pad = (hi - lo) * 0.06;
    lo = (lo - pad).clamp(0, double.infinity);
    hi += pad;
    double px(int x) => left + w * x / maxX;
    double py(double v) => top + h * (1 - (v - lo) / (hi - lo));
    final axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, top), Offset(left, top + h), axis);
    canvas.drawLine(Offset(left, top + h), Offset(left + w, top + h), axis);
    void label(String text, Offset at, {bool right = false}) {
      final tp = TextPainter(text: TextSpan(text: text, style: labelStyle), textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling)..layout();
      tp.paint(canvas, right ? Offset(at.dx - tp.width, at.dy - tp.height / 2) : Offset(at.dx - tp.width / 2, at.dy));
    }

    label(_fmt(hi), Offset(left - 4, top + 4), right: true);
    label(_fmt(lo), Offset(left - 4, top + h - 4), right: true);
    label('0', Offset(left, top + h + 4));
    label('$maxX sites', Offset(left + w - 18, top + h + 4));
    final line = Paint()
      ..color = engineColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < engine.length; i++) {
      final o = Offset(px(engine[i].$1), py(engine[i].$2));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, line);
    if (original.length > 1) {
      final dash = Paint()
        ..color = originalColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      for (var i = 0; i + 1 < original.length; i++) {
        final a = Offset(px(original[i].$1), py(original[i].$2)), b = Offset(px(original[i + 1].$1), py(original[i + 1].$2));
        final len = (b - a).distance;
        final dir = (b - a) / len;
        for (var d = 0.0; d < len; d += 10) {
          canvas.drawLine(a + dir * d, a + dir * (d + 5 > len ? len : d + 5), dash);
        }
      }
      for (final o in original) {
        canvas.drawCircle(Offset(px(o.$1), py(o.$2)), 4, Paint()..color = originalColor);
      }
    }
  }

  static String _fmt(double v) => v >= 10000 ? '${(v / 1000).round()}k' : v.round().toString();

  @override
  bool shouldRepaint(SeriesChartPainter old) => old.engine != engine || old.original != original;
}
