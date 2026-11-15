// Saved plans on the phone (lib/core/plan/plan_repository.dart): one file per plan, atomic, newest first, ids are safe
// file names.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_repository.dart';

void main() {
  test('file store: write, read, list newest first, delete; a bad id never touches the disk', () async {
    final dir = await Directory.systemTemp.createTemp('plans');
    addTearDown(() => dir.delete(recursive: true));
    final r = FilePlanRepository(Directory('${dir.path}/plans'));
    expect(await r.ids(), isEmpty, reason: 'no folder yet');
    await r.write('p1', '{"v":1,"name":"One"}');
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // file times have 1 s resolution on some disks
    await r.write('p2', '{"v":1,"name":"Two"}');
    expect(await r.ids(), ['p2', 'p1']);
    expect(await r.read('p1'), '{"v":1,"name":"One"}');
    expect(await r.read('missing'), isNull);
    expect(await r.read('../etc/passwd'), isNull);
    expect(() => r.write('../evil', '{}'), throwsArgumentError);
    await r.delete('p1');
    expect(await r.ids(), ['p2']);
    expect(Directory('${dir.path}/plans').listSync().map((e) => e.uri.pathSegments.last), ['p2.plan.json'], reason: 'no temp file left');
  });

  test('memory store: same contract', () async {
    final r = MemoryPlanRepository();
    await r.write('a', '1');
    await r.write('b', '2');
    await r.write('a', '3');
    expect(await r.ids(), ['a', 'b']);
    expect(await r.read('a'), '3');
    await r.delete('a');
    expect(await r.ids(), ['b']);
    expect(isValidPlanId('plan_2026-11-15'), isTrue);
    expect(isValidPlanId(''), isFalse);
    expect(isValidPlanId('a b'), isFalse);
  });
}
