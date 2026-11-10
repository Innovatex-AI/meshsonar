// The Map Definition every map renders from right now (plan unified-map-system §2.2, phase M2). It starts as the bundled
// copy (the M1 fixture, no I/O) and follows the server: the last good copy of the viewed scope (region, group or the hub)
// replaces it as soon as the store has one, and a newer copy from a refresh replaces that. The theme (signal colours), the
// coverage styles, the repeater / observer symbols, the Layers sheet, the legend card and the paint order all read it, so a
// definition change on the server reaches every app map without an app release.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/map_definition.dart';

class ActiveMapDefinition {
  ActiveMapDefinition._();

  static final ValueNotifier<MapDefinition> notifier = ValueNotifier<MapDefinition>(MapDefinition.bundled);

  /// The definition maps draw from now.
  static MapDefinition get current => notifier.value;

  static String? _scope;
  static StreamSubscription<String>? _changes;

  /// The scope the app is looking at ('' or null = the server's own scope). Called when the viewed region changes; the store
  /// answers from its last good copy at once and refreshes in the background when stale.
  static Future<void> follow(String? scope) async {
    final store = MapDefinitionStore.instance;
    final k = (scope ?? '').trim().toLowerCase();
    _scope = k;
    if (store == null) return;
    _changes ??= store.changes.listen((changed) {
      if (changed == _scope) unawaited(_load(store, changed));
    });
    await _load(store, k);
    final fresh = await store.refreshIfStale(k);
    if (_scope == k) _set(fresh.definition);
  }

  static Future<void> _load(MapDefinitionStore store, String k) async {
    try {
      final c = await store.current(k);
      if (_scope == k) _set(c.definition);
    } catch (_) {
      // the bundled copy stays
    }
  }

  static void _set(MapDefinition d) {
    if (d.version != notifier.value.version) notifier.value = d;
  }

  /// Tests: back to the bundled copy (or [d]).
  @visibleForTesting
  static void debugSet([MapDefinition? d]) {
    _scope = null;
    notifier.value = d ?? MapDefinition.bundled;
  }
}
