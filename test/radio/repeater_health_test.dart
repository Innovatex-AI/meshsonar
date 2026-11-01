import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show RadioPreset;
import 'package:meshsonar/radio/repeater_health.dart';
import 'package:meshsonar/radio/repeater_settings.dart';
import 'package:meshsonar/radio/repeater_wire.dart';

const preset = RadioPreset(name: 'USA/Canada (Recommended)', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);
RepeaterStats stats({int mv = 3860, int up = 149365, int nf = -108, int recv = 1165, int errs = 193}) => RepeaterStats(
    battMilliVolts: mv, txQueueLen: 0, noiseFloorDbm: nf, lastRssiDbm: -100, packetsRecv: recv, packetsSent: 600, airTimeSecs: 1, upTimeSecs: up, recvErrors: errs);

Map<String, HealthFinding> by(List<HealthFinding> f) => {for (final x in f) x.id: x};

void main() {
  final good = {
    'radio': '910.5250244,62.5,7,5', 'tx': '22', 'flood.advert.interval': '12', 'repeat': 'on', 'flood.max': '64',
  };

  test('INNO-OB-2 as measured is healthy (clock +1 s, preset match, 6 neighbours, battery 3.86 V)', () {
    final f = by(evaluateHealth(HealthInput(
      stats: stats(),
      telemetry: const RepeaterTelemetry(voltageV: 3.86, temperatureC: 45),
      clockSkewSecs: 1,
      settings: {...good, 'tx': '28', 'flood.advert.interval': '6'},
      regionPreset: preset,
      neighbourCount: 6,
      boardLimits: const BoardLimits(28),
    )));
    expect(f.values.every((x) => x.severity.index <= Severity.info.index), isTrue, reason: f.values.map((x) => '${x.id}:${x.severity}').join(','));
    expect(f['radio-preset']!.severity, Severity.ok);
    expect(f['clock']!.severity, Severity.ok);
    expect(worst(f.values.toList()), isNot(Severity.fail));
  });

  test('clock thresholds: 60 s warn, 600 s fail; ahead vs behind gives different advice', () {
    HealthFinding c(int s) => by(evaluateHealth(HealthInput(clockSkewSecs: s)))['clock']!;
    expect(c(59).severity, Severity.ok);
    expect(c(61).severity, Severity.warn);
    expect(c(601).severity, Severity.fail);
    expect(c(-3600).fix, contains('Sync clock'));
    expect(c(3600).fix, contains('never sets its clock backwards'));
  });

  test('a different frequency fails; a different bandwidth or SF only warns; suggestions never auto-apply', () {
    HealthFinding r(String radio) => by(evaluateHealth(HealthInput(settings: {'radio': radio}, regionPreset: preset)))['radio-preset']!;
    expect(r('869.618,62.5,7,5').severity, Severity.fail);
    expect(r('910.525,125,7,5').severity, Severity.warn);
    expect(r('910.525,62.5,8,5').detail, contains('SF8'));
    expect(r('869.618,62.5,7,5').settingKey, 'radio');
  });

  test('tx power: above the board fails, 23..28 on a V4 is info, tiny warns', () {
    HealthFinding t(String v, int cap) => by(evaluateHealth(HealthInput(settings: {'tx': v}, boardLimits: BoardLimits(cap))))['tx']!;
    expect(t('30', 28).severity, Severity.fail);
    expect(t('28', 28).severity, Severity.info);
    expect(t('22', 22).severity, Severity.ok);
    expect(t('2', 22).severity, Severity.warn);
  });

  test('adverts, repeat, flood limit, neighbours', () {
    final f = by(evaluateHealth(const HealthInput(settings: {'flood.advert.interval': '0', 'repeat': 'off', 'flood.max': '2'}, neighbourCount: 0)));
    expect(f['advert']!.severity, Severity.warn);
    expect(f['repeat']!.severity, Severity.warn);
    expect(f['flood-max']!.severity, Severity.warn);
    expect(f['neighbours']!.severity, Severity.warn);
    expect(by(evaluateHealth(const HealthInput(neighbourCount: 1)))['neighbours']!.severity, Severity.info);
    expect(by(evaluateHealth(const HealthInput(settings: {'flood.advert.interval': '4'})))['advert']!.severity, Severity.info);
  });

  test('battery, restart, noise, receive errors', () {
    expect(by(evaluateHealth(HealthInput(stats: stats(mv: 3300))))['battery']!.severity, Severity.fail);
    expect(by(evaluateHealth(HealthInput(stats: stats(mv: 3500))))['battery']!.severity, Severity.warn);
    expect(by(evaluateHealth(HealthInput(stats: stats(up: 100), previousUptimeSecs: 5000)))['restart']!.severity, Severity.warn);
    expect(by(evaluateHealth(HealthInput(stats: stats(up: 100))))['restart']!.severity, Severity.info);
    expect(by(evaluateHealth(HealthInput(stats: stats(nf: -85))))['noise']!.severity, Severity.warn);
    expect(by(evaluateHealth(HealthInput(stats: stats(nf: -70))))['noise']!.severity, Severity.fail);
    expect(by(evaluateHealth(HealthInput(stats: stats(recv: 1000, errs: 500))))['rx-errors']!.severity, Severity.warn);
    expect(by(evaluateHealth(HealthInput(stats: stats())))['rx-errors'], isNull);
  });

  test('observer uplink parses the measured strings and flags a slot that is not ok', () {
    final ok = ObserverStatus.parse({
      'get mqtt.status': '> msgs: on, 1: analyzer-us (ok), 2: meshmapper (ok), 3: okimesh-1 (ok), 4: meshomatic (ok), 5: custom (ok), q:1',
      'get mqtt.stats': '> Free=134020 Max=120820 q:1/50 Outbox=0 drops=0/0 | s1=963/0',
      'get mqtt1.diag': '> mqtt1: ok, dc:76, first_disc:148510s, no errors',
      'get mqtt6.diag': '> not configured',
      'get mqtt.ntp.diag': 'pool.ntp.org ok\ntime.google.com ok',
    });
    expect(ok.slots.length, 5);
    expect(ok.slots.last.name, 'custom');
    expect(ok.queueLen, 1);
    expect(ok.disconnects, 76);
    expect(ok.ntpOk, isTrue);
    expect(by(evaluateHealth(HealthInput(observer: ok, isObserverBuild: true)))['uplink']!.severity, Severity.ok);
    final bad = ObserverStatus.parse({'get mqtt.status': '> msgs: on, 1: a (ok), 2: meshmapper (connecting), q:40', 'get mqtt.stats': 'q:40/50 drops=3/1'});
    final f = by(evaluateHealth(HealthInput(observer: bad, isObserverBuild: true)));
    expect(f['uplink']!.severity, Severity.fail);
    expect(f['uplink']!.detail, contains('meshmapper'));
    expect(f['uplink-drops'], isNotNull);
    expect(f['uplink-queue'], isNotNull);
    // not an observer build: ignored
    expect(by(evaluateHealth(HealthInput(observer: bad)))['uplink'], isNull);
    expect(ObserverStatus.parse({}).slots, isEmpty);
  });

  test('missing inputs skip their checks, never guess', () {
    expect(evaluateHealth(const HealthInput()), isEmpty);
  });

  test('worst-first ordering', () {
    final f = evaluateHealth(HealthInput(clockSkewSecs: 1, stats: stats(mv: 3300)));
    expect(f.first.severity, Severity.fail);
  });
}
