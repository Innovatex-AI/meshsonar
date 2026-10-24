import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_health.dart';

/// A fake clock with one-shot timers that fire only when the test advances time.
class FakeTime {
  DateTime now = DateTime.utc(2026, 10, 24, 20);
  final List<_FakeTimer> _timers = [];

  Timer timer(Duration d, void Function() cb) {
    final t = _FakeTimer(now.add(d), cb, this);
    _timers.add(t);
    return t;
  }

  static Future<void> pump() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> advance(Duration d) async {
    final end = now.add(d);
    await pump();
    while (true) {
      final due = _timers.where((t) => t.isActive && !t.at.isAfter(end)).toList()..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      if (t.at.isAfter(now)) now = t.at;
      t.fire();
      await pump();
    }
    now = end;
    await pump();
  }
}

class _FakeTimer implements Timer {
  final DateTime at;
  final void Function() cb;
  final FakeTime owner;
  bool _active = true;
  _FakeTimer(this.at, this.cb, this.owner);
  void fire() {
    _active = false;
    owner._timers.remove(this);
    cb();
  }

  @override
  void cancel() {
    _active = false;
    owner._timers.remove(this);
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

class FakeStats implements RadioStatsSource {
  final FakeTime time;
  bool connected = true;
  bool Function() busy;
  final List<(String, DateTime, bool)> calls = [];
  CoreStatsFrame? core = const CoreStatsFrame(batteryMv: 3912, uptimeSecs: 86011, errFlags: 0, queueLen: 0);
  RadioStatsFrame? radio = const RadioStatsFrame(-104, -88, 6.25, 412, 1930);
  PacketStatsFrame? packets = const PacketStatsFrame(
      recv: 18233, sent: 412, floodTx: 400, directTx: 12, floodRx: 17001, directRx: 1232, recvErrors: 37);
  BattAndStorageFrame? batt = const BattAndStorageFrame(batteryMv: 3910, storageUsedKb: 120, storageTotalKb: 1984);
  bool throwOnPackets = false;

  /// Called after each command (to flip state mid-poll).
  void Function(String cmd)? after;

  FakeStats(this.time, this.busy);

  T? _rec<T>(String name, T? v) {
    calls.add((name, time.now, busy()));
    after?.call(name);
    return v;
  }

  @override
  bool get isConnected => connected;
  @override
  Future<BattAndStorageFrame?> batteryAndStorage() async => _rec('batt', batt);
  SelfTelemetry? telemetry = const SelfTelemetry(mcuTempC: 31.5, voltageV: 3.91);
  @override
  Future<SelfTelemetry?> selfTelemetry() async => _rec('telemetry', telemetry);
  @override
  Future<CoreStatsFrame?> coreStats() async => _rec('core', core);
  @override
  Future<RadioStatsFrame?> radioStats() async => _rec('radio', radio);
  @override
  Future<PacketStatsFrame?> packetStats() async {
    _rec('packets', null);
    if (throwOnPackets) throw TimeoutException('no answer');
    return packets;
  }
}

void main() {
  late FakeTime time;
  late FakeStats src;
  late List<DriveSample> out;
  var busy = false;
  late RadioHealthPoller poller;

  RadioHealthPoller make({Future<int?> Function()? ble}) => RadioHealthPoller(
        source: src,
        pingBusy: () => busy,
        onSample: out.add,
        clock: () => time.now,
        timer: time.timer,
        bleRssi: ble,
      );

  setUp(() {
    time = FakeTime();
    busy = false;
    out = [];
    src = FakeStats(time, () => busy);
    poller = make();
  });

  tearDown(() => poller.stop());

  test('first poll at start: radio, core, packets, battery+storage in order; one sample with every field', () async {
    poller.start();
    await time.advance(Duration.zero);
    expect(src.calls.map((c) => c.$1), ['radio', 'core', 'packets', 'batt', 'telemetry']);
    expect(out, hasLength(1));
    final j = out.single.toJson();
    expect(j, {
      'ts': '2026-10-24T20:00:00.000Z',
      'src': 'radio',
      'batt_mv': 3912,
      'uptime_s': 86011,
      'err_flags': 0,
      'queue': 0,
      'tx_air_s': 412,
      'rx_air_s': 1930,
      'last_rssi': -88,
      'last_snr': 6.25,
      'noise_dbm': -104,
      'pkts': {
        'recv': 18233,
        'sent': 412,
        'flood_tx': 400,
        'direct_tx': 12,
        'flood_rx': 17001,
        'direct_rx': 1232,
        'recv_errors': 37
      },
      'storage_kb': {'used': 120, 'total': 1984},
      'mcu_temp_c': 31.5,
    });
    expect(poller.lastSample, same(out.single));
  });

  test('every 60 s; storage only every 15 min', () async {
    poller.start();
    await time.advance(Duration.zero);
    await time.advance(const Duration(seconds: 59));
    expect(out, hasLength(1));
    await time.advance(const Duration(seconds: 1));
    expect(out, hasLength(2));
    expect(src.calls.where((c) => c.$1 == 'batt'), hasLength(1));
    await time.advance(const Duration(minutes: 14));
    expect(out, hasLength(16));
    expect(src.calls.where((c) => c.$1 == 'batt'), hasLength(2), reason: 'second storage read at 15 min');
    expect(out[1].storageTotalKb, isNull);
    expect(out[15].storageTotalKb, 1984);
  });

  test('never sends a command while a ping is in flight; waits and then polls', () async {
    busy = true;
    poller.start();
    await time.advance(const Duration(seconds: 5));
    expect(src.calls, isEmpty);
    busy = false;
    await time.advance(const Duration(seconds: 1));
    expect(src.calls.map((c) => c.$1), ['radio', 'core', 'packets', 'batt', 'telemetry']);
    expect(src.calls.every((c) => !c.$3), isTrue);
    expect(out.single.ts, DateTime.utc(2026, 10, 24, 20), reason: 'sample time = poll start');
  });

  test('a ping starting mid-poll pauses the remaining commands until it is done', () async {
    src.after = (cmd) {
      if (cmd == 'radio') busy = true;
    };
    poller.start();
    await time.advance(Duration.zero);
    expect(src.calls.map((c) => c.$1), ['radio']);
    await time.advance(const Duration(seconds: 7));
    expect(src.calls.map((c) => c.$1), ['radio']);
    src.after = null;
    busy = false;
    await time.advance(const Duration(seconds: 1));
    expect(src.calls.map((c) => c.$1), ['radio', 'core', 'packets', 'batt', 'telemetry']);
    expect(src.calls.every((c) => !c.$3), isTrue);
    expect(out, hasLength(1));
  });

  test('busy for longer than half the interval: the poll is skipped, the next one runs on time', () async {
    busy = true;
    poller.start();
    await time.advance(const Duration(seconds: 40));
    expect(src.calls, isEmpty);
    expect(out, isEmpty);
    busy = false;
    await time.advance(const Duration(seconds: 30));
    expect(out, hasLength(1));
  });

  test('disconnected: nothing asked, nothing recorded; resumes when connected', () async {
    src.connected = false;
    poller.start();
    await time.advance(const Duration(minutes: 3));
    expect(src.calls, isEmpty);
    expect(out, isEmpty);
    src.connected = true;
    await time.advance(const Duration(seconds: 60));
    expect(out, hasLength(1));
  });

  test('stop: no further commands or samples', () async {
    poller.start();
    await time.advance(Duration.zero);
    poller.stop();
    await time.advance(const Duration(minutes: 5));
    expect(out, hasLength(1));
    expect(poller.isRunning, isFalse);
  });

  test('unmeasured stays null: 0 mV battery, 0 noise floor, 0 last RSSI (and its SNR), 0 storage', () async {
    src.core = const CoreStatsFrame(batteryMv: 0, uptimeSecs: 10, errFlags: 5, queueLen: 2);
    src.radio = const RadioStatsFrame(0, 0, 3.0, 0, 0);
    src.batt = const BattAndStorageFrame(batteryMv: 0, storageUsedKb: 0, storageTotalKb: 0);
    poller.start();
    await time.advance(Duration.zero);
    final j = out.single.toJson();
    expect(j.containsKey('batt_mv'), isFalse);
    expect(j.containsKey('noise_dbm'), isFalse);
    expect(j.containsKey('last_rssi'), isFalse);
    expect(j.containsKey('last_snr'), isFalse);
    expect(j.containsKey('storage_kb'), isFalse);
    expect(j['err_flags'], 5);
    expect(j['queue'], 2);
    expect(j['tx_air_s'], 0);
  });

  test('older firmware without GET_STATS: battery from GET_BATT_AND_STORAGE every poll', () async {
    src.core = null;
    src.radio = null;
    src.packets = null;
    src.telemetry = null;
    poller.start();
    await time.advance(Duration.zero);
    await time.advance(const Duration(seconds: 60));
    expect(src.calls.where((c) => c.$1 == 'batt'), hasLength(2));
    expect(out.map((s) => s.battMv), [3910, 3910]);
    expect(out.first.toJson().keys.toSet(), {'ts', 'src', 'batt_mv', 'storage_kb'});
  });

  test('a command that throws leaves its fields null; the rest is recorded', () async {
    src.throwOnPackets = true;
    poller.start();
    await time.advance(Duration.zero);
    expect(out.single.pkts, isNull);
    expect(out.single.battMv, 3912);
  });

  test('nothing reported at all: no sample', () async {
    src.core = null;
    src.radio = null;
    src.packets = null;
    src.batt = null;
    src.telemetry = null;
    poller.start();
    await time.advance(Duration.zero);
    expect(out, isEmpty);
    expect(poller.lastSample, isNull);
  });

  test('BLE RSSI hook is read after the radio commands', () async {
    poller.stop();
    poller = make(ble: () async => -61);
    poller.start();
    await time.advance(Duration.zero);
    expect(out.single.bleRssi, -61);
  });

  test('radioSampleFrom keeps a 26-byte packet frame (no recv_errors) without the key', () {
    final s = radioSampleFrom(
      ts: DateTime.utc(2026),
      packets: const PacketStatsFrame(recv: 1, sent: 2, floodTx: 3, directTx: 4, floodRx: 5, directRx: 6),
    )!;
    expect((s.toJson()['pkts'] as Map).containsKey('recv_errors'), isFalse);
  });
}
