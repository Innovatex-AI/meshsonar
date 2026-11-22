// What the one Layers panel needs from a map (MAP slice 4, app half, build 74): any map can open the same sheet by handing it a
// [MapLayersModel]. The Drive map's `DriveMapModel` implements it (the full set: drive pings, filters, the timeline) and
// [PageLayersModel] serves a map that draws only the shared layers (the Plan map): its choices are remembered under its page id
// in [MapPrefs] and every layer it cannot draw reads as unavailable with a one-line reason (shown disabled, never hidden).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/app_state.dart';
import '../../../core/coverage_query.dart';
import '../../../core/map_filter.dart';
import '../../../core/map_prefs.dart';
import '../../../core/map_styles.dart';
import '../../../core/repeater_sync.dart' show SyncTrigger;
import '../active_map_definition.dart';
import '../map_layers.dart' show PingColorMode, pingColorModeOf;
import 'map_layer.dart';
import 'registry.dart';
import 'repeater_map_source.dart';

/// The members the Layers sheet (and its key rows, the Filters section and the credits row) read from a map.
abstract class MapLayersModel implements Listenable {
  /// The page-config id the choices are remembered under (`drive`, `plan`).
  String get pageId;
  AppState get state;

  MapLayerState get layerState;
  void setLayer(String id, bool on);

  /// "Reset layers": the layers (and, on the Drive map, the ping colours and coverage options) back to the defaults.
  void resetLayers();

  /// The switch state and the line under it for registry layer [id].
  LayerStatus statusOf(String id);
  Future<void> retry(String id);

  RepeaterMapSource get repeaterSource;
  RepeaterMapFeed get repeaterFeed;

  /// Where this phone is, null when unknown.
  LatLng? get position;

  bool get coverageV2;

  /// The Filters section's values (the Drive map's filter drawer and coverage window / source); none on a map without them.
  MapFilter get filter;
  CoverageQuery get coverageQuery;

  PingColorMode get pingColors;
  set pingColors(PingColorMode m);

  BaseMapStyle get baseStyle;
  List<BaseMapStyle> get availableBaseStyles;
  void setBaseStyle(BaseMapStyle v);
}

/// Serves a map that draws the shared layers only (the Plan map): its remembered layer choices live in [MapPrefs] under [pageId],
/// the repeater lists come from the host's [repeaterSource], and everything this map does not draw is unavailable with its reason.
class PageLayersModel extends ChangeNotifier implements MapLayersModel {
  PageLayersModel({
    required this.pageId,
    required this.state,
    required this.repeaterSource,
    required this.repeaterFeed,
    this.mapName = 'this map',
    this.alwaysOn = const {},
    this.drawn = kPageDrawnLayerIds,
    this.defaults,
    MapPrefs? prefs,
  }) : _prefs = prefs ?? MapPrefs.shared {
    _prefs.addListener(notifyListeners);
    state.addListener(notifyListeners);
    ActiveMapDefinition.notifier.addListener(notifyListeners);
  }

  @override
  final String pageId;
  @override
  final AppState state;
  @override
  final RepeaterMapSource repeaterSource;
  @override
  final RepeaterMapFeed repeaterFeed;
  final MapPrefs _prefs;

  /// "the Plan map": the words in the reason of a layer this map does not draw.
  final String mapName;

  /// Layers that are on whatever was remembered (the Plan map's `plan` layer) and never written to the prefs.
  final Set<String> alwaysOn;

  /// The registry layers this map draws.
  final Set<String> drawn;

  /// What the page starts with before the person chooses anything (a page preset of the definition); null = the registry defaults.
  /// Read each time, so a definition that arrives later is followed.
  final MapLayerState Function()? defaults;

  @override
  void dispose() {
    _prefs.removeListener(notifyListeners);
    state.removeListener(notifyListeners);
    ActiveMapDefinition.notifier.removeListener(notifyListeners);
    super.dispose();
  }

  LayerPrefs get _lp => _prefs.layerPrefs(pageId);

  @override
  MapLayerState get layerState {
    var s = layerStateFromPrefs(_lp, defaults: defaults?.call());
    for (final id in alwaysOn) {
      s = s.toggle(id, true);
    }
    return s;
  }

  @override
  void setLayer(String id, bool on) {
    final was = layerState;
    final n = was.toggle(id, on);
    if (n == was) return;
    final toggles = {..._lp.toggles};
    for (final l in kMapLayerIds) {
      if (alwaysOn.contains(l)) continue;
      if (n.isOn(l) != was.isOn(l)) toggles[l] = n.isOn(l);
    }
    repeaterSource.dedupeAgainstRoster = n.isOn(kRosterLayerId);
    if (on && (id == kRosterLayerId || id == kNetworkLayerId)) repeaterSource.refreshAges();
    _prefs.setLayerPrefs(pageId, _lp.copyWith(toggles: toggles));
  }

  @override
  void resetLayers() {
    _prefs.setLayerPrefs(pageId, LayerPrefs.empty);
    repeaterSource.dedupeAgainstRoster = layerState.isOn(kRosterLayerId);
  }

  @override
  LayerStatus statusOf(String id) {
    if (!drawn.contains(id)) {
      final own = id == 'hexes' || id == 'pings' || id == 'heard';
      return LayerStatus(LayerAvailability.unsupported, detail: own ? 'Your drive is shown on the Drive map.' : 'Not drawn on $mapName.');
    }
    switch (id) {
      case 'measured':
        // The Plan map draws measured coverage from the server's tiles only.
        return coverageV2
            ? const LayerStatus(LayerAvailability.ready)
            : const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet');
      case 'predicted':
      case kHeardCellsLayerId:
        return layerStatus(id, MapLayerInputs(coverageV2: coverageV2, coverageHeard: state.coverageHeard, tilesOffline: coverageV2 && state.coverageTiles.offline), repeaters: repeaterSource);
      case kNetworkLayerId:
      case kRosterLayerId:
        return repeaterSource.statusOf(id);
      default:
        return const LayerStatus(LayerAvailability.ready);
    }
  }

  @override
  Future<void> retry(String id) async {
    switch (id) {
      case 'predicted':
      case kHeardCellsLayerId:
        if (coverageV2) {
          state.coverageTiles.networkFailures = 0;
          notifyListeners();
          unawaited(state.refreshCoverageMeta());
        }
      case kRosterLayerId:
      case kNetworkLayerId:
        await state.syncRepeaterLists(SyncTrigger.force);
    }
  }

  @override
  LatLng? get position {
    final f = state.phoneFix;
    return f == null ? null : LatLng(f.fix.lat, f.fix.lon);
  }

  @override
  bool get coverageV2 => state.coverageV2;

  @override
  MapFilter get filter => MapFilter.none;
  @override
  CoverageQuery get coverageQuery => const CoverageQuery();

  @override
  PingColorMode get pingColors => pingColorModeOf(layerState);
  @override
  set pingColors(PingColorMode m) {
    final modes = {..._lp.modes, 'pings': m == PingColorMode.result ? 'result' : 'snr'};
    _prefs.setLayerPrefs(pageId, _lp.copyWith(modes: modes));
  }

  @override
  BaseMapStyle get baseStyle => BaseMapStyle.effective(BaseMapStyle.parse(state.settings.baseMapStyle), ActiveMapDefinition.current);
  @override
  List<BaseMapStyle> get availableBaseStyles => BaseMapStyle.availableFor(ActiveMapDefinition.current);
  @override
  void setBaseStyle(BaseMapStyle v) {
    if (v == baseStyle || !availableBaseStyles.contains(v)) return;
    unawaited(state.updateSettings(state.settings.copyWith(baseMapStyle: v.id)));
  }
}

/// What the Plan map draws of the shared layers: the server's coverage tiles (measured, predicted, heard by phones), the repeater
/// lists with their names. Everything else reads as unavailable there.
const Set<String> kPageDrawnLayerIds = {'measured', 'predicted', kHeardCellsLayerId, kRosterLayerId, kNetworkLayerId, kLabelsLayerId};
