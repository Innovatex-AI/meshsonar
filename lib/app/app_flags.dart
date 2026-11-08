// Feature flags. The Chat redesign flag is gone (plan D23, removed in Chat WP15: the new Chat UI is unconditional). What is left:
// the Drive redesign switch (default ON; More > Developer falls back to the old footer layout as an escape hatch, removed with
// the Drive plan) and the set-path write gate. Persisted next to the other UI prefs in a small JSON file (an old 'chatRedesign'
// key in that file is ignored).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class AppFlags {
  /// The set-path radio write (Chat WP7): ADD_UPDATE_CONTACT with a chosen route ("Choose repeaters yourself" > Save) and the
  /// outbox rewrite of a path the radio forgot in Keep this route. Hidden until Andy's real-radio test passes (spikes S3/S13,
  /// HANDOFF checklist). Everything else about routes (display, mode, discovery, trace, ping, reset) is live.
  static const bool routeWriteVerified = false;

  /// The new Drive screen (map plus bottom panel, Drive plan WP3). ON by default (Andy, Nov 2): More > Developer keeps a switch
  /// that falls back to the old footer layout as an escape hatch.
  static final ValueNotifier<bool> driveRedesignNotifier = ValueNotifier<bool>(true);
  static bool get driveRedesign => driveRedesignNotifier.value;
  static set driveRedesign(bool v) => driveRedesignNotifier.value = v;


  /// Reads the saved choice. A missing or damaged file leaves the default (on).
  static Future<void> load(File? file) async {
    if (file == null) return;
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is Map && j['driveRedesign'] is bool) driveRedesign = j['driveRedesign'] as bool;
    } catch (_) {}
  }

  /// Sets the Drive flag and saves it (best effort: a failed write only costs the choice on the next launch).
  static Future<void> setDriveRedesign(bool v, {File? file}) async {
    driveRedesign = v;
    await _save(file);
  }

  static Future<void> _save(File? file) async {
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'driveRedesign': driveRedesign}), flush: true);
    } catch (_) {}
  }
}
