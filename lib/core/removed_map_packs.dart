// Build 76 removed the downloadable region map packs (builds up to 75 kept them in `<app support>/meshsonar/offline_packs`:
// `<CODE>.pmtiles`, `<CODE>.coverage.pmtiles`, unfinished `.part` files, and the `packs.json`, `prefs.json` and
// `manifest.cache.json` beside them). This only deletes that folder; nothing here reads a pack. Pure Dart.
import 'dart:io';

/// The folder the removed feature used, under the app's data folder [base] (application support, or documents where that
/// was not available).
Directory oldMapPackFolder(Directory base) => Directory('${base.path}/meshsonar/offline_packs');

/// Deletes the old pack folder under each of [bases] with everything in it. Returns the bytes freed (0 when there was
/// nothing, which is every launch after the first). Never throws: a folder that cannot be deleted is tried again next launch.
Future<int> removeOldMapPackFiles(Iterable<Directory> bases) async {
  var freed = 0;
  for (final base in bases) {
    final dir = oldMapPackFolder(base);
    try {
      if (!await dir.exists()) continue;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            freed += await e.length();
          } catch (_) {}
        }
      }
      await dir.delete(recursive: true);
    } catch (_) {}
  }
  return freed;
}
