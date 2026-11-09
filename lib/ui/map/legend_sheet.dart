// "Legend & Info": one sheet that explains every colour and symbol on the maps, in plain words, with the real swatches.
// Opened from the info icon in the Map layers sheet and from Settings > About > Map legend. Every colour is read from the
// same functions the maps draw with (MeshSonarColors.forPing / levelColor, networkLevelColor, linkLine), so a swatch
// can never disagree with the map, and it follows the chosen colour palette and light/dark.
//
// Keys: 'legend-sheet', 'legend-section-<id>' (pings, cells, repeaters, links, observers, heard, owned, why),
// 'legend-swatch-<id>' on every swatch (a [LegendSwatch] whose `color` is the map colour).
//
// Coverage v2 (server capability coverageV2): the coverage section is built from `/api/coverage/meta` (band labels and dB
// ranges, saved for offline use) with the colours of coverage-v2-colours.md: five bands, No reply, Heard no direct signal,
// Faint = under 3 pings, and the hatched Predicted swatch. Without v2 the old Best-SNR steps show (one colour metric: the
// colour-by modes are gone).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_flags.dart';
import '../../core/colour_palette.dart';
import '../../core/coverage_v2.dart';
import '../../core/network_coverage.dart';
import '../app.dart' show AppScope;
import '../claims/claim_widgets.dart' show OwnedByYouChip;
import '../theme.dart';
import 'coverage_bands.dart';
import 'coverage_layer_controls.dart' show coverageLegend;
import 'coverage_map.dart' show networkLevelColor;
import 'sheets/coverage_cell_sheet.dart' show CoverageBandSwatch;
import 'layers/layers_sheet.dart' show repeaterFreshnessKey;
import 'map_layers.dart' show PingColorMode;
import '../design/app_surfaces.dart';

/// Opens the legend. [pingColors] is the map's current choice so the legend opens on what the person sees. Coverage v2 and its
/// meta are read from the app (null [v2] = ask the app).
Future<void> showMapLegend(BuildContext context, {PingColorMode pingColors = PingColorMode.snr}) {
  final app = AppScope.maybeOf(context);
  final v2 = app?.coverageV2 ?? false;
  final meta = app?.coverageMeta;
  return showAppSheet<void>(
    context,
    detents: const [0.6, 0.92],
    builder: (ctx, c) => SafeArea(
      child: MapLegendSheet(pingColors: pingColors, coverageV2: v2, meta: meta, onDone: () => Navigator.of(ctx).pop()),
    ),
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
  final PingColorMode pingColors;
  final VoidCallback? onDone;

  /// Draw the coverage v2 legend (from [meta], [CoverageMeta.fallback] when none was read yet).
  final bool coverageV2;
  final CoverageMeta? meta;
  const MapLegendSheet({super.key, this.pingColors = PingColorMode.snr, this.onDone, this.coverageV2 = false, this.meta});

  @override
  State<MapLegendSheet> createState() => _MapLegendSheetState();
}

class _MapLegendSheetState extends State<MapLegendSheet> {

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
            Row(
              children: [
                Expanded(child: Semantics(header: true, child: Text('Map guide', style: t.textTheme.titleLarge))),
                if (widget.onDone != null)
                  TextButton(key: const Key('legend-done'), onPressed: widget.onDone, child: const Text('Done')),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'What the colours and symbols on the maps mean. Colour palette: ${mc.palette.label}. Change it in Settings, '
              'Units & display.',
              key: const Key('legend-palette-note'),
              style: t.textTheme.bodyMedium,
            ),
            _section(context, 'pings', Icons.scatter_plot_rounded, 'Your pings', _pings(context, mc)),
            if (widget.coverageV2) ...[
              _section(context, 'cells', Icons.hexagon_outlined, 'Measured coverage', _cellsV2(context, mc)),
              _section(context, 'predicted', Icons.texture_rounded, 'Predicted coverage', _predictedV2(context, mc)),
              _section(context, 'yours', Icons.hexagon_rounded, 'This drive', _yoursV2(context, mc)),
            ] else ...[
              _section(context, 'cells', Icons.hexagon_outlined, 'Network coverage cells', _cells(context, mc)),
              _section(context, 'yours', Icons.hexagon_rounded, 'Your coverage (hexagons)', _yourHexes(context, mc)),
            ],
            _section(context, 'repeaters', Icons.cell_tower_rounded, 'Repeaters', _repeaters(context, mc)),
            _section(context, 'links', Icons.timeline_rounded, 'Link lines', _links(context, mc)),
            _section(context, 'observers', Icons.change_history_rounded, 'Observers', _observers(context, mc)),
            // The heard box exists only on the old Drive layout (Developer > New Drive screen off); the redesigned screen has none.
            if (!AppFlags.driveRedesign) _section(context, 'heard', Icons.list_alt_rounded, 'The heard box', _heard(context, mc)),
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
    final steps = coverageLegend();
    return [
      _note(context, 'Hexagons show what everyone has measured, not just this drive.'),
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
    ];
  }

  // ---------- coverage v2 ----------
  CoverageMeta get _meta => widget.meta ?? CoverageMeta.fallback;
  CoverageBandColors _bands(BuildContext context, MeshSonarColors mc) => CoverageBandColors.of(mc.palette, Theme.of(context).brightness);

  List<Widget> _bandRows(BuildContext context, MeshSonarColors mc, String prefix, {bool predicted = false}) {
    final meta = _meta;
    final c = _bands(context, mc);
    final sf = presetSf(meta.defaultPreset);
    return [
      for (final b in [5, 4, 3, 2, 1])
        LegendRow(
          id: '$prefix-band-$b',
          swatch: CoverageBandSwatch(band: b, colors: c, predicted: predicted, size: 26),
          title: '${meta.labelOf(b)}, ${meta.rangeText(b, sf: sf)}',
        ),
    ];
  }

  List<Widget> _cellsV2(BuildContext context, MeshSonarColors mc) {
    final meta = _meta;
    final c = _bands(context, mc);
    return [
      _note(
        context,
        'Everyone\'s drives. Each cell is about ${AppScope.unitsOf(context).distance(50, approx: true)} across, the same size at '
        'every zoom. Its colour is the average SNR of every ping that was heard there. Zoomed out, each cell is a dot.',
        key: const Key('legend-v2-note'),
      ),
      ..._bandRows(context, mc, 'cell'),
      LegendRow(
        id: 'cell-band-0',
        swatch: CoverageBandSwatch(band: 0, colors: c, size: 26),
        title: meta.labelOf(0),
        detail: mc.palette == ColourPalette.standard
            ? 'Pinged here and nothing answered: no coverage. Dark red, the bottom of the red to green scale.'
            : 'Pinged here and nothing answered: no coverage. Drawn with a red outline.',
      ),
      LegendRow(
        id: 'cell-band-6',
        swatch: CoverageBandSwatch(band: 6, colors: c, size: 26),
        title: meta.labelOf(6),
        detail: 'Heard only through a relay, or with no signal reading. Not a strength colour.',
      ),
      LegendRow(
        id: 'cell-faded',
        swatch: CoverageBandSwatch(band: 4, colors: c, faint: true, size: 26),
        title: 'Faint = under ${meta.faintBelow} pings',
        detail: 'Too little data to trust yet. Any colour above can appear faint.',
      ),
    ];
  }

  List<Widget> _predictedV2(BuildContext context, MeshSonarColors mc) {
    final c = _bands(context, mc);
    return [
      _note(
        context,
        'An estimate for cells nobody has driven, from the measured cells within ${AppScope.unitsOf(context).distance(1000, approx: true)}. '
        'Same colours, hatched and lighter; '
        'the further from a measurement, the fainter. Always drawn under measured cells.',
        key: const Key('legend-predicted-note'),
      ),
      LegendRow(id: 'predicted-sample', swatch: CoverageBandSwatch(band: 4, colors: c, predicted: true, size: 26), title: 'Predicted coverage'),
      LegendRow(
        id: 'predicted-none',
        swatch: CoverageBandSwatch(band: 0, colors: c, predicted: true, size: 26),
        title: 'Predicted: no coverage',
        detail: 'A thin hatch in the No reply colour, no fill. Not drawn when zoomed out.',
      ),
    ];
  }

  List<Widget> _yoursV2(BuildContext context, MeshSonarColors mc) => [
    _note(
      context,
      'Your pings this session in the same cells and colours, with a solid outline so they stand out. Built on this phone '
      'as you drive.',
      key: const Key('legend-yours-note'),
    ),
  ];

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

  /// Your coverage (layer `hexes`, Drive plan 7.3 F3): the drive's own hexagons, coloured like the Pings layer.
  List<Widget> _yourHexes(BuildContext context, MeshSonarColors mc) {
    final byResult = widget.pingColors == PingColorMode.result;
    return [
      _note(context, 'Your pings rolled up to the same hexagons as the website. This is only what this phone recorded.'),
      if (byResult) ...[
        LegendRow(id: 'yours-heard', swatch: LegendSwatch(color: mc.snrStrong), title: 'Green: a ping here was heard', detail: 'The map is set to Heard, so a hexagon is green if any ping in it was heard.'),
        LegendRow(id: 'yours-silent', swatch: LegendSwatch(color: mc.silent, silentCell: true), title: 'Grey: nothing heard here'),
      ] else ...[
        LegendRow(id: 'yours-strong', swatch: LegendSwatch(color: mc.forPing(heard: true, snr: 10)), title: 'Strong, +10 dB or better', detail: 'Coloured by the best SNR of any ping in the hexagon, on the same scale as the pings.'),
        LegendRow(id: 'yours-weak', swatch: LegendSwatch(color: mc.forPing(heard: true, snr: -10)), title: 'Weak, -10 dB or worse'),
        LegendRow(id: 'yours-silent', swatch: LegendSwatch(color: mc.silent, silentCell: true), title: 'Grey: nothing heard here'),
      ],
    ];
  }

  List<Widget> _repeaters(BuildContext context, MeshSonarColors mc) {
    final t = Theme.of(context);
    final states = repeaterFreshnessKey(context, hours: true);
    const details = ['Advertised in the last 24 hours. Region repeaters: active or new.', 'Advertised in the last 7 days. Region repeaters: quiet.', 'Older than 7 days, or never advertised. Region repeaters: stale.'];
    const titles = ['Solid badge: fresh', 'Tinted badge with a ring: recent', 'Hollow dashed badge: older'];
    return [
      _note(context, 'A repeater is a tower badge with a white ring. Its colour is how recently it advertised, not its signal: blue and amber here are not the signal colours.', key: const Key('legend-repeater-note')),
      for (var i = 0; i < states.length; i++)
        LegendRow(id: 'repeater-${const ['fresh', 'recent', 'older'][i]}', swatch: states[i].swatch, title: titles[i], detail: details[i]),
      LegendRow(
        id: 'repeater-heard',
        swatch: ExcludeSemantics(child: Icon(Icons.check_circle, size: 22, color: mc.snrStrong)),
        title: 'Green tick: heard this drive',
        detail: 'A repeater your pings reached, with its name when known.',
      ),
      Text('A square badge is a room server.', style: t.textTheme.bodySmall),
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
        swatch: ExcludeSemantics(child: _Triangle(color: t.colorScheme.primary, filled: true, halo: t.colorScheme.surface)),
        title: 'Filled triangle: observer online',
        detail: 'A listening station that shares its position and is reporting now.',
      ),
      LegendRow(
        id: 'observer-offline',
        swatch: ExcludeSemantics(child: _Triangle(color: mc.silent, filled: false, halo: t.colorScheme.surface)),
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
    _Why('What does No reply mean?', 'No reply (dark red in the standard colours) means someone pinged there and no repeater answered, which is useful because '
        'it marks a gap. It is different from no hexagon at all, which means nobody has tried.', 'grey'),
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

/// The observer marker as the map draws it: a filled triangle when online, an outline when offline.
class _Triangle extends StatelessWidget {
  final Color color, halo;
  final bool filled;
  const _Triangle({required this.color, required this.filled, required this.halo});
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(24, 22), painter: _TriPainter(color, filled, halo));
}

class _TriPainter extends CustomPainter {
  final Color color, halo;
  final bool filled;
  _TriPainter(this.color, this.filled, this.halo);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 2)
      ..lineTo(size.width - 2, size.height - 2)
      ..lineTo(2, size.height - 2)
      ..close();
    if (filled) canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..color = filled ? halo : color,
    );
  }

  @override
  bool shouldRepaint(_TriPainter o) => o.color != color || o.filled != filled || o.halo != halo;
}
