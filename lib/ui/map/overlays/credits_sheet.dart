// The Credits sheet behind the attribution line's (i) (Drive plan section 8). Minimal in WP2: the full licence text and links,
// OpenTopoMap and SRTM when Topo is the base, MeshCore Map when its layer is on, where the base map is coming from right now
// (this replaces the old on-map source chip), the colour key (moved off the map), and a way into the legend.
//
// Keys: 'credits-sheet', 'credits-osm', 'credits-topo', 'credits-meshcore', 'credits-source', 'credits-key', 'credits-legend'.
import 'package:flutter/material.dart';

import '../../../core/map_styles.dart';
import '../../../platform/open_url.dart';
import '../../design/app_surfaces.dart' show showAppSheet;
import '../../theme.dart';

/// Opens the sheet. [sourceState] is the live "Online map / Offline map: CMH / Saved map / No map here" line; [colourKey] is
/// the map key widget; [meshCoreCredit] is the layer's attribution text when its data is on the map.
Future<void> showMapCredits(
  BuildContext context, {
  required BaseMapStyle style,
  Widget? sourceState,
  Widget? colourKey,
  String? meshCoreCredit,
  VoidCallback? openLegend,
}) {
  return showAppSheet<void>(
    context,
    detents: const [0.45, 0.8],
    builder: (ctx, controller) => CreditsSheet(
      controller: controller,
      style: style,
      sourceState: sourceState,
      colourKey: colourKey,
      meshCoreCredit: meshCoreCredit,
      openLegend: openLegend,
    ),
  );
}

class CreditsSheet extends StatelessWidget {
  final ScrollController? controller;
  final BaseMapStyle style;
  final Widget? sourceState;
  final Widget? colourKey;
  final String? meshCoreCredit;
  final VoidCallback? openLegend;
  const CreditsSheet({super.key, this.controller, required this.style, this.sourceState, this.colourKey, this.meshCoreCredit, this.openLegend});

  static final Uri _osmCopyright = Uri.parse('https://www.openstreetmap.org/copyright');
  static final Uri _odbl = Uri.parse('https://opendatacommons.org/licenses/odbl/1-0/');
  static final Uri _topo = Uri.parse('https://opentopomap.org');
  static final Uri _ccBySa = Uri.parse('https://creativecommons.org/licenses/by-sa/3.0/');
  static final Uri _meshcore = Uri.parse('https://map.meshcore.io');
  static final Uri _protomaps = Uri.parse('https://protomaps.com');
  static final Uri _openfreemap = Uri.parse('https://openfreemap.org');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    Widget head(String s) => Padding(padding: const EdgeInsets.only(top: 16, bottom: 4), child: Text(s, style: t.textTheme.titleSmall));
    Widget link(String label, Uri u) => TextButton(
      onPressed: () => openExternalUrl(u),
      style: TextButton.styleFrom(alignment: Alignment.centerLeft, minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
      child: Text(label),
    );
    return SingleChildScrollView(
      key: const Key('credits-sheet'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Map credits', style: t.textTheme.titleLarge),
        if (sourceState != null) ...[head('Base map right now'), Align(alignment: Alignment.centerLeft, key: const Key('credits-source'), child: sourceState!)],
        head('Map data'),
        Column(
          key: const Key('credits-osm'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('© OpenStreetMap contributors. The map data is available under the Open Database Licence (ODbL).', style: t.textTheme.bodyMedium),
            link('openstreetmap.org/copyright', _osmCopyright),
            link('Open Database Licence (ODbL)', _odbl),
          ],
        ),
        if (style == BaseMapStyle.topo) ...[
          head('Terrain map'),
          Column(
            key: const Key('credits-topo'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Map data: © OpenStreetMap contributors, SRTM. Map style: © OpenTopoMap (CC-BY-SA).', style: t.textTheme.bodyMedium),
              link('opentopomap.org', _topo),
              link('Creative Commons BY-SA 3.0', _ccBySa),
            ],
          ),
        ],
        if (meshCoreCredit != null) ...[
          head('Repeater data'),
          Column(
            key: const Key('credits-meshcore'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Repeater positions on the global layer: $meshCoreCredit (map.meshcore.io).', style: t.textTheme.bodyMedium),
              link('map.meshcore.io', _meshcore),
            ],
          ),
        ],
        head('Base map'),
        Text(
          'Road and dark maps: MeshSonar\'s own vector tiles built by Protomaps from OpenStreetMap data. When they cannot be '
          'reached, or outside North America, the map comes from OpenFreeMap (also OpenStreetMap data). The credit line '
          'on the map names the one you are looking at.',
          key: const Key('credits-basemap'),
          style: t.textTheme.bodyMedium,
        ),
        link('protomaps.com', _protomaps),
        link('openfreemap.org', _openfreemap),
        head('Offline maps'),
        Text('Offline region maps are the same Protomaps map, served by MeshSonar, with the same credit.', style: t.textTheme.bodyMedium?.copyWith(color: mc.textMuted)),
        if (colourKey != null) ...[head('What the colours mean'), KeyedSubtree(key: const Key('credits-key'), child: colourKey!)],
        if (openLegend != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton.icon(
              key: const Key('credits-legend'),
              onPressed: openLegend,
              icon: const Icon(Icons.help_outline_rounded),
              label: const Text('What do the colours mean?'),
            ),
          ),
      ],
    ));
  }
}
