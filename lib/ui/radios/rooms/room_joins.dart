// Which rooms this app run has joined, and how. Listen to [changes] to show the joined state in lists and titles.
import 'package:flutter/foundation.dart';

import '../../../radio/claim_radio.dart';

class RoomJoins {
  static final Map<String, RemoteLogin> _joined = {};

  /// Bumps whenever a join is added or cleared.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static RemoteLogin? of(String keyHex) => _joined[keyHex.toLowerCase()];
  static void set(String keyHex, RemoteLogin l) {
    _joined[keyHex.toLowerCase()] = l;
    changes.value++;
  }

  static void clear() {
    _joined.clear();
    changes.value++;
  }

  /// "Joined", "Joined as admin" or "Joined, read only"; null when not joined.
  static String? label(String keyHex) {
    final j = of(keyHex);
    if (j == null) return null;
    return j.isAdmin ? 'Joined as admin' : (j.canPost ? 'Joined' : 'Joined, read only');
  }
}
