// Launch glue for lib/core/removed_map_packs.dart: finds the app's data folders and deletes what the removed map packs
// feature left there. Runs at every launch; after the first it finds nothing.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/removed_map_packs.dart';

Future<void> removeOldMapPackFilesAtLaunch() async {
  final bases = <Directory>[];
  for (final get in [getApplicationSupportDirectory, getApplicationDocumentsDirectory]) {
    try {
      bases.add(await get());
    } catch (_) {}
  }
  await removeOldMapPackFiles(bases);
}
