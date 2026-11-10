// Starts the Map Definition cache at launch (core/map_definition.dart): bundled copy from the assets, last good copy in the
// app support folder, a refresh when stale against the configured MeshSonar server. Rendering from it is the M2 phase proper.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/map_definition.dart';

Future<MapDefinitionStore?> startMapDefinition(Uri server) async {
  try {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final store = MapDefinitionStore(
      root: Directory(p.join(base.path, 'meshsonar', 'map_definition')),
      origin: server,
      loadBundled: () => rootBundle.loadString(mapDefinitionAsset),
    );
    MapDefinitionStore.instance = store;
    unawaited(store.refreshIfStale());
    return store;
  } catch (_) {
    return null; // the map works without it until the M2 renderer reads it
  }
}
