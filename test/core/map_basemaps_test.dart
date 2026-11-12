// M3-1 (Topo + Satellite): what the Map Definition says about the basemaps, and when the app offers them. An older cached definition
// (no `schemaMinor`, no `capabilities`, no topo / satellite entries) must keep working and offer only Chart, Light and Dark.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_basemaps.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_styles.dart';

final _body = File('assets/map/map-definition.json').readAsStringSync();

/// The bundled definition, edited by [edit], as a parsed definition.
MapDefinition _def(void Function(Map<String, dynamic> j) edit) {
  final j = jsonDecode(_body) as Map<String, dynamic>;
  edit(j);
  return MapDefinition.parse(jsonEncode(j));
}

/// What an app saw before M3: no new keys, no topo / satellite basemaps, none of the new layers.
MapDefinition _old() => _def((j) {
  j
    ..remove('schemaMinor')
    ..remove('capabilities');
  j['basemaps'] = [for (final b in j['basemaps'] as List) if (const {'road', 'relief', 'plain'}.contains((b as Map)['id'])) b];
  j['layers'] = [for (final l in j['layers'] as List) if (!const {'redundancy', 'snrlinks', 'estimated'}.contains((l as Map)['id'])) l];
});

void main() {
  group('the M3 fixture', () {
    test('parses; schemaMinor 1; the five capabilities; Topo and Satellite are offered', () {
      final d = MapDefinition.parse(_body);
      expect(d.v, 1);
      expect(d.schemaMinor, 1);
      expect(d.capabilities, {capBasemapTopo, capBasemapSatellite, capLayerEstimated, capLayerRedundancy, capLayerSnrLinks});
      expect(d.offersTopo, isTrue);
      expect(d.offersSatellite, isTrue);
      expect(BaseMapStyle.availableFor(d), [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark, BaseMapStyle.topo, BaseMapStyle.satellite]);
    });

    test('satellite sources: Esri through our proxy then NAIP; NAIP is drawn up to z17 inside the contiguous US', () {
      final sat = MapDefinition.parse(_body).satellite!;
      expect(sat.esriAvailable, isTrue);
      expect(sat.usable.map((s) => s.id), ['esri', 'naip']);
      final esri = sat.usable[0], naip = sat.usable[1];
      expect(esri.tiles, 'https://meshsonar.com/api/map/satellite/esri/{z}/{y}/{x}', reason: 'the absolute server proxy URL, never an Esri URL with a key');
      expect(esri.maxZoom, 18);
      expect(esri.layerMaxZoom, isNull);
      expect(naip.maxZoom, 16);
      expect(naip.layerMaxZoom, 17);
      expect(naip.bounds, [-125, 24.4, -66.9, 49.5]);
      expect(sat.labels, isTrue);
      expect(sat.credits, ['Powered by Esri. Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community', 'Imagery: USGS National Map (NAIP)']);
      expect(sat.coverageNote, contains('Esri'));
    });

    test('no key on the server (esriAvailable false): Esri is left out and its credit with it; NAIP alone still offers Satellite', () {
      final d = _def((j) {
        final b = (j['basemaps'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['id'] == 'satellite');
        (b['satellite'] as Map<String, dynamic>)['esriAvailable'] = false;
      });
      final sat = d.satellite!;
      expect(sat.usable.map((s) => s.id), ['naip']);
      expect(sat.credits, ['Imagery: USGS National Map (NAIP)']);
      expect(sat.coverageNote, contains('Outside the US there is no satellite imagery'));
      expect(d.offersSatellite, isTrue);
    });

    test('Topo carries the palette overrides for both themes (what tool/basemap/make_basemap_styles.mjs bakes)', () {
      final topo = MapDefinition.parse(_body).basemap('topo')!['topo'] as Map;
      expect((topo['base'] as Map).keys, containsAll(['light', 'dark']));
      expect(((topo['overrides'] as Map)['light'] as Map)['water'], '#A9D0E5');
      expect(topo['contours'], isNull, reason: 'no contour tile source exists');
    });
  });

  group('an older definition (before M3)', () {
    test('parses, has schemaMinor 0 and no capabilities, and offers only Chart / Light / Dark', () {
      final d = _old();
      expect(d.schemaMinor, 0);
      expect(d.capabilities, isEmpty);
      expect(d.hasCapability(capBasemapTopo), isFalse);
      expect(d.offersTopo, isFalse);
      expect(d.offersSatellite, isFalse);
      expect(d.satellite, isNull);
      expect(BaseMapStyle.availableFor(d), [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]);
    });

    test('a saved Topo or Satellite choice is Chart while the definition does not offer it', () {
      final old = _old(), fresh = MapDefinition.parse(_body);
      expect(BaseMapStyle.effective(BaseMapStyle.topo, old), BaseMapStyle.chart);
      expect(BaseMapStyle.effective(BaseMapStyle.satellite, old), BaseMapStyle.chart);
      expect(BaseMapStyle.effective(BaseMapStyle.dark, old), BaseMapStyle.dark);
      expect(BaseMapStyle.effective(BaseMapStyle.satellite, fresh), BaseMapStyle.satellite);
    });
  });

  group('capability gating', () {
    test('the capability string AND the basemap entry are both needed', () {
      final noCap = _def((j) => (j['capabilities'] as List).remove(capBasemapTopo));
      expect(noCap.hasTopo, isTrue);
      expect(noCap.offersTopo, isFalse, reason: 'a client checks the capability string before it relies on a feature');
      final noEntry = _def((j) => (j['basemaps'] as List).removeWhere((b) => (b as Map)['id'] == 'topo'));
      expect(noEntry.offersTopo, isFalse);
      final noSatCap = _def((j) => (j['capabilities'] as List).remove(capBasemapSatellite));
      expect(noSatCap.offersSatellite, isFalse);
      expect(BaseMapStyle.availableFor(noSatCap), isNot(contains(BaseMapStyle.satellite)));
    });

    test('a satellite entry the app cannot read (no sources, a source without tiles) is not offered, and never throws', () {
      final none = _def((j) {
        final b = (j['basemaps'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['id'] == 'satellite');
        (b['satellite'] as Map<String, dynamic>)['sources'] = <Object>[];
      });
      expect(none.offersSatellite, isFalse);
      final broken = _def((j) {
        final b = (j['basemaps'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['id'] == 'satellite');
        (b['satellite'] as Map<String, dynamic>)['sources'] = [<String, Object>{'id': 'esri'}];
      });
      expect(broken.satellite, isNull);
      expect(broken.offersSatellite, isFalse);
    });

    test('the cycler skips what is not offered and wraps', () {
      final a = BaseMapStyle.availableFor(_old());
      expect(BaseMapStyle.dark.nextAvailable(a), BaseMapStyle.chart, reason: 'Topo and Satellite are not in the cycle');
      final b = BaseMapStyle.availableFor(MapDefinition.parse(_body));
      expect(BaseMapStyle.dark.nextAvailable(b), BaseMapStyle.topo);
      expect(BaseMapStyle.satellite.nextAvailable(b), BaseMapStyle.chart);
    });
  });

  test('the legend entry parser reads the new Redundancy `step` kind', () {
    final l = MapDefinition.parse(_body).layerDef('redundancy')!;
    expect(l.legend.map((e) => e.kind), everyElement('step'));
    expect(l.legend.map((e) => e.step), [1, 2, 3, 4]);
    expect(l.legend.first.label, '1 repeater: a single point of failure');
    expect(l.defaultOn, isFalse);
    expect(l.hidesWithTime, isTrue);
    expect(MapDefinition.parse(_body).layerDef('estimated')!.defaultOn, isTrue);
  });
}
