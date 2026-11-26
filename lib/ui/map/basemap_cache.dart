// The one-time removal of the basemap renders older builds left on disk.
//
// vector_map_tiles stores the PNG it rendered for each tile on disk (`<tmp>/.vector_map`, 30 days, 50 MB), named by the
// theme's id and version: `<id>-v<version>-<z>-<x>-<y>.png`. Builds 57 to 71 shipped seven styles with no id, so all of them
// wrote and read the same files (`default-vnone-<z>-<x>-<y>.png`): a tile rendered once as Dark was served as Light, Topo and
// the rest, and Satellite's names-only tiles were served as the whole map. Since build 72 every style has its own identity
// (core/basemap.dart, basemapRenderVersion), so those files are never read again; [purgeOldOnce] deletes them, and the
// renders of any earlier render version of ours, once per render version.
//
// (The package's `cacheFolder` option is not used to move the cache: its parameter type is a conditional-export stub the
// analyzer cannot match with dart:io's Directory. The identity in the file name does the job.)
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/basemap.dart' show basemapRenderVersion;
import '../../core/map_prefs.dart';

abstract final class BasemapRenderCache {
  /// The renderer's folder under the temp directory (vector_map_tiles' default).
  static const String folderName = '.vector_map';

  /// What the shared no-id theme of builds 57 to 71 named its renders.
  static const String legacyPrefix = 'default-vnone-';

  /// Our styles' ids all start with this (tool/basemap/make_basemap_styles.mjs).
  static const String ownPrefix = 'meshsonar-';

  /// The temp directory (tests point this at their own).
  @visibleForTesting
  static Future<Directory> Function() tempDirectory = getTemporaryDirectory;

  static final RegExp _ownRender = RegExp(r'^meshsonar-[a-z0-9-]*?-v(\d+)-\d+-\d+-\d+\.png$');

  /// True for a file the current build must never draw: a render under the old shared identity, or one of our styles'
  /// renders from another render version.
  static bool isStaleRender(String fileName) {
    if (fileName.startsWith(legacyPrefix)) return true;
    final m = _ownRender.firstMatch(fileName);
    return m != null && m.group(1) != '$basemapRenderVersion';
  }

  static bool _scheduled = false;

  /// Schedules [purgeOld] for after the first frame, once per launch. Never awaited: the map does not wait for it.
  static void purgeOldOnce({MapPrefs? prefs}) {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(purgeOld(prefs ?? MapPrefs.shared)));
  }

  @visibleForTesting
  static void debugReset() => _scheduled = false;

  /// Deletes every stale render ([isStaleRender]) and drops what Flutter's image cache holds, then remembers it in [prefs] so
  /// it runs once per render version. File work is dart:io's async API (its own threads, not the UI thread). Any failure
  /// leaves the flag unset: the next launch tries again. Returns the number of files deleted, or null when it did not run
  /// (already done) or failed.
  static Future<int?> purgeOld(MapPrefs prefs) async {
    try {
      await prefs.load();
      if (prefs.basemapCachePurged == basemapRenderVersion) return null;
      // Tiles decoded under the old shared key ("default/vnone/...") must not be painted again in this run either.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final dir = Directory(p.join((await tempDirectory()).path, folderName));
      var deleted = 0;
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File && isStaleRender(p.basename(e.path))) {
            await e.delete();
            deleted++;
          }
        }
      }
      prefs.basemapCachePurged = basemapRenderVersion;
      return deleted;
    } catch (_) {
      return null; // retried on the next launch; the map never depends on this
    }
  }
}
