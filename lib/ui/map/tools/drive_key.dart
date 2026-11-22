// The key on a drive's track map (MAP slice 6, app half; the twin of the website's components/map/drive-key.tsx): ONE key for the
// drive detail, the server drive and the privacy zones. A ping a repeater answered is a disc in its SNR band (the five bands of the
// cells, the active palette, read from the Map Definition through CoverageBandColors, never copied), a ping nobody answered is the
// No-reply disc, "outlined" says the drive's own cells carry an outline, the part the public does not see is a faded dashed line and
// a privacy zone is a dashed circle (the last two come from `symbols.tools` and appear only when the definition has it).
// Light and dark follow the theme. Keys: 'drive-key', 'drive-key-bands', 'drive-key-noreply', 'drive-key-outlined', 'drive-key-hidden',
// 'drive-key-zone'.
import 'package:flutter/material.dart';

import '../../../core/map_definition.dart';
import '../../../core/map_tool_style.dart';
import '../../theme.dart';
import '../active_map_definition.dart';
import '../coverage_bands.dart';
import 'zone_layer.dart' show dashedBorderPattern;

class DriveKey extends StatelessWidget {
  /// The ping discs (the bands and No reply).
  final bool dots;

  /// The faded dashed line of the part of a drive the public does not see.
  final bool hiddenPart;

  /// How many privacy zones the map shows (0 = no zone swatch; 1 = "Privacy zone", more = "Privacy zones").
  final int zones;

  /// "Outlined: this drive".
  final bool outlined;

  /// The definition to read; null = the active one.
  final MapDefinition? definition;
  const DriveKey({super.key, this.dots = true, this.hiddenPart = false, this.zones = 0, this.outlined = true, this.definition});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final def = definition ?? ActiveMapDefinition.current;
    final dark = t.brightness == Brightness.dark;
    final bands = CoverageBandColors.of(MeshSonarColors.of(context).palette, t.brightness, definition: def);
    final tool = MapToolStyle.of(def);
    final style = t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurface);
    Widget item(Key key, Widget swatch, String text) => Row(key: key, mainAxisSize: MainAxisSize.min, children: [
      swatch,
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: style)),
    ]);
    final items = <Widget>[
      if (dots)
        item(
          const Key('drive-key-bands'),
          ExcludeSemantics(child: Row(mainAxisSize: MainAxisSize.min, children: [for (var b = 1; b <= 5; b++) _Disc(bands[b], t.colorScheme.onSurface)])),
          'Ping a repeater answered: its colour is the SNR band, the same as the cells',
        ),
      if (dots) item(const Key('drive-key-noreply'), ExcludeSemantics(child: _Disc(bands.noReplyPoint, t.colorScheme.onSurface)), 'Ping nobody answered'),
      if (dots && outlined)
        item(
          const Key('drive-key-outlined'),
          ExcludeSemantics(child: _Disc(const Color(0x00000000), t.colorScheme.onSurface, ringOnly: true)),
          'Outlined: this drive',
        ),
      if (hiddenPart && tool != null)
        item(const Key('drive-key-hidden'), ExcludeSemantics(child: _DashSwatch(tool.hiddenTrack, dark)), tool.hiddenTrack.label),
      if (zones > 0 && tool != null)
        item(const Key('drive-key-zone'), ExcludeSemantics(child: _ZoneSwatch(tool.zone, dark)), zones == 1 ? tool.zone.label : '${tool.zone.label}s'),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Material(
      key: const Key('drive-key'),
      color: t.colorScheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(Corners.chip),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.xs + 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(height: 3), items[i]],
        ]),
      ),
    );
  }
}

/// A ping disc: filled in its band colour, with a thin ring so a pale band still reads on a light card.
class _Disc extends StatelessWidget {
  final Color fill, ring;
  final bool ringOnly;
  const _Disc(this.fill, this.ring, {this.ringOnly = false});
  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    margin: const EdgeInsets.only(right: 2),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: fill,
      border: Border.all(color: ring.withValues(alpha: ringOnly ? 0.9 : 0.35), width: ringOnly ? 1.6 : 0.8),
    ),
  );
}

class _DashSwatch extends StatelessWidget {
  final HiddenTrackToolStyle s;
  final bool dark;
  const _DashSwatch(this.s, this.dark);
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(28, 12),
    painter: _DashPainter(Color(s.colour.of(dark: dark)).withValues(alpha: s.opacity), s.widthPx, s.dash),
  );
}

class _DashPainter extends CustomPainter {
  final Color colour;
  final double width;
  final List<double>? dash;
  _DashPainter(this.colour, this.width, this.dash);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final pattern = dash == null ? null : dashedBorderPattern(dash!, width);
    final y = size.height / 2;
    if (pattern == null) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      return;
    }
    var x = 0.0, i = 0;
    while (x < size.width) {
      final len = pattern[i % pattern.length];
      if (i.isEven) canvas.drawLine(Offset(x, y), Offset((x + len).clamp(0, size.width), y), p);
      x += len;
      i++;
    }
  }

  @override
  bool shouldRepaint(_DashPainter o) => o.colour != colour || o.width != width || o.dash != dash;
}

class _ZoneSwatch extends StatelessWidget {
  final ZoneToolStyle s;
  final bool dark;
  const _ZoneSwatch(this.s, this.dark);
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(14, 14), painter: _ZonePainter(s, dark));
}

class _ZonePainter extends CustomPainter {
  final ZoneToolStyle s;
  final bool dark;
  _ZonePainter(this.s, this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 1;
    canvas.drawCircle(c, r, Paint()..color = Color(s.fill.of(dark: dark)).withValues(alpha: s.fillOpacity.normal));
    final w = s.edgeWidthPx.normal;
    final edge = Paint()
      ..color = Color(s.edge.of(dark: dark))
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    final pattern = s.dash == null ? null : dashedBorderPattern(s.dash!, w);
    if (pattern == null) {
      canvas.drawCircle(c, r, edge);
      return;
    }
    // Dashes along the circle: each dash and gap in px becomes an arc.
    final circ = 2 * 3.141592653589793 * r;
    var d = 0.0, i = 0;
    while (d < circ) {
      final len = pattern[i % pattern.length];
      if (i.isEven) canvas.drawArc(Rect.fromCircle(center: c, radius: r), d / r, (len.clamp(0, circ - d)) / r, false, edge);
      d += len;
      i++;
    }
  }

  @override
  bool shouldRepaint(_ZonePainter o) => o.s != s || o.dark != dark;
}
