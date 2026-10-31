// Drives that could not be uploaded (no signal in the field, server down, rate limit) are tried again by themselves:
// at launch and each time the app comes back to the front, never while driving, and never while the server said wait.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';

import '../ui/fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

DriveSession finished(String id) {
  final start = DateTime.utc(2026, 10, 16, 9);
  return DriveSession(id: id, startedAt: start, endedAt: start.add(const Duration(hours: 1)));
}

void main() {
  test('a finished drive that never uploaded goes up at the next launch', () async {
    final h = Harness()..approveKey();
    h.store.seed(finished('left-behind'), [silentPing('a'), silentPing('b')]);
    h.state.retryPendingAtLaunch = true;
    await h.state.init();
    await settle();
    expect(h.sync.syncAllCalls, 1);
    expect(h.store.synced['left-behind'], containsAll(['a', 'b']));
  });

  test('nothing waiting: no request at launch or on resume', () async {
    final h = Harness()..approveKey();
    h.state.retryPendingAtLaunch = true;
    await h.state.init();
    h.state.debugOnForeground();
    await settle();
    expect(h.sync.syncAllCalls, 0);
  });

  test('a failed retry is quiet, and the next resume (2+ minutes later) tries again and succeeds', () async {
    final h = Harness()..approveKey();
    h.store.seed(finished('d1'), [silentPing('a')]);
    h.sync.failWith = 'network error: connection reset';
    h.state.retryPendingAtLaunch = true;
    await h.state.init();
    await settle();
    expect(h.sync.syncAllCalls, 1);
    expect(h.state.pendingNotice, isNull, reason: 'a background retry that fails says nothing');
    h.state.debugOnForeground();
    await settle();
    expect(h.sync.syncAllCalls, 1, reason: 'throttled: not again within 2 minutes');
    h.clockNow = h.clockNow.add(const Duration(minutes: 3));
    h.sync.failWith = null;
    h.state.debugOnForeground();
    await settle();
    expect(h.sync.syncAllCalls, 2);
    expect(h.store.synced['d1'], contains('a'));
    expect(h.state.takeNotice(), contains('Uploaded 1 waiting ping'));
  });

  test('after a 429 nothing is retried automatically until the wait is over', () async {
    final h = Harness()..approveKey();
    h.store.seed(finished('d1'), [silentPing('a')]);
    h.sync
      ..failWith = 'HTTP 429: the server asked us to slow down'
      ..failRetryAfterSec = 600;
    h.state.retryPendingAtLaunch = true;
    await h.state.init();
    await settle();
    expect(h.sync.syncAllCalls, 1);
    h.sync.failWith = null;
    h.clockNow = h.clockNow.add(const Duration(minutes: 5)); // past the 2 minute throttle, inside the 10 minute wait
    h.state.debugOnForeground();
    await settle();
    expect(h.sync.syncAllCalls, 1, reason: 'the server said wait 10 minutes');
    h.clockNow = h.clockNow.add(const Duration(minutes: 6));
    h.state.debugOnForeground();
    await settle();
    expect(h.sync.syncAllCalls, 2);
  });

  test('no retry without an approved key or with auto-upload off', () async {
    final h = Harness();
    h.store.seed(finished('d1'), [silentPing('a')]);
    h.state.retryPendingAtLaunch = true;
    await h.state.init();
    h.state.debugOnForeground();
    await settle();
    expect(h.sync.syncAllCalls, 0);
  });
}
