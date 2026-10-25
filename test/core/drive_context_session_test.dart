// DriveContextSession (stream 7 WP2/WP3): every collector starts and stops with the drive and with its category
// switch, nothing is read while the switches (or the disclosure gate behind them) say no, sensors that are missing are
// reported as such and never invented, and no sample ever carries a coordinate.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/data_categories.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_context_recorder.dart';
import 'package:meshsonar/core/drive_context_session.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/phone_sensors.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/radio_health.dart';

import '../ui/fakes.dart' show FakeBarometer, FakeBattery, FakeContextLedger, FakeDeviceDetails;

class _Radio implements RadioStatsSource {
  int polls = 0;
  @override
  bool isConnected = true;
  @override
  Future<BattAndStorageFrame?> batteryAndStorage() async =>
      const BattAndStorageFrame(batteryMv: 3912, storageUsedKb: 120, storageTotalKb: 1984);
  @override
  Future<CoreStatsFrame?> coreStats() async =>
      const CoreStatsFrame(batteryMv: 3910, uptimeSecs: 86011, errFlags: RadioErrFlag.cadTimeout, queueLen: 0);
  @override
  Future<RadioStatsFrame?> radioStats() async {
    polls++;
    return const RadioStatsFrame(-104, -88, 6.25, 412, 1930);
  }

  @override
  Future<PacketStatsFrame?> packetStats() async => null;
  @override
  Future<SelfTelemetry?> selfTelemetry() async => const SelfTelemetry(mcuTempC: 31.5, voltageV: 3.91);
}

void main() {
  late FakeContextLedger ledger;
  late Set<String> off;
  late DateTime now;
  late List<void Function(Timer)> ticks;
  late List<_FakeTimer> timers;
  late List<_FakeTimer> periodics;
  setUp(() {
    ledger = FakeContextLedger();
    off = {};
    now = DateTime.utc(2026, 10, 24, 20, 0, 0);
    ticks = [];
    timers = [];
    periodics = [];
  });

  Timer periodic(Duration d, void Function(Timer) tick) {
    final t = _FakeTimer();
    timers.add(t);
    periodics.add(t);
    ticks.add((x) {
      if (t.isActive) tick(t);
    });
    return t;
  }

  Timer oneShot(Duration d, void Function() cb) {
    final t = _FakeTimer();
    if (d == Duration.zero) scheduleMicrotask(() => t.isActive ? cb() : null);
    timers.add(t);
    return t;
  }

  DriveContextSession make({
    bool Function(String id)? isOn,
    FakeBarometer? baro,
    FakeBattery? battery,
    FakeDeviceDetails? device,
    RadioStatsSource? radio,
    CompanionDetails? companion,
  }) =>
      DriveContextSession(
        recorder: DriveContextRecorder(ledger: ledger, sessionId: 's1', isOn: isOn ?? (id) => !off.contains(id)),
        pingBusy: () => false,
        radio: radio,
        barometer: baro,
        battery: battery,
        deviceDetails: device?.read,
        companion: companion == null ? null : () => companion,
        clock: () => now,
        periodic: periodic,
        radioTimer: oneShot,
      );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  DrivePing ping(String id, DateTime ts) => DrivePing(id: id, ts: ts, lat: 40.1, lon: -82.9);

  test('all on: snapshot, battery at start, barometer median per minute and per ping, motion from the fix', () async {
    final baro = FakeBarometer(), bat = FakeBattery(), dev = FakeDeviceDetails();
    final c = make(baro: baro, battery: bat, device: dev, companion: CompanionDetails(model: 'Heltec V4', maxTxDbm: 22));
    await c.start();
    expect(baro.listening, isTrue);
    expect(c.barometerStatus, SensorStatus.notStarted);
    final ses = await ledger.sessionContext('s1');
    expect(ses!.device!.model, 'iPhone15,2');
    expect(ses.companionExt!.maxTxDbm, 22);
    expect((await ledger.samples('s1')).single.battPct, 64, reason: 'a phone sample at drive start');

    for (final v in [990.0, 990.4, 990.2]) {
      baro.emit(v);
      now = now.add(const Duration(seconds: 1));
      await settle();
    }
    expect(c.barometerStatus, SensorStatus.reading);
    c.onFix(GeoFix(lat: 40.1, lon: -82.9, at: now, altitudeM: 251.3, altitudeAccuracyM: 6, courseDeg: 87, courseAccuracyDeg: 12));
    final ctx = await c.onPingSaved(ping('p1', now));
    expect(ctx!.toJson(), {
      'alt_m': 251.3,
      'alt_acc_m': 6.0,
      'course_deg': 87.0,
      'course_acc_deg': 12.0,
      'pressure_hpa': 990.2,
      'phone_batt_pct': 64,
    });

    ticks.single(periodics.single);
    await settle();
    final last = (await ledger.samples('s1')).last;
    expect(last.pressureHpa, 990.2, reason: 'median of the last minute');
    expect(last.battState, PhoneBatteryState.unplugged);
    c.stop();
    expect(baro.listening, isFalse);
  });

  test('nothing is read while the gate says no (disclosure not seen): no barometer prompt, no battery, no device',
      () async {
    final baro = FakeBarometer(), bat = FakeBattery(), dev = FakeDeviceDetails(), radio = _Radio();
    final c = make(isOn: (_) => false, baro: baro, battery: bat, device: dev, radio: radio);
    await c.start();
    await settle();
    expect(baro.listens, 0, reason: 'listening is what triggers the iOS Motion & Fitness prompt');
    expect(bat.reads, 0);
    expect(dev.reads, 0);
    expect(radio.polls, 0);
    expect(c.poller, isNull);
    expect(timers.where((t) => t.isActive), isEmpty);
    c.onFix(GeoFix(lat: 1, lon: 2, at: now, altitudeM: 100, altitudeAccuracyM: 3));
    expect(await c.onPingSaved(ping('p', now)), isNull);
    expect(await ledger.samples('s1'), isEmpty);
    expect(await ledger.sessionContext('s1'), isNull);
    expect(await ledger.pingContexts('s1'), isEmpty);
  });

  test('switching a category off mid-drive stops its collector at once; on again resumes', () async {
    final baro = FakeBarometer(), bat = FakeBattery(), radio = _Radio();
    final c = make(baro: baro, battery: bat, radio: radio);
    await c.start();
    await settle();
    expect(c.poller?.isRunning, isTrue);
    expect(radio.polls, 1, reason: 'first radio poll at drive start');

    off.addAll({CategoryId.barometer, CategoryId.radioHealth});
    c.refresh();
    expect(baro.listening, isFalse, reason: 'sensor subscription closed');
    expect(c.poller, isNull);
    final reads = bat.reads;
    ticks.single(periodics.single);
    await settle();
    expect(bat.reads, reads + 1, reason: 'battery still on');
    expect((await ledger.samples('s1')).last.pressureHpa, isNull);

    off.remove(CategoryId.barometer);
    c.refresh();
    expect(baro.listening, isTrue);
    expect(baro.listens, 2);

    off.add(CategoryId.phoneBattery);
    off.add(CategoryId.barometer);
    c.refresh();
    expect(periodics.single.isActive, isFalse, reason: 'no phone category on: the minute timer is cancelled');
    c.stop();
  });

  test('a phone without a barometer: status unavailable, never a made-up value, other categories unaffected',
      () async {
    final baro = FakeBarometer(fail: true), bat = FakeBattery();
    final c = make(baro: baro, battery: bat);
    await c.start();
    await settle();
    expect(c.barometerStatus, SensorStatus.unavailable);
    final ctx = await c.onPingSaved(ping('p', now));
    expect(ctx!.toJson().containsKey('pressure_hpa'), isFalse);
    expect((await ledger.samples('s1')).every((s) => s.pressureHpa == null), isTrue);
    expect((await ledger.samples('s1')).first.battPct, 64);
    c.refresh();
    expect(baro.listens, 1, reason: 'not asked again this drive');
    c.stop();
  });

  test('no barometer service at all (desktop/tests) is "unsupported"', () async {
    final c = make();
    expect(c.barometerStatus, SensorStatus.unsupported);
    await c.start();
    expect(timers, isEmpty);
    c.stop();
  });

  test('radio health samples: no coordinates, error flags kept as a bitmask, stop ends polling', () async {
    final radio = _Radio();
    final c = make(radio: radio);
    await c.start();
    await settle();
    final s = (await ledger.samples('s1')).where((x) => x.src == SampleSource.radio).single;
    final j = s.toJson();
    expect(j['batt_mv'], 3910);
    expect(j['err_flags'], RadioErrFlag.cadTimeout);
    expect(j['storage_kb'], {'used': 120, 'total': 1984});
    expect(j['mcu_temp_c'], 31.5, reason: 'radio chip temperature from its self telemetry');
    for (final k in ['lat', 'lon', 'latitude', 'longitude', 'alt_m']) {
      expect(j.containsKey(k), isFalse, reason: k);
    }
    c.stop();
    expect(c.poller, isNull);
  });

  test('a category turned on mid-drive records the snapshot from then', () async {
    off.add(CategoryId.device);
    final dev = FakeDeviceDetails();
    final c = make(device: dev);
    await c.start();
    expect(await ledger.sessionContext('s1'), isNull);
    off.remove(CategoryId.device);
    c.refresh();
    await settle();
    expect((await ledger.sessionContext('s1'))!.device!.model, 'iPhone15,2');
    c.stop();
  });

  test('medianOf', () {
    expect(medianOf([]), isNull);
    expect(medianOf([3, 1, 2]), 2);
    expect(medianOf([4, 1, 2, 3]), 2.5);
  });
}

class _FakeTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}
