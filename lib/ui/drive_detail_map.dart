// Map for the drive detail screen: the shared CoverageMap framed on the whole drive (no live position). With coverage v2 the
// drive's cells are res-11 cells with the mean SNR in the coverage bands, and a tap opens the server's cell inspector.
//
// MAP slice 6 (app half, build 74): under the map the drive key (ui/map/tools/drive_key.dart), the reader's saved basemap, the
// Map Definition's `drive-detail` page preset for the layers, the privacy zones from `symbols.tools.zone` and the part of the drive
// a zone hides drawn faded and dashed from `symbols.tools.hiddenTrack`. A definition without `pages` / `symbols.tools` (the bundled
// copy) leaves every one of those on what build 73 drew: the default layers, the Chart basemap choice as before, no zone, no
// hidden line (the key still names the ping colours). No Layers button: legend and basemap only.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../core/map_definition.dart';
import '../core/map_definition_pages.dart';
import '../core/map_styles.dart';
import '../core/map_tool_style.dart';
import '../core/model.dart';
import '../core/privacy_zones.dart';
import 'app.dart';
import 'map/active_map_definition.dart';
import 'map/coverage_map.dart';
import 'map/layers/map_layer.dart';
import 'map/layers/registry.dart' show appLayerId, defaultLayerState, definitionLayerId, kMapLayers;
import 'map/layers/repeater_map_source.dart' show kLabelsLayerId;
import 'map/region_center.dart';
import 'map/tools/drive_key.dart';
import 'map/tools/hidden_track_layer.dart';
import 'map/tools/zone_layer.dart';

/// The layers the definition's `drive-detail` preset turns on, as the app's layer state: a definition layer is on exactly when the
/// preset lists it; the app's own extras (ping dots, heard repeaters, friends) keep their defaults; Names follow the preset's
/// `names`. Null when the definition has no such preset (the caller keeps build 73's layers).
MapLayerState? driveDetailLayerState(MapDefinition def, {String page = 'drive-detail'}) {
  final p = def.pagePreset(page);
  if (p == null) return null;
  final base = defaultLayerState(def);
  final on = <String>{
    for (final l in kMapLayers)
      if (definitionLayerId(l.id) == null ? base.isOn(l.id) : p.layers.any((d) => appLayerId(d) == l.id)) l.id,
  };
  if (p.names != null) p.names! ? on.add(kLabelsLayerId) : on.remove(kLabelsLayerId);
  return MapLayerState(on: Set.unmodifiable(on), mode: base.mode);
}

class DriveDetailMap extends StatelessWidget {
  final List<DrivePing> pings;

  /// Draw the phone's privacy zones and the part of the drive they hide (the drive on this phone). The server's copy of a drive
  /// holds none of the hidden part, so the server drive screen turns this off.
  final bool showZones;
  const DriveDetailMap({super.key, required this.pings, this.showZones = true});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ValueListenableBuilder<MapDefinition>(
      valueListenable: ActiveMapDefinition.notifier,
      builder: (context, def, _) {
        final tool = MapToolStyle.of(def);
        final zones = showZones && tool != null ? s.privacyZones.zones : const <PrivacyZone>[];
        final List<List<LatLng>> runs = zones.isEmpty ? const [] : hiddenRuns(pings, PrivacyZones(zones));
        return CoverageMap(
          pings: pings,
          repeaters: s.repeaters,
          repeaterLabel: s.repeaterLabel,
          follow: false,
          fitToPings: true,
          showLinks: false,
          fallbackCenter: viewedRegionCenter(s),
          baseStyle: BaseMapStyle.effective(BaseMapStyle.parse(s.settings.baseMapStyle), def),
          layerState: driveDetailLayerState(def),
          legend: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 300), child: DriveKey(hiddenPart: runs.isNotEmpty, zones: zones.length, definition: def)),
          ),
          extraLayers: [
            if (zones.isNotEmpty) ZoneLayer(zones: zones, definition: def),
            if (runs.isNotEmpty) HiddenTrackLayer(runs: runs, definition: def),
          ],
          coverageV2: s.coverageV2 ? CoverageV2Inputs(tiles: s.coverageTiles, meta: s.coverageMeta, drawTiles: false, fetchCell: s.coverageCell) : null,
        );
      },
    );
  }
}
