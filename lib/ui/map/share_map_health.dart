// Drives > menu > Share map health: sends the drive's `map_health.jsonl` (frame times, puck update rate, camera mode, tile source
// mix per 10 seconds; local only) through the system share sheet, like the ping trace.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/drive_store.dart' show MapHealthStore;

Future<void> shareMapHealth(BuildContext context, AppState s, String sessionId) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final st = s.services.store;
    final f = st is MapHealthStore ? await (st as MapHealthStore).mapHealthFile(sessionId) : null;
    if (f == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('This drive has no map health samples. Drives recorded from this version on keep them.')));
      return;
    }
    final dir = await s.services.exportDir();
    final short = sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    final out = await f.copy('${dir.path}/meshsonar-map-health-$short.jsonl');
    await s.services.shareFile(out);
  } catch (e) {
    messenger?.showSnackBar(const SnackBar(content: Text('Could not share the map health file.')));
  }
}
