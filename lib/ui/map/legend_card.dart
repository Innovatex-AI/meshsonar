// The ONE legend card (plan unified-map-system §2.5, the website's components/map/one/legend-card.tsx): compact on the map (the
// band ramp and "Weak → strong signal"), expandable to every legend entry of the layers that are on, all from the Map
// Definition (layer names, entry labels, symbols; dB ranges from its coverage meta). The palette chooser lives here (and in the
// Layers sheet), never only in a hidden setting: Standard or Colour-blind safe, saved in Settings like everywhere else.
//
// Keys: 'legend-card', 'legend-card-toggle', 'legend-card-body', 'legend-layer-<defId>', 'legend-palette-<paletteId>'.
import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../../core/colour_palette.dart';
import '../../core/coverage_v2.dart' show CoverageMeta;
import '../../core/map_definition.dart';
import '../app.dart' show AppScope;
import '../design/app_symbols.dart';
import '../theme.dart';
import 'active_map_definition.dart';
import 'coverage_bands.dart';
import 'layers/observer_layer.dart' show MobileObserverPainter, ObserverSymbolColours, ObserverTrianglePainter;
import 'layers/m3_layers.dart' show SnrLinkStyle, redundancyColour;
import 'layers/registry.dart' show definitionLayerId;
import 'layers/repeater_sprites.dart' show RepeaterSymbolStyle;
import 'sheets/coverage_cell_sheet.dart' show CoverageBandSwatch;

/// Standard | Colour-blind safe, from the definition's `palettes` (names and order). Writes Settings > Colour palette.
class PaletteSwitch extends StatelessWidget {
  final String keyPrefix;
  const PaletteSwitch({super.key, this.keyPrefix = 'legend-palette'});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.maybeOf(context);
    final cur = s?.settings.colourPalette ?? MeshSonarColors.of(context).palette;
    final defs = ActiveMapDefinition.current.paletteDefs;
    return Semantics(
      label: 'Colour palette',
      child: CupertinoSlidingSegmentedControl<String>(
        key: Key(keyPrefix),
        groupValue: cur.id,
        children: {
          for (final p in defs)
            p.id: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6),
              child: Text(p.name, key: Key('$keyPrefix-${p.id}'), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        },
        onValueChanged: (id) {
          if (id == null || s == null) return;
          final p = ColourPalette.parse(id);
          if (p != s.settings.colourPalette) s.updateSettings(s.settings.copyWith(colourPalette: p));
        },
      ),
    );
  }
}

/// A repeater status key: the definition's neutral tower disc with the state's ring (solid / dashed / none + faded), the
/// symbol the map draws.
class RepeaterRingKey extends StatelessWidget {
  final String state;
  final double size;
  const RepeaterRingKey({super.key, required this.state, this.size = 16});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: _RingKeyPainter(state, RepeaterSymbolStyle.of(Theme.of(context).brightness))),
  );
}

class _RingKeyPainter extends CustomPainter {
  final String state;
  final RepeaterSymbolStyle s;
  _RingKeyPainter(this.state, this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final k = size.width / 16;
    final stale = state == 'stale';
    if (stale) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, s.staleOpacity));
    canvas.drawCircle(c, 4.6 * k, Paint()..color = s.disc);
    canvas.drawCircle(c, 4.6 * k, Paint()..style = PaintingStyle.stroke..strokeWidth = k..color = s.ring.withValues(alpha: 0.6));
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = s.icon;
    canvas.drawPath(Path()..moveTo(c.dx - 2 * k, c.dy + 2.5 * k)..lineTo(c.dx, c.dy - 2 * k)..lineTo(c.dx + 2 * k, c.dy + 2.5 * k), p);
    if (!stale) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * k
        ..color = s.ring;
      if (state == 'recent') {
        const n = 10;
        for (var i = 0; i < n; i++) {
          canvas.drawArc(Rect.fromCircle(center: c, radius: 6.6 * k), i * 2 * 3.14159 / n, 0.36, false, ring);
        }
      } else {
        canvas.drawCircle(c, 6.6 * k, ring);
      }
    }
    if (stale) canvas.restore();
  }

  @override
  bool shouldRepaint(_RingKeyPainter o) => o.state != state || o.s != s;
}

/// The key of one legend entry, drawn the way the map draws it.
Widget legendEntryKey(BuildContext context, LegendEntryDef e, MapDefinition def) {
  final mc = MeshSonarColors.of(context);
  final br = Theme.of(context).brightness;
  final c = CoverageBandColors.of(mc.palette, br, definition: def);
  switch (e.kind) {
    case 'band':
      return CoverageBandSwatch(band: e.band ?? 0, colors: c, size: 16);
    case 'hatch':
      return CoverageBandSwatch(band: e.band ?? 4, colors: c, predicted: true, size: 16);
    case 'outline':
      return CoverageBandSwatch(band: e.band ?? 4, colors: c, heard: true, size: 16);
    case 'faint':
      return CoverageBandSwatch(band: 4, colors: c, faint: true, size: 16);
    case 'step':
      // Redundancy (M3): the definition's purple ramp, step 1..4.
      return ExcludeSemantics(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: redundancyColour(def, e.step ?? 1, dark: br == Brightness.dark).withValues(alpha: def.symbol('redundancy')['opacity'] is num ? (def.symbol('redundancy')['opacity'] as num).toDouble() : 1), borderRadius: BorderRadius.circular(3)),
        ),
      );
  }
  final obs = ObserverSymbolColours.of(br);
  switch (e.symbol) {
    case 'repeater':
      return RepeaterRingKey(state: e.state ?? 'fresh');
    case 'observer':
      final online = e.state != 'offline';
      return ExcludeSemantics(
        child: CustomPaint(
          size: const Size(16, 14),
          painter: ObserverTrianglePainter(fill: online ? obs.observerStroke : null, stroke: online ? obs.observerFill : obs.observerOffline, halo: obs.observerFill),
        ),
      );
    case 'phone':
      return ExcludeSemantics(
        child: CustomPaint(size: const Size.square(14), painter: MobileObserverPainter(fill: obs.phoneFill, glyph: obs.phoneStroke, halo: obs.phoneFill)),
      );
    case 'estimated':
      // Estimated position (M3): the repeater symbol, paler by confidence (the definition's opacity for the state).
      final o = def.symbol('estimated')['opacity'];
      final op = o is Map && o[e.state] is num ? (o[e.state] as num).toDouble() : 0.6;
      return Opacity(opacity: op, child: const RepeaterRingKey(state: 'fresh'));
    case 'snrlink':
      // Links by SNR with no SNR (M3): the neutral dashed line.
      final nc = SnrLinkStyle.of(def, dark: br == Brightness.dark).noSnr;
      return ExcludeSemantics(
        child: SizedBox(width: 16, height: 3, child: Row(children: [for (var i = 0; i < 3; i++) ...[Container(width: 4, height: 3, color: nc), if (i < 2) const SizedBox(width: 2)]])),
      );
    case 'border':
      final col = Color(def.symbolColour('border', 'x', dark: br == Brightness.dark));
      return ExcludeSemantics(child: Container(width: 16, height: 2, color: col));
    case 'link':
      return ExcludeSemantics(child: Container(width: 16, height: 3, decoration: BoxDecoration(color: mc.linkLine, borderRadius: BorderRadius.circular(2))));
    case 'ping':
      return ExcludeSemantics(
        child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: c[e.state == 'none' ? 0 : 4])),
      );
    default:
      return ExcludeSemantics(child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: mc.beacon)));
  }
}

class LegendCard extends StatefulWidget {
  /// The app layer ids that are on (registry ids).
  final Set<String> on;
  final CoverageMeta? meta;

  /// A time window / source / timeline is picked: the layers that hide with time are left out, with the definition's note.
  final bool local;

  /// The drive panel is open (the definition's panel-only `drive` layer is drawn).
  final bool drivePanel;
  final bool initiallyOpen;
  const LegendCard({super.key, required this.on, this.meta, this.local = false, this.drivePanel = true, this.initiallyOpen = false});

  @override
  State<LegendCard> createState() => _LegendCardState();
}

class _LegendCardState extends State<LegendCard> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MapDefinition>(valueListenable: ActiveMapDefinition.notifier, builder: (context, def, _) => _card(context, def));
  }

  Widget _card(BuildContext context, MapDefinition def) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final bands = CoverageBandColors.of(mc.palette, t.brightness, definition: def);
    bool isOn(MapLayerDef l) {
      if (l.panelOnly) return l.id == 'drive' && widget.drivePanel && widget.on.contains('hexes');
      return widget.on.any((a) => definitionLayerId(a) == l.id);
    }

    final visible = [
      for (final l in def.layerDefs.reversed)
        if (isOn(l) && !(widget.local && l.hidesWithTime) && l.legend.isNotEmpty) l,
    ];
    final anyCoverage = visible.any((l) => l.group == 'coverage');
    final small = t.textTheme.bodySmall;
    final dim = small?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final labels = def.bandLabels;
    String label(int b) => widget.meta?.labelOf(b) ?? labels[b] ?? 'Band $b';

    Widget row(Widget key, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [SizedBox(width: 20, child: Center(child: key)), const SizedBox(width: Gap.s), Expanded(child: Text(text, style: small))],
      ),
    );

    final head = Semantics(
      button: true,
      expanded: _open,
      label: anyCoverage ? 'Legend: weak to strong signal' : 'Legend',
      child: InkWell(
        key: const Key('legend-card-toggle'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _open = !_open),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (anyCoverage) ...[
                  for (final b in const [1, 2, 3, 4, 5])
                    Padding(padding: const EdgeInsets.only(right: 2), child: CoverageBandSwatch(band: b, colors: bands, size: 11)),
                  const SizedBox(width: 6),
                ],
                Text(anyCoverage ? 'Weak → strong signal' : 'Legend', style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                AppSymbolIcon(_open ? AppSymbols.chevronDown : AppSymbols.chevronUp, size: 12, color: t.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );

    final body = !_open
        ? null
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42, maxWidth: 300),
            child: SingleChildScrollView(
              key: const Key('legend-card-body'),
              padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final l in visible)
                    Padding(
                      key: Key('legend-layer-${l.id}'),
                      padding: const EdgeInsets.only(top: Gap.s),
                      child: Semantics(
                        container: true,
                        label: l.name,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.name, style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                            for (final e in l.legend)
                              if (e.kind == 'bands') ...[
                                if (e.note != null) Text('${e.note}:', style: dim),
                                for (var b = e.from ?? 5; (e.from ?? 5) >= (e.to ?? 1) ? b >= (e.to ?? 1) : b <= (e.to ?? 1); b += (e.from ?? 5) >= (e.to ?? 1) ? -1 : 1)
                                  row(CoverageBandSwatch(band: b, colors: bands, size: 14), [label(b), ?widget.meta?.rangeText(b)].join('  ')),
                              ] else
                                row(legendEntryKey(context, e, def), e.label ?? ''),
                          ],
                        ),
                      ),
                    ),
                  if (widget.local && def.filter('time').note != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(def.filter('time').note!, style: dim)),
                  if (visible.isEmpty) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('No layer is switched on. Open Layers to pick some.', style: dim)),
                  Padding(padding: const EdgeInsets.only(top: Gap.m, bottom: 4), child: Text('Colours', style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600))),
                  const PaletteSwitch(),
                ],
              ),
            ),
          );

    return Material(
      key: const Key('legend-card'),
      color: t.colorScheme.surface.withValues(alpha: 0.94),
      elevation: 2,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.bottomLeft,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [head, ?body]),
      ),
    );
  }
}
