// Feature flags of the Chat and Drive redesigns (plan D23). Drive's flag defaults ON, Chat's OFF.
// Chat redesign (plan D23). `chatRedesign` is OFF by default and is flipped from More > Developer so
// partially merged work can sit on main without showing half a UI. It is removed in WP15. Persisted next to the other UI
// prefs in a small JSON file so a TestFlight build keeps the choice across launches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class AppFlags {
  /// New Chat screens that are not finished everywhere yet (Ping, Stats and Route tools on the contact profile, ...).
  static final ValueNotifier<bool> chatRedesignNotifier = ValueNotifier<bool>(false);

  /// Plain read / write of the flag (the shape the other Chat work packages use); widgets that must rebuild when it
  /// flips listen to [chatRedesignNotifier].
  static bool get chatRedesign => chatRedesignNotifier.value;
  static set chatRedesign(bool v) => chatRedesignNotifier.value = v;

  /// The new Drive screen (map plus bottom panel, Drive plan WP3). ON by default (Andy, Nov 2): More > Developer keeps a switch
  /// that falls back to the old footer layout as an escape hatch.
  static final ValueNotifier<bool> driveRedesignNotifier = ValueNotifier<bool>(true);
  static bool get driveRedesign => driveRedesignNotifier.value;
  static set driveRedesign(bool v) => driveRedesignNotifier.value = v;

  /// Reads the saved choice. A missing or damaged file leaves the default (off).
  static Future<void> load(File? file) async {
    if (file == null) return;
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is Map && j['chatRedesign'] is bool) chatRedesign = j['chatRedesign'] as bool;
      if (j is Map && j['driveRedesign'] is bool) driveRedesign = j['driveRedesign'] as bool;
    } catch (_) {}
  }

  /// Sets the flag and saves it (best effort: a failed write only costs the choice on the next launch).
  static Future<void> setChatRedesign(bool v, {File? file}) async {
    chatRedesign = v;
    await _save(file);
  }

  static Future<void> setDriveRedesign(bool v, {File? file}) async {
    driveRedesign = v;
    await _save(file);
  }

  static Future<void> _save(File? file) async {
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'chatRedesign': chatRedesign, 'driveRedesign': driveRedesign}), flush: true);
    } catch (_) {}
  }
}
