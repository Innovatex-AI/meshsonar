// LayerPrefs (Drive plan 7.2, fix F11): the layer choices survive a relaunch through the map_prefs.json store.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_prefs.dart';

void main() {
  test('LayerPrefs JSON round trip, sorted and compact; empty writes nothing', () {
    const p = LayerPrefs(toggles: {'rings': false, 'network': true}, modes: {'pings': 'result'}, colorBy: 'noise', res: 9, since: 'week', source: 'meshsonar');
    expect(LayerPrefs.fromJson(jsonDecode(jsonEncode(p.toJson()))), p);
    expect(p.toJson().keys, ['on', 'mode', 'color_by', 'res', 'since', 'source']);
    expect(LayerPrefs.empty.toJson(), isEmpty);
    expect(LayerPrefs.empty.isEmpty, isTrue);
  });

  test('a damaged or future file leaves defaults: wrong shapes and out-of-range detail are ignored', () {
    expect(LayerPrefs.fromJson('x'), LayerPrefs.empty);
    expect(LayerPrefs.fromJson({'on': {'rings': 'yes', 'pings': true}, 'res': 12, 'color_by': 3}).toggles, {'pings': true});
    expect(LayerPrefs.fromJson({'res': 12}).res, isNull);
    expect(LayerPrefs.fromJson({'res': 7}).res, 7);
  });

  test('MapPrefs: set, "relaunch" (a new instance reading the same file), same choices; pages are independent; reset forgets', () async {
    String? file;
    MapPrefs open() => MapPrefs(read: () async => file, write: (s) async => file = s);

    final a = open();
    await a.load();
    expect(a.layerPrefs(kDriveLayerPage), LayerPrefs.empty);
    a.setLayerPrefs(kDriveLayerPage, const LayerPrefs(toggles: {'measured': false}, modes: {'pings': 'result'}, res: 10));
    a.setLayerPrefs('analyze', const LayerPrefs(toggles: {'rings': false}));
    a.headingUp = true; // the other keys of the same file are untouched by layers
    await Future<void>.delayed(Duration.zero);

    final b = open();
    await b.load();
    expect(b.layerPrefs(kDriveLayerPage), const LayerPrefs(toggles: {'measured': false}, modes: {'pings': 'result'}, res: 10));
    expect(b.layerPrefs('analyze').toggles, {'rings': false});
    expect(b.headingUp, isTrue);

    b.setLayerPrefs(kDriveLayerPage, LayerPrefs.empty);
    await Future<void>.delayed(Duration.zero);
    final c = open();
    await c.load();
    expect(c.layerPrefs(kDriveLayerPage), LayerPrefs.empty);
    expect(c.layerPrefs('analyze').toggles, {'rings': false});
    expect(jsonDecode(file!)['layers'].containsKey(kDriveLayerPage), isFalse);
  });

  test('an old file with no layers key loads fine', () async {
    final p = MapPrefs(read: () async => '{"heading_up":true}', write: (_) async {});
    await p.load();
    expect(p.headingUp, isTrue);
    expect(p.layerPrefs(kDriveLayerPage), LayerPrefs.empty);
  });
}
