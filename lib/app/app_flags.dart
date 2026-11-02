// Feature flags of the Chat redesign (plan D23). `chatRedesign` is OFF by default and is flipped from More > Developer so
// partially merged work can sit on main without showing half a UI. It is removed in WP15. Persisted next to the other UI
// prefs in a small JSON file so a TestFlight build keeps the choice across launches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class AppFlags {
  /// New Chat screens that are not finished everywhere yet (Ping, Stats and Route tools on the contact profile, ...).
  static final ValueNotifier<bool> chatRedesign = ValueNotifier<bool>(false);

  /// Reads the saved choice. A missing or damaged file leaves the default (off).
  static Future<void> load(File? file) async {
    if (file == null) return;
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is Map && j['chatRedesign'] is bool) chatRedesign.value = j['chatRedesign'] as bool;
    } catch (_) {}
  }

  /// Sets the flag and saves it (best effort: a failed write only costs the choice on the next launch).
  static Future<void> setChatRedesign(bool v, {File? file}) async {
    chatRedesign.value = v;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'chatRedesign': v}), flush: true);
    } catch (_) {}
  }
}
