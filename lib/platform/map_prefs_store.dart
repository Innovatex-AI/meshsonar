// Where the map preferences live: `<app support>/meshsonar/map_prefs.json`. Opened lazily; any failure (no plugin in a test,
// read-only disk) just leaves the defaults.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/map_prefs.dart';

/// Wires [MapPrefs.shared] to its file and loads it. Safe to call more than once.
Future<MapPrefs> openSharedMapPrefs() async {
  final prefs = MapPrefs.shared;
  if (prefs.read != null) return prefs;
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'meshsonar'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, 'map_prefs.json'));
    prefs.read = () async => await f.exists() ? await f.readAsString() : null;
    prefs.write = (s) async => f.writeAsString(s, flush: true);
    await prefs.load();
  } catch (_) {
    // defaults for this session
  }
  return prefs;
}
