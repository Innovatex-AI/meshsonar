import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/command_queue.dart';

void main() {
  test('jobs run one at a time, in order, at equal priority', () async {
    final q = CommandQueue();
    final log = <String>[];
    var running = 0;
    var maxRunning = 0;
    Future<void> job(String n) async {
      running++;
      maxRunning = running > maxRunning ? running : maxRunning;
      log.add('start $n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      log.add('end $n');
      running--;
    }

    await Future.wait([q.run(() => job('a')), q.run(() => job('b')), q.run(() => job('c'))]);
    expect(maxRunning, 1);
    expect(log, ['start a', 'end a', 'start b', 'end b', 'start c', 'end c']);
  });

  test('a waiting user job goes before waiting pings, but never interrupts the running one', () async {
    final q = CommandQueue();
    final log = <String>[];
    final gate = Completer<void>();
    final first = q.run(() async {
      log.add('ping1 start');
      await gate.future;
      log.add('ping1 end');
    }, priority: CommandPriority.ping);
    await Future<void>.delayed(Duration.zero); // the first job is on the air
    final ping2 = q.run(() async => log.add('ping2'), priority: CommandPriority.ping);
    final stats = q.run(() async => log.add('stats'), priority: CommandPriority.ping);
    final user = q.run(() async => log.add('user'), priority: CommandPriority.user);
    final admin = q.run(() async => log.add('admin'), priority: CommandPriority.admin);
    await Future<void>.delayed(Duration.zero);
    expect(log, ['ping1 start']);
    gate.complete();
    await Future.wait([first, ping2, stats, user, admin]);
    expect(log, ['ping1 start', 'ping1 end', 'user', 'admin', 'ping2', 'stats']);
  });

  test('a failing job does not stop the queue and reports its own error', () async {
    final q = CommandQueue();
    final bad = q.run<int>(() async => throw StateError('boom'));
    final good = q.run(() async => 7);
    await expectLater(bad, throwsStateError);
    expect(await good, 7);
    expect(q.busy, isFalse);
  });

  test('close fails the waiting jobs and refuses new ones', () async {
    final q = CommandQueue();
    final gate = Completer<void>();
    final running = q.run(() => gate.future);
    final waiting = q.run(() async => 1);
    final waitingErr = expectLater(waiting, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);
    q.close(StateError('closed'));
    await waitingErr;
    await expectLater(q.run(() async => 2), throwsA(isA<StateError>()));
    gate.complete();
    await running;
  });
}
