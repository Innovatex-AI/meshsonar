// AttributionLine (Drive plan section 8, R04, D13): the map credit as one always-visible 12 pt line in the bottom-RIGHT corner
// with a trailing (i) that opens the Credits sheet. It never collapses to the bare (i) and a MapPageConfig cannot turn it off:
// the OSM Attribution Guidelines say the credit should appear in a corner of the map and not need interaction to see it, and
// an (i) alone is not compliant. On Topo the line also carries the OpenTopoMap credit (CC-BY-SA needs reasonable visibility).
//
// Keys: 'map-attribution' (the whole line), 'map-attribution-text', 'map-attribution-info' (the (i) button),
// 'map-attribution-meshcore' (the optional second line).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/map_styles.dart';
import '../../theme.dart';

/// The default text of the credit line for [style]. Chart, Light and Dark are our Protomaps tiles (the map passes the
/// OpenFreeMap credit while the fallback draws); Topo adds OpenTopoMap and SRTM.
String attributionText(BaseMapStyle style) => style.attribution;

class AttributionLine extends StatelessWidget {
  final BaseMapStyle style;

  /// Shown as a second, muted line while the MeshCore Map layer is drawing ("MeshCore Map").
  final bool showMeshCore;

  /// Opens the Credits sheet.
  final VoidCallback? onInfo;

  /// The credit of the source drawn right now (ours, OpenFreeMap or an offline pack); null = [attributionText].
  final String? text;
  const AttributionLine({super.key, required this.style, this.showMeshCore = false, this.onInfo, this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Topo is drawn as the tile server made it (busy) and Light stays light under a dark theme: a surface pill keeps the
    // 12 pt line legible on both.
    final pill = style == BaseMapStyle.street || style == BaseMapStyle.topo;
    final ink = t.colorScheme.onSurface;
    final halo = t.colorScheme.surface;
    TextStyle base(Color c) => (t.textTheme.labelSmall ?? const TextStyle()).copyWith(
      fontSize: 12,
      height: 1.25,
      color: c,
      shadows: pill
          ? null
          : [Shadow(color: halo, blurRadius: 2), Shadow(color: halo, blurRadius: 4), Shadow(color: halo.withValues(alpha: 0.9), offset: const Offset(0.5, 0.5), blurRadius: 1)],
    );
    final text = this.text ?? attributionText(style);
    final infoButton = GestureDetector(
        key: const Key('map-attribution-info'),
        behavior: HitTestBehavior.opaque,
        onTap: onInfo,
        child: Semantics(
          button: true,
          label: 'Map credits',
          excludeSemantics: true,
          onTap: onInfo,
          child: SizedBox(width: 24, height: 22, child: Center(child: Icon(Icons.info_outline_rounded, size: 16, color: ink))),
        ),
      );
    final line = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(child: Text(text, key: const Key('map-attribution-text'), textAlign: TextAlign.end, style: base(ink))),
        const SizedBox(width: 2),
        infoButton,
      ],
    );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        line,
        if (showMeshCore)
          Text('MeshCore Map', key: const Key('map-attribution-meshcore'), textAlign: TextAlign.end, style: base(MeshSonarColors.of(context).textMuted)),
      ],
    );
    // The line is 18 pt tall; the (i) is hit from 13 pt around it (44 x 44), which only works at the root: every ancestor
    // checks its own bounds before it lets a tap through.
    return HitSlop(
      slop: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      child: Semantics(
      container: true,
      child: Container(
        key: const Key('map-attribution'),
        // No padding on the right or vertically: the (i) must sit on the line's own edge so the hit slop reaches it.
        padding: pill ? const EdgeInsets.only(left: 6) : EdgeInsets.zero,
        decoration: pill ? BoxDecoration(color: t.colorScheme.surface.withValues(alpha: 0.88), borderRadius: BorderRadius.circular(6)) : null,
        child: body,
      ),
    ));
  }
}

/// Lets a small widget be tapped from [slop] beyond its box (the (i) is 18 pt drawn, 44 x 44 to hit).
class HitSlop extends SingleChildRenderObjectWidget {
  final EdgeInsets slop;
  const HitSlop({super.key, required this.slop, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHitSlop(slop);
  @override
  void updateRenderObject(BuildContext context, covariant RenderProxyBox renderObject) => (renderObject as _RenderHitSlop).slop = slop;
}

class _RenderHitSlop extends RenderProxyBox {
  _RenderHitSlop(this.slop);
  EdgeInsets slop;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!slop.inflateRect(Offset.zero & size).contains(position)) return false;
    final inside = Offset(position.dx.clamp(0.0, size.width - 0.01), position.dy.clamp(0.0, size.height - 0.01));
    return super.hitTest(result, position: inside);
  }
}
