// WP8: the telemetry decode surface behind the Stats sheet: LPP fixtures (battery only, battery + location, env sensors),
// withheld wording, history series for the sparkline, and the queued request (noReply on silence, background dropped when busy).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/tools/lpp.dart';
import 'package:meshsonar/radio/tools/telemetry_tool.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';

import '../../support/tools_rig.dart';

TelemetryResult resultOf(List<int> lpp, {String who = 'Maya Chen'}) {
  final readings = decodeLpp(Uint8List.fromList(lpp));
  return TelemetryResult(readings.isEmpty ? TelemetryStatus.empty : TelemetryStatus.ok, who, DateTime(2026, 11, 2), readings: readings);
}

RadioContact person() => RadioContact(publicKeyHex: 'ab' * 32, type: AdvType.chat, outPath: Uint8List(0), name: 'Maya Chen');

void main() {
  group('summary and withheld wording', () {
    test('battery only: shared battery, location and sensors named as not shared', () {
      final s = resultOf(lppVoltage(3.92)).summary();
      expect(s.battery!.value, closeTo(3.92, 1e-9));
      expect(s.position, isNull);
      expect(s.environment, isEmpty);
      expect(s.withheld, ["Maya's radio doesn't share location.", "Maya's radio doesn't share sensor readings."]);
    });

    test('battery + location: only sensors withheld; position decoded', () {
      final s = resultOf([...lppVoltage(3.92), ...lppGps(39.9612, -82.9988, 250)]).summary();
      expect(s.position!.lat, closeTo(39.9612, 1e-4));
      expect(s.position!.lon, closeTo(-82.9988, 1e-4));
      expect(s.withheld, ["Maya's radio doesn't share sensor readings."]);
    });

    test('env sensors: temperature and humidity grouped, nothing about them withheld', () {
      final s = resultOf([...lppVoltage(3.7), ...lppTemperature(18.5), ...lppHumidity(41, ch: 2), ...lppGps(1, 2, 3)]).summary();
      expect(s.environment.map((e) => e.kind), [LppKind.temperature, LppKind.humidity]);
      expect(s.environment.first.text, '18.5 °C');
      expect(s.environment.last.text, '41.0 %');
      expect(s.withheld, isEmpty);
    });

    test('position only: battery is named as withheld', () {
      final s = resultOf(lppGps(1, 2, 3)).summary();
      expect(s.withheld, contains("Maya's radio doesn't share battery."));
    });

    test('a non-person never gets withheld sentences', () {
      final s = TelemetrySummary.of(resultOf(lppVoltage(3.9)), person: false);
      expect(s.withheld, isEmpty);
    });

    test('empty answer is empty', () {
      expect(resultOf(const []).status, TelemetryStatus.empty);
    });
  });

  test('distanceKm: Columbus to Dayton is about 105 km; same point is 0', () {
    expect(distanceKm(39.9612, -82.9988, 39.7589, -84.1916), closeTo(105, 8));
    expect(distanceKm(1, 2, 1, 2), 0);
  });

  test('seriesOf collects one reading across answers, oldest first, skipping failures', () {
    final h = [resultOf(lppTemperature(10)), resultOf(lppTemperature(12)), TelemetryResult(TelemetryStatus.silent, 'x', DateTime(2026)), resultOf(lppTemperature(11))];
    expect(seriesOf(h, LppKind.temperature), [10, 12, 11]);
    expect(seriesOf(h, LppKind.humidity), isEmpty);
  });

  group('queued request', () {
    late FakeToolsRadio radio;
    late RemoteRequestQueue q;
    late TelemetryTool t;
    setUp(() {
      radio = FakeToolsRadio();
      q = RemoteRequestQueue();
      t = TelemetryTool(radio, testArbiter(),
          waitSlack: Duration.zero, minWait: Duration.zero, maxWait: const Duration(milliseconds: 150), minGap: Duration.zero)
        ..queue = q;
    });

    test('answer: result returned, kept as latest, history grows for the sparkline', () async {
      var n = 0;
      radio.onSend = (f) {
        scheduleMicrotask(() => radio.push(encodeTelemetryResponsePush(Uint8List.fromList(List.filled(6, 0xab)), lppTemperature(20.0 + n++))));
        return const SentFrame(flood: false, tag: 1, estTimeoutMs: 100);
      };
      final c = person();
      for (var i = 0; i < 3; i++) {
        final r = await t.requestContactQueued(c);
        expect(r.ok, isTrue, reason: r.detail);
      }
      expect(t.latest[c.publicKeyHex]!.ok, isTrue);
      expect(seriesOf(t.historyFor(c.publicKeyHex), LppKind.temperature), [20, 21, 22]);
      expect(radio.sent.every((s) => s.frame[0] == Cmd.sendTelemetryReq), isTrue);
    });

    test('silence: result is silent and the queue entry ended as noReply, slot released', () async {
      radio.onSend = (f) => const SentFrame(flood: false, tag: 1, estTimeoutMs: 50);
      final seen = <RemoteState>[];
      q.requests.changes.listen((l) => seen.addAll(l.map((r) => r.state)));
      final r = await t.requestContactQueued(person());
      expect(r.status, TelemetryStatus.silent);
      expect(q.busy, isFalse);
      expect(t.historyFor(person().publicKeyHex), isEmpty);
    });

    test('background refresh is dropped when the queue is busy; a user tap waits its turn', () async {
      final gate = Completer<void>();
      final other = q.enqueue<void>(kind: RemoteKind.status, target: 'rep', run: (_) => gate.future);
      final bg = await t.requestContactQueued(person(), background: true);
      expect(bg.status, TelemetryStatus.tooSoon);
      expect(bg.detail, contains('busy'));
      gate.complete();
      await other.result;
    });

    test('without a queue the request runs directly', () async {
      t.queue = null;
      radio.onSend = (f) => const SentFrame(flood: false, tag: 1, estTimeoutMs: 50);
      expect((await t.requestContactQueued(person())).status, TelemetryStatus.silent);
    });
  });
}
