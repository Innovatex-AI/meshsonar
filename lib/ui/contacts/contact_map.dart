// The little non-interactive map on a contact's detail screen. Injectable (ContactMapBuilder) so tests and offline use never
// depend on tile downloads.
import '../map/basemap_layer.dart' show BasemapLayer;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../design/app_symbols.dart';
import '../theme.dart';
import '../map/overlays/mini_map_credit.dart';

typedef ContactMapBuilder = Widget Function(BuildContext context, double lat, double lon);

Widget defaultContactMap(BuildContext context, double lat, double lon) {
  final m = MeshSonarColors.of(context);
  final at = LatLng(lat, lon);
  return ClipRRect(
    key: const Key('contact-map'),
    borderRadius: BorderRadius.circular(Corners.small),
    child: SizedBox(
      height: 180,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: at,
          initialZoom: 13,
          backgroundColor: m.mapBackground,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
        ),
        children: [
          const BasemapLayer(),
          MarkerLayer(markers: [Marker(point: at, width: 28, height: 28, child: AppSymbolIcon(AppSymbols.locationFill, color: m.beacon, size: 28, scaleWithText: false))]),
          const MiniMapCredit(),
        ],
      ),
    ),
  );
}
