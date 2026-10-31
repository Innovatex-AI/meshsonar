// "Legend & Info": one sheet that explains every colour and symbol on the maps, in plain words, with the real swatches.
// Opened from the info icon in the Map layers sheet and from Settings > About > Map legend. Every colour is read from the
// same functions the maps draw with (MeshSonarColors.forPing / levelColor, networkLevelColor, linkLine), so a swatch
// can never disagree with the map, and it follows the chosen colour palette and light/dark.
//
// Keys: 'legend-sheet', 'legend-section-<id>' (pings, cells, repeaters, links, observers, heard, owned, why),
// 'legend-swatch-<id>' on every swatch (a [LegendSwatch] whose `color` is the map colour), 'legend-colour-by-<mode>'.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/network_coverage.dart';
import '../claims/claim_widgets.dart' show OwnedByYouChip;
import '../theme.dart';
import 'coverage_layer_controls.dart' show colorByLabel, coverageLegend;
import 'coverage_map.dart' show networkLevelColor;
import 'layers/layers_sheet.dart' show NetworkAgeLegend;
import 'map_layers.dart' show PingColorMode;

/// Opens the legend. [colorBy] and [pingColors] are the map's current choices so the legend opens on what the person sees.
Future<void> showMapLegend(
  BuildContext context, {
  CoverageColorBy colorBy = CoverageColorBy.snr,
  PingColorMode pingColors = PingColorMode.snr,
}) {
  final h = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxHeight: h * 0.92),
    builder: (_) => MapLegendSheet(colorBy: colorBy, pingColors: pingColors),
  );
}

/// What a swatch is: a hexagon (a coverage cell), a dot (a ping or repeater), or a bar (a heard-box accent).
enum SwatchShape { hex, dot, bar }

/// A colour sample. [color] is the full-strength map colour; [faded] draws it the way a thin cell (fewer than 3 pings) is
/// drawn. Cells and hexes are drawn with the same fill and outline strengths as the map.
class LegendSwatch extends StatelessWidget {
  final Color color;
  final SwatchShape shape;
  final bool faded;

  /// Draw a "nothing heard" cell (the faintest strength on the map).
  final bool silentCell;
  final double size;
  const LegendSwatch({super.key, required this.color, this.shape = SwatchShape.hex, this.faded = false, this.silentCell = false, this.size = 30});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _SwatchPainter(color, shape, faded, silentCell, Theme.of(context).colorScheme.outlineVariant)),
    ),
  );
}

class _SwatchPainter extends CustomPainter {
  final Color color;
  final SwatchShape shape;
  final bool faded, silentCell;
  final Color guide;
  _SwatchPainter(this.color, this.shape, this.faded, this.silentCell, this.guide);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    switch (shape) {
      case SwatchShape.hex:
        final path = Path();
        for (var i = 0; i < 6; i++) {
          final a = (60.0 * i - 30) * math.pi / 180;
          final p = c + Offset(r * math.cos(a), r * math.sin(a));
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        path.close();
        final (fill, edge) = cellAlphas(silentCell ? CoverageLevel.none : CoverageLevel.good, faded ? 0 : kMinCellPings);
        canvas.drawPath(path, Paint()..color = color.withValues(alpha: fill));
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..color = color.withValues(alpha: edge),
        );
      case SwatchShape.dot:
        canvas.drawCircle(c, r * 0.62, Paint()..color = color);
        canvas.drawCircle(
          c,
          r * 0.62,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = guide,
        );
      case SwatchShape.bar:
        final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 6, height: size.height * 0.8), const Radius.circular(3));
        canvas.drawRRect(rect, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter o) => o.color != color || o.shape != shape || o.faded != faded || o.silentCell != silentCell || o.guide != guide;
}

class MapLegendSheet extends StatefulWidget {
  final CoverageColorBy colorBy;
  final PingColorMode pingColors;
  const MapLegendSheet({super.key, this.colorBy = CoverageColorBy.snr, this.pingColors = PingColorMode.snr});

  @override
  State<MapLegendSheet> createState() => _MapLegendSheetState();
}

class _MapLegendSheetState extends State<MapLegendSheet> {
  late CoverageColorBy _by = widget.colorBy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    return SingleChildScrollView(
      child: Padding(
        key: const Key('legend-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text('Map legend', style: t.textTheme.titleLarge)),
            const SizedBox(height: Gap.xs),
            Text(
              'What the colours and symbols on the maps mean. Colour palette: ${mc.palette.label}. Change it in Settings, '
              'Units & display.',
              key: const Key('legend-palette-note'),
              style: t.textTheme.bodyMedium,
            ),
            _section(context, 'pings', Icons.scatter_plot_rounded, 'Your pings', _pings(context, mc)),
            _section(context, 'cells', Icons.hexagon_outlined, 'Network coverage cells', _cells(context, mc)),
            _section(context, 'repeaters', Icons.cell_tower_rounded, 'Repeaters', _repeaters(context, mc)),
            _section(context, 'links', Icons.timeline_rounded, 'Link lines', _links(context, mc)),
            _section(context, 'observers', Icons.change_history_rounded, 'Observers', _observers(context, mc)),
            _section(context, 'heard', Icons.list_alt_rounded, 'The heard box', _heard(context, mc)),
            _section(context, 'owned', Icons.verified_outlined, 'Owned by you', _owned(context)),
            _section(context, 'why', Icons.help_outline_rounded, 'Why', _why(context)),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String id, IconData icon, String title, List<Widget> children) {
    final t = Theme.of(context);
    return Column(
      key: Key('legend-section-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Gap.l),
        Semantics(
          header: true,
          child: Row(
            children: [
              Icon(icon, size: 20, color: t.colorScheme.primary),
              const SizedBox(width: Gap.s),
              Expanded(child: Text(title, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary))),
            ],
          ),
        ),
        const SizedBox(height: Gap.xs),
        ...children,
      ],
    );
  }

  Widget _note(BuildContext context, String text, {Key? key}) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Text(text, key: key, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }

  List<Widget> _pings(BuildContext context, MeshSonarColors mc) {
    final byResult = widget.pingColors == PingColorMode.result;
    return [
      if (byResult) ...[
        LegendRow(id: 'ping-heard', swatch: LegendSwatch(color: mc.snrStrong, shape: SwatchShape.dot), title: 'Heard', detail: 'A repeater answered. (The map is set to Heard / not, so every heard ping is one colour.)'),
      ] else ...[
        LegendRow(
          id: 'ping-strong',
          swatch: LegendSwatch(color: mc.forPing(heard: true, snr: 10), shape: SwatchShape.dot),
          title: 'Strong, +10 dB or better',
          detail: 'A repeater heard you clearly.',
        ),
        LegendRow(
          id: 'ping-mid',
          swatch: LegendSwatch(color: mc.forPing(heard: true, snr: 0), shape: SwatchShape.dot),
          title: 'Middling, about 0 dB',
          detail: 'Heard, but with less margin.',
        ),
        LegendRow(
          id: 'ping-weak',
          swatch: LegendSwatch(color: mc.forPing(heard: true, snr: -10), shape: SwatchShape.dot),
          title: 'Weak, -10 dB or worse',
          detail: 'Heard, barely. Colours in between blend along the same scale.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Semantics(
            label: 'Signal scale from weakest to strongest',
            child: ExcludeSemantics(
              child: Container(
                key: const Key('legend-ping-gradient'),
                height: 10,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), gradient: LinearGradient(colors: mc.snrStops)),
              ),
            ),
          ),
        ),
      ],
      LegendRow(
        id: 'ping-silent',
        swatch: LegendSwatch(color: mc.silent, shape: SwatchShape.dot),
        title: 'Grey: nothing heard',
        detail: 'You sent a ping and no repeater answered here.',
      ),
      if (!byResult)
        LegendRow(
          id: 'ping-unknown',
          swatch: LegendSwatch(color: mc.heardUnknown, shape: SwatchShape.dot),
          title: 'Purple: heard, no signal reading',
          detail: 'A repeater answered but did not report how strong. Never coloured as a strength.',
        ),
    ];
  }

  List<Widget> _cells(BuildContext context, MeshSonarColors mc) {
    final t = Theme.of(context);
    final steps = coverageLegend(_by);
    return [
      _note(context, 'Hexagons show what everyone has measured, not just this drive.'),
      Wrap(
        spacing: Gap.s,
        children: [
          for (final by in CoverageColorBy.values)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ChoiceChip(
                key: Key('legend-colour-by-${by.name}'),
                label: Text(colorByLabel(by)),
                selected: by == _by,
                onSelected: (_) => setState(() => _by = by),
              ),
            ),
        ],
      ),
      for (final (level, text) in steps)
        LegendRow(
          id: 'cell-${level.name}',
          swatch: LegendSwatch(color: networkLevelColor(context, level), silentCell: level == CoverageLevel.none),
          title: _levelTitle(level, text),
          detail: switch (level) {
            CoverageLevel.none => 'Someone pinged here and nothing answered. Not a strength colour.',
            CoverageLevel.unknown => 'Something answered but no signal reading came with it.',
            _ => null,
          },
        ),
      LegendRow(
        id: 'cell-faded',
        swatch: LegendSwatch(color: networkLevelColor(context, CoverageLevel.good), faded: true),
        title: 'Faded: fewer than $kMinCellPings pings',
        detail: 'Too little data to trust yet. Any colour above can appear faded.',
      ),
      if (_by == CoverageColorBy.noise)
        _note(context, 'Noise is the background radio level a repeater hears with nothing on air: quieter is better.',
            key: const Key('legend-noise-note'))
      else
        const SizedBox.shrink(),
      Text(
        'Showing the ${colorByLabel(_by).toLowerCase()} colouring.',
        style: t.textTheme.labelSmall,
      ),
    ];
  }

  String _levelTitle(CoverageLevel level, String text) => switch (level) {
    CoverageLevel.unknown => 'Purple: heard, signal unknown',
    CoverageLevel.none => 'Grey: mapped, nothing heard',
    _ => '${_stepName(level)}: $text',
  };

  String _stepName(CoverageLevel level) => switch (level) {
    CoverageLevel.strong => 'Strong',
    CoverageLevel.good => 'Good',
    CoverageLevel.fair => 'Fair',
    CoverageLevel.weak => 'Weak',
    _ => '',
  };

  List<Widget> _repeaters(BuildContext context, MeshSonarColors mc) {
    final t = Theme.of(context);
    return [
      LegendRow(
        id: 'repeater-heard',
        swatch: ExcludeSemantics(child: Icon(Icons.cell_tower_rounded, size: 28, color: mc.beacon)),
        title: 'Amber tower: a repeater you heard',
        detail: 'Repeaters this drive heard, with their name when known.',
      ),
      _note(context, 'All-repeaters layer: the colour is how recently the repeater advertised itself.'),
      for (final (level, label) in NetworkAgeLegend.steps)
        LegendRow(
          id: 'age-${level.name}',
          swatch: LegendSwatch(color: networkLevelColor(context, level), shape: SwatchShape.dot),
          title: switch (label) {
            '24 h' => 'Within the last 24 hours',
            '7 d' => 'Within the last 7 days',
            '30 d' => 'Within the last 30 days',
            _ => 'Older than 30 days',
          },
        ),
      Text('Circles with a ring are room servers.', style: t.textTheme.bodySmall),
    ];
  }

  List<Widget> _links(BuildContext context, MeshSonarColors mc) => [
    LegendRow(
      id: 'link',
      swatch: ExcludeSemantics(
        child: SizedBox(
          key: const Key('legend-link-sample'),
          width: 30,
          height: 30,
          child: CustomPaint(painter: LinkSamplePainter(mc.linkLine, mc.linkLineCasing, mc.linkLineDashed)),
        ),
      ),
      title: mc.linkLineDashed ? 'Dashed line: who heard what' : 'Orange line: who heard what',
      detail: 'Tap a repeater or a cell to draw a line to each place it was heard from or heard. The label is the best '
          'signal (SNR) on that link. Line colour is never a signal strength.',
    ),
  ];

  List<Widget> _observers(BuildContext context, MeshSonarColors mc) {
    final t = Theme.of(context);
    return [
      LegendRow(
        id: 'observer-online',
        swatch: ExcludeSemantics(child: Icon(Icons.change_history_rounded, size: 28, color: t.colorScheme.primary)),
        title: 'Filled triangle: observer online',
        detail: 'A listening station that shares its position and is reporting now.',
      ),
      LegendRow(
        id: 'observer-offline',
        swatch: ExcludeSemantics(child: Icon(Icons.change_history_outlined, size: 28, color: mc.silent)),
        title: 'Hollow grey triangle: offline',
      ),
    ];
  }

  List<Widget> _heard(BuildContext context, MeshSonarColors mc) {
    final t = Theme.of(context);
    return [
      _note(context, 'The box on the full-screen map lists repeaters that answered your last pings, strongest signal first.'),
      LegendRow(
        id: 'heard-fresh',
        swatch: LegendSwatch(color: mc.forPing(heard: true, snr: 5), shape: SwatchShape.bar),
        title: 'Bright bar: heard recently',
        detail: 'The bar uses the signal scale, and the number beside it is the SNR in dB.',
      ),
      LegendRow(
        id: 'heard-missed',
        swatch: LegendSwatch(color: Color.lerp(mc.forPing(heard: true, snr: 5), t.colorScheme.outline, 0.55)!, shape: SwatchShape.bar),
        title: 'Dimmer bar: missed a ping or two',
        detail: 'Still in range, just not on the last ping.',
      ),
      LegendRow(
        id: 'heard-stale',
        swatch: LegendSwatch(color: t.colorScheme.outline.withValues(alpha: 0.5), shape: SwatchShape.bar),
        title: 'Faint grey bar: not heard for a while',
        detail: 'Kept so a drive never loses a row.',
      ),
    ];
  }

  List<Widget> _owned(BuildContext context) => [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: const Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: OwnedByYouChip())),
      ),
    ),
    _note(context, 'Shown on a repeater you have claimed with this phone. It only lets you manage that radio.'),
  ];

  List<Widget> _why(BuildContext context) => [
    _Why('What is a hexagon?', 'The map is cut into small hexagonal cells of equal shape. Each cell collects every ping that landed in it, '
        'so you can compare places fairly. Zoom in and the cells get smaller.', 'hexagon'),
    _Why('Why is a cell grey?', 'Grey means someone pinged there and no repeater answered, which is useful because it marks a gap. '
        'It is different from no hexagon at all, which means nobody has tried.', 'grey'),
    _Why('What is SNR?', 'Signal-to-noise ratio, in dB: how far the signal stood above the radio noise. Above 0 dB is clear, '
        'and a LoRa radio can still decode a little below 0. Higher is better.', 'snr'),
    _Why('Why are some colours faded?', 'A cell with fewer than $kMinCellPings pings is drawn fainter because one lucky or unlucky ping '
        'is not a reliable picture of the area.', 'faded'),
  ];
}

class _Why extends StatelessWidget {
  final String question, answer, id;
  const _Why(this.question, this.answer, this.id);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ExpansionTile(
      key: Key('legend-why-$id'),
      tilePadding: EdgeInsets.zero,
      minTileHeight: 48,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(question, style: t.textTheme.titleSmall),
      childrenPadding: const EdgeInsets.only(bottom: Gap.s),
      expandedAlignment: Alignment.centerLeft,
      children: [Text(answer, style: t.textTheme.bodyMedium)],
    );
  }
}

/// One row: a swatch, what it means, and an optional second line. Merged into a single spoken item (colour is never the
/// only way to tell what a row is: the title says it).
class LegendRow extends StatelessWidget {
  final String id;
  final Widget swatch;
  final String title;
  final String? detail;

  const LegendRow({super.key, required this.id, required this.swatch, required this.title, this.detail});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return MergeSemantics(
      child: Semantics(
        label: detail == null ? title : '$title. $detail',
        child: ConstrainedBox(
          key: Key('legend-row-$id'),
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(key: Key('legend-swatch-$id'), width: 36, child: Center(child: swatch)),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                        if (detail != null) Text(detail!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A short sample of a link line (dashed or solid, with its casing), as the map draws it.
class LinkSamplePainter extends CustomPainter {
  final Color line, casing;
  final bool dashed;
  LinkSamplePainter(this.line, this.casing, this.dashed);

  @override
  void paint(Canvas canvas, Size size) {
    final a = Offset(1, size.height - 4), b = Offset(size.width - 1, 4);
    void stroke(Paint p) {
      if (!dashed) {
        canvas.drawLine(a, b, p);
        return;
      }
      final len = (b - a).distance;
      final dir = (b - a) / len;
      for (double d = 0; d < len; d += 14) {
        canvas.drawLine(a + dir * d, a + dir * (d + 9 > len ? len : d + 9), p..strokeCap = StrokeCap.butt);
      }
    }

    stroke(Paint()..color = casing..strokeWidth = 6);
    stroke(Paint()..color = line..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(LinkSamplePainter o) => o.line != line || o.casing != casing || o.dashed != dashed;
}
