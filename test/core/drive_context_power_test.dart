// Battery plan D9: radio stats and the phone sample follow the battery mode's statsEveryS (60 s, Saver 5 min), also
// when the mode changes mid-drive; a pinned interval still wins.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_context_recorder.dart';
import 'package:meshsonar/core/drive_context_session.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_health.dart';

import '../ui/fakes.dart' show FakeBattery, FakeContextLedger;

class _Radio implements RadioStatsSource {
  @override
  bool isConnected = true;
  @override
  Future<BattAndStorageFrame?> batteryAndStorage() async => null;
  @override
  Future<CoreStatsFrame?> coreStats() async => null;
  @override
  Future<RadioStatsFrame?> radioStats() async => null;
  @override
  Future<PacketStatsFrame?> packetStats() async => null;
  @override
  Future<SelfTelemetry?> selfTelemetry() async => null;
}

class _T implements Timer {
  bool on = true;
  @override
  void cancel() => on = false;
  @override
  bool get isActive => on;
  @override
  int get tick => 0;
}

void main() {
  final periods = <Duration>[];
  tearDown(() {
    PowerProfile.debugReset();
    periods.clear();
  });

  DriveContextSession make({Duration? every}) => DriveContextSession(
        recorder: DriveContextRecorder(ledger: FakeContextLedger(), sessionId: 's1', isOn: (_) => true),
        pingBusy: () => false,
        radio: _Radio(),
        battery: FakeBattery(),
        phoneEvery: every,
        radioEvery: every,
        periodic: (d, _) {
          periods.add(d);
          return _T();
        },
        radioTimer: (d, cb) => _T(),
      );

  test('Balanced = 60 s, Saver = 5 min for both radio stats and the phone sample', () async {
    PowerProfile.debugReset(PowerSettings.balanced);
    final a = make();
    await a.start();
    expect(a.poller!.interval, const Duration(seconds: 60));
    expect(periods.last, const Duration(seconds: 60));
    a.stop();

    PowerProfile.debugReset(PowerSettings.saver);
    final b = make();
    await b.start();
    expect(b.poller!.interval, const Duration(minutes: 5));
    expect(periods.last, const Duration(minutes: 5));
    b.stop();
  });

  test('a mode change mid-drive restarts the collectors on the new interval', () async {
    PowerProfile.debugReset(PowerSettings.balanced);
    final c = make();
    await c.start();
    final first = c.poller;
    await PowerProfile.set(PowerSettings.saver);
    expect(c.poller, isNot(same(first)));
    expect(first!.isRunning, isFalse);
    expect(c.poller!.interval, const Duration(minutes: 5));
    expect(periods.last, const Duration(minutes: 5));
    final n = periods.length;
    await PowerProfile.set(PowerSettings.saver.tweak((s) => s.copyWith(mapFps: 60)));
    expect(periods.length, n, reason: 'same interval: nothing restarted');
    c.stop();
  });

  test('a pinned interval ignores the mode', () async {
    PowerProfile.debugReset(PowerSettings.saver);
    final c = make(every: const Duration(seconds: 15));
    await c.start();
    expect(c.poller!.interval, const Duration(seconds: 15));
    expect(periods.last, const Duration(seconds: 15));
    c.stop();
  });
}
