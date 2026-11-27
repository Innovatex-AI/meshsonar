// AttributionLine (Drive plan section 8, R04, D13; build 77 Round 1 decision 5): the map credit as one always-visible pill in the
// bottom-RIGHT corner, "© OpenStreetMap (i)", with the (i) opening the Credits sheet (which names Protomaps or OpenFreeMap, who
// draw the map, and the source drawn right now). It never collapses to the bare (i) and a MapPageConfig cannot turn it off: the
// OSM Attribution Guidelines say the credit should be visible without interaction, and an (i) alone is not compliant. It sits at
// ONE fixed spot just above the panel's resting height (MapOverlayHost.attributionClearance): a panel pulled up covers it, as
// Apple's maps do. On Satellite the pill carries the longer imagery credit (Esri, USGS NAIP) the definition requires.
//
// Keys: 'map-attribution' (the whole line), 'map-attribution-text', 'map-attribution-info' (the (i) button),
// 'map-attribution-meshcore' (the optional second line).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/map_styles.dart';
import '../../design/map_tokens.dart';

/// The default text of the credit line for [style]. Chart, Light and Dark are our Protomaps tiles (the map passes the
/// OpenFreeMap credit while the fallback draws, Satellite the imagery credits).
String attributionText(BaseMapStyle style) => style.attribution;

class AttributionLine extends StatelessWidget {
  final BaseMapStyle style;

  /// Shown as a second, muted line while the MeshCore Map layer is drawing ("MeshCore Map").
  final bool showMeshCore;

  /// Opens the Credits sheet.
  final VoidCallback? onInfo;

  /// The credit of the source drawn right now; null = [attributionText].
  final String? text;
  const AttributionLine({super.key, required this.style, this.showMeshCore = false, this.onInfo, this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Build 77 (decision 5): one small pill on every base map, dark on a dark map and light on a light one (Road follows the
    // app theme, Light is always light, Dark and Satellite always dark), so the 11 pt credit reads on any map.
    final darkMap = style.isDark(appDark: t.brightness == Brightness.dark);
    final ink = MapTokens.creditInk(darkMap: darkMap);
    TextStyle base(Color c) => (t.textTheme.labelSmall ?? const TextStyle()).copyWith(fontSize: 11, height: 1.25, color: c);
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
          Text('MeshCore Map', key: const Key('map-attribution-meshcore'), textAlign: TextAlign.end, style: base(ink.withValues(alpha: 0.75))),
      ],
    );
    // The line is 22 pt tall; the (i) is hit from 11 pt around it (44 x 44), which only works at the root: every ancestor
    // checks its own bounds before it lets a tap through.
    return HitSlop(
      slop: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      child: Semantics(
      container: true,
      child: Container(
        key: const Key('map-attribution'),
        // No padding on the right or vertically: the (i) must sit on the pill's own edge so the hit slop reaches it.
        padding: const EdgeInsets.only(left: 7),
        decoration: BoxDecoration(color: MapTokens.creditPill(darkMap: darkMap), borderRadius: BorderRadius.circular(11)),
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
