// The ONE legend card (plan unified-map-system §2.5, the website's components/map/one/legend-card.tsx): compact on the map (the
// band ramp and "Weak → strong signal"). On a map with a transient panel slot a tap opens the MapPanel `drive.legend`
// ([LegendCard.onOpen], [LegendCard.asPanel]) instead of growing over the map; elsewhere it expands in place to every legend
// entry of the layers that are on, all from the Map
// Definition (layer names, entry labels, symbols; dB ranges from its coverage meta). The palette chooser lives here (and in the
// Layers sheet), never only in a hidden setting: Standard or Colour-blind safe, saved in Settings like everywhere else.
//
// Keys: 'legend-card', 'legend-card-toggle', 'legend-card-body', 'legend-layer-<defId>', 'legend-palette-<paletteId>'.
import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/colour_palette.dart';
import '../../core/coverage_v2.dart' show CoverageMeta;
import '../../core/map_definition.dart';
import '../../core/map_definition_v2.dart';
import '../app.dart' show AppScope;
import '../design/anchored_sheet.dart' show MapPanelHostController;
import '../design/tokens.dart' show AppColors;
import '../design/map_panel.dart' show MapPanel;
import '../theme.dart';
import 'active_map_definition.dart';
import 'coverage_bands.dart';
import 'node_symbol.dart';
import 'layers/m3_layers.dart' show SnrLinkStyle, redundancyColour;
import 'layers/registry.dart' show definitionLayerId;
import 'layers/plan_layer.dart' show planLegendKey;
import 'layers/repeater_sprites.dart' show RepeaterSymbolStyle;
import 'legend_sheet.dart' show showMapLegend;
import 'map_layers.dart' show PingColorMode;
import 'parts/map_chips.dart' show MapChip;
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
  if (planLegendKey(context, e.symbol, state: e.state) case final k?) return k;
  switch (e.symbol) {
    case 'repeater':
      return RepeaterRingKey(state: e.state ?? 'fresh');
    case 'observer':
      return ExcludeSemantics(child: NodeSymbol(role: 'observer', freshness: e.state == 'offline' ? 'stale' : 'fresh', size: 18, scaled: false));
    case 'phone':
      return const ExcludeSemantics(child: NodeSymbol(role: 'phone', size: 18, scaled: false));
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
      return ExcludeSemantics(child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: mc.repeater)));
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

  /// The chip on a map with a transient panel slot: a tap calls this (the host shows the legend as a MapPanel) and the card
  /// itself never grows over the map.
  final VoidCallback? onOpen;

  /// Only the entries (no chip, no card): the body of the legend MapPanel.
  final bool asPanel;

  /// The short chip of the Drive map (build 76): the band ramp and "Weak → strong", no chevron, so it takes a third less of
  /// the map, and as tall as the region chip above it (36 pt; it was 28).
  final bool compact;

  /// Which map the legend is for: it decides the extra entries (Live: packet colours and line styles; Plan: plan markers).
  final MapLegendPage page;
  const LegendCard({super.key, required this.on, this.meta, this.local = false, this.drivePanel = true, this.initiallyOpen = false, this.onOpen, this.asPanel = false, this.compact = false, this.page = MapLegendPage.drive});

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
    final ld = def.legendDef;
    bool isOn(MapLayerDef l) {
      // Plan: the plan's own (magenta) markers are always explained there (Round 4 section 3).
      if (widget.page == MapLegendPage.plan && l.id == 'plan') return true;
      if (l.panelOnly) return l.id == 'drive' && widget.drivePanel && widget.on.contains('hexes');
      return widget.on.any((a) => definitionLayerId(a) == l.id);
    }

    final visible = [
      for (final l in def.layerDefs.reversed)
        if (isOn(l) && !(widget.local && l.hidesWithTime) && l.legend.isNotEmpty) l,
    ];
    final anyCoverage = visible.any((l) => l.group == 'coverage' || layerSectionOf(l) == 'coverage');
    final small = t.textTheme.bodySmall;
    final dim = small?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final labels = def.bandLabels;
    String label(int b) => widget.meta?.labelOf(b) ?? labels[b] ?? 'Band $b';

    // In the panel the rows are a size up and further apart (build 76): there is room, and it is read at arm's length.
    final rowText = widget.asPanel ? t.textTheme.bodyMedium : small;
    Widget row(Widget key, String text, {String? detail, Key? rowKey}) => LegendRow(key: rowKey, symbol: key, label: text, detail: detail, style: rowText, dense: !widget.asPanel);

    // The chip (Round 1 F4): the one map chip style, 36 pt drawn and 44 pt to tap, with a chevron so it looks tappable. The
    // wording is the same on every map: "Weak → strong" (Round 4 section 3, Round 5 D-17).
    final chipLabel = anyCoverage ? 'Weak → strong' : 'Legend';
    final head = MapChip(
      tapKey: const Key('legend-card-toggle'),
      semanticsLabel: anyCoverage ? 'Legend: weak to strong signal' : 'Legend',
      expanded: widget.onOpen == null ? _open : null,
      onTap: widget.onOpen ?? () => setState(() => _open = !_open),
      leading: anyCoverage
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              for (final b in const [1, 2, 3, 4, 5]) Padding(padding: const EdgeInsets.only(right: 2), child: CoverageBandSwatch(band: b, colors: bands, size: 11)),
            ])
          : null,
      label: Text(chipLabel),
    );

    // Panel order (Round 1 N2): coverage first, then my drive, repeaters, people, appearance; extras that are not layers
    // (your position, a cluster, the selected ring, ...) in their section; on Live the packet colours and route lines.
    final sectionNames = {for (final sec in def.layerSections) sec.id: sec.name};
    String sectionName(String id) => sectionNames[id] ?? switch (id) {
      'coverage' => 'Signal coverage',
      'drive' => 'My drive',
      'repeaters' => 'Repeaters',
      'people' => 'People and listeners',
      'appearance' => 'Appearance',
      _ => id,
    };
    bool extraShows(LegendExtraDef e) {
      final onPage = switch (e.on) {
        'drive' => widget.page == MapLegendPage.drive,
        'live' => widget.page == MapLegendPage.live,
        _ => true,
      };
      if (!onPage) return false;
      return switch (e.section) {
        'repeaters' => visible.any((l) => layerSectionOf(l) == 'repeaters'),
        'people' => widget.on.contains('friends') || e.id == 'friend' && widget.page == MapLegendPage.drive,
        _ => true,
      };
    }

    Widget layerBlock(MapLayerDef l) => Padding(
      key: Key('legend-layer-${l.id}'),
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Semantics(
        container: true,
        label: l.name,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.name, style: (widget.asPanel ? t.textTheme.titleSmall : t.textTheme.labelMedium)?.copyWith(fontWeight: FontWeight.w600)),
            for (final e in l.legend)
              if (e.kind == 'bands') ...[
                if (e.note != null) Text('${e.note}:', style: dim),
                for (var b = e.from ?? 5; (e.from ?? 5) >= (e.to ?? 1) ? b >= (e.to ?? 1) : b <= (e.to ?? 1); b += (e.from ?? 5) >= (e.to ?? 1) ? -1 : 1)
                  row(CoverageBandSwatch(band: b, colors: bands, size: 14), [label(b), ?widget.meta?.rangeText(b)].join('  ')),
              ] else
                row(legendEntryKey(context, e, def), e.label ?? '', detail: e.detail),
          ],
        ),
      ),
    );

    final sections = <Widget>[];
    for (final id in ld.order) {
      final layers = [for (final l in visible) if (layerSectionOf(l) == id) l];
      final extras = [for (final e in ld.extras) if (e.section == id && extraShows(e)) e];
      if (layers.isEmpty && extras.isEmpty) continue;
      sections.add(Padding(
        key: Key('legend-section-$id'),
        padding: const EdgeInsets.only(top: Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(sectionName(id), style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          for (final l in layers) layerBlock(l),
          for (final e in extras) row(legendExtraKey(context, e.symbol), e.label, detail: e.detail, rowKey: Key('legend-extra-${e.id}')),
        ]),
      ));
    }
    // A layer in a section the order does not name still shows (a newer definition), last.
    for (final l in visible) {
      if (!ld.order.contains(layerSectionOf(l))) sections.add(layerBlock(l));
    }
    if (widget.page == MapLegendPage.live) sections.add(_liveSection(context, def, ld, row));

    final body = !(_open && widget.onOpen == null) && !widget.asPanel
        ? null
        : ConstrainedBox(
            constraints: widget.asPanel ? const BoxConstraints() : BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42, maxWidth: 300),
            child: SingleChildScrollView(
              key: const Key('legend-card-body'),
              padding: widget.asPanel ? const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m) : const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...sections,
                  if (widget.local && def.filter('time').note != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(def.filter('time').note!, style: dim)),
                  if (visible.isEmpty && widget.page != MapLegendPage.live)
                    Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('No layer is switched on. Open Layers to pick some.', style: dim)),
                  Padding(padding: const EdgeInsets.only(top: Gap.m, bottom: 4), child: Text('Colours', style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600))),
                  const PaletteSwitch(),
                ],
              ),
            ),
          );

    if (widget.asPanel) return body!;
    if (body == null) return KeyedSubtree(key: const Key('legend-card'), child: head);
    return Material(
      key: const Key('legend-card'),
      color: t.colorScheme.surface.withValues(alpha: 0.94),
      elevation: 2,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
        alignment: Alignment.bottomLeft,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [head, body]),
      ),
    );
  }

  /// Live (Round 1 N2): the packet-type colours and the route line styles, in the same panel as the repeaters.
  Widget _liveSection(BuildContext context, MapDefinition def, LegendDef ld, Widget Function(Widget, String, {String? detail, Key? rowKey}) row) {
    final t = Theme.of(context);
    final types = def.packetTypes;
    final dark = t.brightness == Brightness.dark;
    final lang = ColourLanguage.of(t.brightness);
    const builtInNames = {4: 'Advert', 5: 'Group text', 2: 'Direct message', 3: 'Ack', 1: 'Response', 9: 'Trace', 8: 'Path', 0: 'Request'};
    const order = [4, 5, 2, 3, 1, 9, 8, 0];
    Color colourOf(int type, int slot) {
      if (types != null) {
        final c = types.of(type);
        return Color(dark ? c.dark : c.light);
      }
      return lang.packetTypes[slot];
    }

    Widget line(String style, Color c) => ExcludeSemantics(child: CustomPaint(size: const Size(20, 4), painter: _LineKeyPainter(style, c)));
    final ink = t.colorScheme.onSurface;
    return Padding(
      key: const Key('legend-section-live'),
      padding: const EdgeInsets.only(top: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(ld.liveTitle, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
        Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(ld.packetTypesTitle, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
        for (final (slot, type) in order.indexed)
          row(
            ExcludeSemantics(child: Container(width: 12, height: 12, decoration: BoxDecoration(color: colourOf(type, slot), shape: BoxShape.circle))),
            types?.names[type] ?? builtInNames[type]!,
            rowKey: Key('legend-packet-$type'),
          ),
        row(ExcludeSemantics(child: Container(width: 12, height: 12, decoration: BoxDecoration(color: lang.packetOther, shape: BoxShape.circle))), 'Other'),
        Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(ld.lineStylesTitle, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
        for (final st in ld.lineStyles)
          row(line(st.line, st.id == 'unplaced' ? lang.packetOther : ink), st.label, detail: st.detail, rowKey: Key('legend-line-${st.id}')),
      ]),
    );
  }
}

/// One legend row: the symbol as the map draws it and a short label; a row with a [detail] opens it on a tap (Round 1 N2:
/// labels of two to four words, detail on tap).
class LegendRow extends StatefulWidget {
  final Widget symbol;
  final String label;
  final String? detail;
  final TextStyle? style;
  final bool dense;
  const LegendRow({super.key, required this.symbol, required this.label, this.detail, this.style, this.dense = false});

  @override
  State<LegendRow> createState() => _LegendRowState();
}

class _LegendRowState extends State<LegendRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final has = widget.detail != null && widget.detail!.trim().isNotEmpty;
    final line = Padding(
      padding: EdgeInsets.symmetric(vertical: widget.dense ? 2 : 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 24, child: Center(child: widget.symbol)),
          const SizedBox(width: Gap.s),
          Expanded(child: Text(widget.label, style: widget.style)),
          if (has) Icon(_open ? Icons.expand_less_rounded : Icons.info_outline_rounded, size: 16, color: t.colorScheme.onSurfaceVariant),
        ],
      ),
    );
    if (!has) return line;
    return Semantics(
      button: true,
      expanded: _open,
      hint: _open ? null : 'Shows what it means',
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: widget.dense ? 0 : 44),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            line,
            if (_open)
              Padding(
                padding: const EdgeInsets.only(left: 32, bottom: 6),
                child: Text(widget.detail!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
          ]),
        ),
      ),
    );
  }
}

class _LineKeyPainter extends CustomPainter {
  final String style;
  final Color color;
  _LineKeyPainter(this.style, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = style == 'solid' ? 2.5 : 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (style == 'solid') {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      return;
    }
    final (on, off) = style == 'dashed' ? (5.0, 3.0) : (1.5, 3.0);
    for (var x = 0.0; x < size.width; x += on + off) {
      canvas.drawLine(Offset(x, y), Offset(math.min(size.width, x + on), y), p);
    }
  }

  @override
  bool shouldRepaint(_LineKeyPainter o) => o.style != style || o.color != color;
}

/// The symbol of a legend extra (an entry that is not a layer), drawn the way the map draws it.
Widget legendExtraKey(BuildContext context, String symbol) {
  final t = Theme.of(context);
  final mc = MeshSonarColors.of(context);
  final c = AppColors.fromTheme(t);
  Widget circle(double d, Color fill, {Color? ring, Widget? child}) => Container(
    width: d,
    height: d,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: ring == null ? null : Border.all(color: ring, width: 2)),
    child: child,
  );
  return ExcludeSemantics(
    child: switch (symbol) {
      'position' => circle(14, t.colorScheme.primary, ring: t.colorScheme.surface),
      'heardtick' => Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        const RepeaterRingKey(state: 'fresh', size: 18),
        Positioned(right: -3, bottom: -3, child: circle(9, c.ok, child: Icon(Icons.check_rounded, size: 7, color: t.colorScheme.surface))),
      ]),
      'cluster' => circle(18, t.colorScheme.surfaceContainerHighest, ring: t.colorScheme.outline, child: Text('3', style: t.textTheme.labelSmall?.copyWith(fontSize: 9, fontWeight: FontWeight.w700))),
      'selected' => circle(18, Colors.transparent, ring: t.colorScheme.onSurface, child: const RepeaterRingKey(state: 'fresh', size: 12)),
      'room' => const NodeSymbol(role: 'room', size: 18, scaled: false),
      'friend' => circle(14, mc.friend, ring: t.colorScheme.surface),
      'meet' => Icon(Icons.flag_rounded, size: 16, color: mc.friend),
      _ => circle(10, t.colorScheme.onSurfaceVariant),
    },
  );
}

/// The transient panel id of the legend on a map.
const String kLegendPanelId = 'drive.legend';

/// The map a legend is shown on (build 77: one Legend panel for Drive, Live and Plan).
enum MapLegendPage { drive, live, plan }

/// The ONE Legend panel of every full map (Drive, Network > Live, Plan): the map's transient panel `drive.legend`, opened by the
/// legend chip; a second tap on the chip closes it. Build 77 (Round 1 F1): Drive and Live each had a copy of this and they had
/// drifted apart ("Full guide" on Live). The getters are read on every rebuild, so the panel follows the layers as they change;
/// [listenable] is what tells it to rebuild (the layers model and the app state).
///
/// Keys: the panel is `map-panel-drive.legend` (MapPanel), 'legend-open-guide' is the "Map guide" button.
void toggleMapLegendPanel({
  required MapPanelHostController host,
  required Listenable listenable,
  required Set<String> Function() on,
  CoverageMeta? Function()? meta,
  bool Function()? local,
  bool Function()? drivePanel,
  PingColorMode Function()? pingColors,
  MapLegendPage page = MapLegendPage.drive,
}) {
  if (host.currentId == kLegendPanelId) return host.close(kLegendPanelId);
  host.show(
    id: kLegendPanelId,
    builder: (context) => ListenableBuilder(
      listenable: listenable,
      builder: (context, _) => MapPanel(
        id: kLegendPanelId,
        title: 'Legend',
        leading: const Icon(Icons.palette_outlined, size: 18),
        bottomSafe: false,
        onClose: () => host.close(kLegendPanelId),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: LegendCard(
                asPanel: true,
                on: on(),
                meta: meta?.call(),
                local: local?.call() ?? false,
                drivePanel: drivePanel?.call() ?? page == MapLegendPage.drive,
                page: page,
              ),
            ),
            // "Map guide" on every map, as a full-width 48 pt button.
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
              child: OutlinedButton.icon(
                key: const Key('legend-open-guide'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => showMapLegend(context, pingColors: pingColors?.call() ?? PingColorMode.snr),
                icon: const Icon(Icons.help_outline_rounded),
                label: const Text('Map guide'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
