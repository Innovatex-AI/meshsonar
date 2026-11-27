// The Plan tab's last mode (build 77, round 4 P-U1): kept beside the planner's stored answers, never taken by their eviction.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_mode_memory.dart';
import 'package:meshsonar/core/plan/plan_store.dart';

void main() {
  test('in memory without a directory, per store', () async {
    final a = PlanStore(), b = PlanStore();
    expect(await PlanModeMemory(a).read(), isNull);
    await PlanModeMemory(a).write('coverage');
    expect(await PlanModeMemory(a).read(), 'coverage');
    expect(await PlanModeMemory(b).read(), isNull, reason: 'another store (another app run in tests) starts fresh');
  });

  test('on disk: survives a new store on the same folder and the store\'s eviction of its answers', () async {
    final dir = await Directory.systemTemp.createTemp('plan_mode_memory');
    addTearDown(() => dir.delete(recursive: true));
    final store = PlanStore(dir: dir, maxEntries: 2);
    await PlanModeMemory(store).write('whereToDrive');
    for (var i = 0; i < 5; i++) {
      await store.write('k$i', 'body $i');
    }
    expect(await PlanModeMemory(PlanStore(dir: dir)).read(), 'whereToDrive');
  });
}
