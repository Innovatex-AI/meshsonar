// The Plan tab's last mode (build 77, round 4 P-U1: the tab opens where the person left it, not always on Link). One word
// (the mode's name) in a small text file beside the planner's stored answers (PlanStore.dir). The file is not `.json`, so
// the store's eviction never takes it; clearing the store forgets it. Without a directory (tests, a phone that gave no
// support folder) it is kept in memory for that store only. Nothing here leaves the phone. Pure Dart.
import 'dart:io';

import 'plan_store.dart';

class PlanModeMemory {
  final PlanStore store;
  PlanModeMemory(this.store);

  static final Expando<String> _mem = Expando<String>('plan mode');

  File? get _file => store.dir == null ? null : File('${store.dir!.path}${Platform.pathSeparator}plan_last_mode.txt');

  /// The mode name last saved, or null when none was.
  Future<String?> read() async {
    final m = _mem[store];
    if (m != null) return m;
    try {
      final f = _file;
      if (f == null || !await f.exists()) return null;
      final v = (await f.readAsString()).trim();
      return v.isEmpty ? null : _mem[store] = v;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String mode) async {
    if (_mem[store] == mode) return;
    _mem[store] = mode;
    try {
      final f = _file;
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(mode, flush: true);
    } catch (_) {
      // A full or read-only disk only costs the memory of the mode.
    }
  }
}
