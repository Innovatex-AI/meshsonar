// Feature flags of the Chat redesign (plan D23). `chatRedesign` is ON by default (Andy, Nov 2: live for testers); More > Developer
// switches back to the old Chat UI and the old contact details as an escape hatch. It is removed in WP15. Persisted next to the other UI
// prefs in a small JSON file so a TestFlight build keeps the choice across launches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class AppFlags {
  /// What a fresh install gets.
  static const bool chatRedesignDefault = true;

  /// New Chat screens that are not finished everywhere yet (Ping, Stats and Route tools on the contact profile, ...).
  static final ValueNotifier<bool> chatRedesignNotifier = ValueNotifier<bool>(chatRedesignDefault);

  /// Plain read / write of the flag (the shape the other Chat work packages use); widgets that must rebuild when it
  /// flips listen to [chatRedesignNotifier].
  static bool get chatRedesign => chatRedesignNotifier.value;
  static set chatRedesign(bool v) => chatRedesignNotifier.value = v;

  /// Reads the saved choice. A missing or damaged file leaves the default (on).
  static Future<void> load(File? file) async {
    if (file == null) return;
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is Map && j['chatRedesign'] is bool) chatRedesign = j['chatRedesign'] as bool;
    } catch (_) {}
  }

  /// Sets the flag and saves it (best effort: a failed write only costs the choice on the next launch).
  static Future<void> setChatRedesign(bool v, {File? file}) async {
    chatRedesign = v;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'chatRedesign': v}), flush: true);
    } catch (_) {}
  }
}
