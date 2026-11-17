// Battery plan A7: the BLE safety poll follows the battery mode (front / background) and is counted.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/app_foreground.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/radio/message_sync.dart';
import 'package:meshsonar/radio/protocol.dart';

class _Src implements MessageSource {
  int syncs = 0;
  @override
  bool get isConnected => true;
  @override
  Future<Frame> syncNextMessage() async {
    syncs++;
    return decodeFrame(encodeNoMoreMessages());
  }
}

/// Polls in one idle hour with the app in front ([fg]) on [mode].
int _pollsPerHour(PowerSettings mode, {required bool fg}) {
  PowerProfile.debugReset(mode);
  AppForeground.debugReset();
  AppForeground.set(fg);
  PowerCounters.debugReset();
  var n = 0;
  fakeAsync((async) {
    final sync = MessageSync(_Src());
    final sub = sync.messages.listen((_) {});
    async.elapse(const Duration(hours: 1));
    n = PowerCounters.get(PowerCounters.blePoll);
    unawaited(sub.cancel());
    sync.dispose();
  });
  return n;
}

void main() {
  tearDown(() {
    PowerProfile.debugReset();
    AppForeground.debugReset();
    PowerCounters.debugReset();
  });

  test('Balanced idle hour: <= 120 polls in front, <= 30 in the background', () {
    expect(_pollsPerHour(PowerSettings.balanced, fg: true), inInclusiveRange(100, 120));
    expect(_pollsPerHour(PowerSettings.balanced, fg: false), inInclusiveRange(20, 30));
  });

  test('Max data keeps the 5 s poll (720 an hour) in front and behind', () {
    expect(_pollsPerHour(PowerSettings.maxData, fg: true), 720);
    expect(_pollsPerHour(PowerSettings.maxData, fg: false), 720);
  });

  test('Saver: every 2 min in front, push only (no poll) in the background', () {
    expect(_pollsPerHour(PowerSettings.saver, fg: true), 30);
    expect(_pollsPerHour(PowerSettings.saver, fg: false), 0);
  });

  test('going behind switches the interval at once; coming back drains once and resumes the front rate', () {
    PowerProfile.debugReset(PowerSettings.balanced);
    AppForeground.debugReset();
    PowerCounters.debugReset();
    fakeAsync((async) {
      final src = _Src();
      final sync = MessageSync(src);
      final sub = sync.messages.listen((_) {});
      async.elapse(const Duration(seconds: 61));
      expect(PowerCounters.get(PowerCounters.blePoll), 2);
      AppForeground.set(false);
      async.elapse(const Duration(seconds: 119));
      expect(PowerCounters.get(PowerCounters.blePoll), 2, reason: 'background: next poll at 120 s');
      async.elapse(const Duration(seconds: 2));
      expect(PowerCounters.get(PowerCounters.blePoll), 3);
      final before = src.syncs;
      AppForeground.set(true);
      async.flushMicrotasks();
      expect(src.syncs, before + 1, reason: 'drain on resume');
      async.elapse(const Duration(seconds: 31));
      expect(PowerCounters.get(PowerCounters.blePoll), 4);
      unawaited(sub.cancel());
      sync.dispose();
    });
  });

  test('a mode change mid-run takes effect without a restart', () {
    PowerProfile.debugReset(PowerSettings.balanced);
    AppForeground.debugReset();
    PowerCounters.debugReset();
    fakeAsync((async) {
      final sync = MessageSync(_Src());
      final sub = sync.messages.listen((_) {});
      expect(sync.currentPollInterval, const Duration(seconds: 30));
      unawaited(PowerProfile.set(PowerSettings.maxData));
      expect(sync.currentPollInterval, const Duration(seconds: 5));
      async.elapse(const Duration(seconds: 60));
      expect(PowerCounters.get(PowerCounters.blePoll), 12);
      unawaited(sub.cancel());
      sync.dispose();
    });
  });

  test('a pinned interval (tests, tools) ignores the profile', () {
    PowerProfile.debugReset(PowerSettings.saver);
    AppForeground.debugReset();
    AppForeground.set(false);
    final sync = MessageSync(_Src(), pollInterval: const Duration(seconds: 7));
    expect(sync.currentPollInterval, const Duration(seconds: 7));
    sync.dispose();
  });
}
