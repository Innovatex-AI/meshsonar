// DriveContextReport: series, airtime / packet deltas across a reboot, error flags in words, radio temperature bands.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_context_report.dart';
import 'package:meshsonar/core/model.dart';

final t0 = DateTime.utc(2026, 10, 24, 20);

DriveSample radio(int min, {int? up, int? tx, int? rx, int? flags, double? temp, int sent = 0}) => DriveSample(
      ts: t0.add(Duration(minutes: min)),
      src: SampleSource.radio,
      uptimeS: up,
      txAirS: tx,
      rxAirS: rx,
      errFlags: flags,
      mcuTempC: temp,
      pkts: PacketCounters(recv: 10 * sent, sent: sent, floodTx: sent, directTx: 0, floodRx: 10 * sent, directRx: 0),
    );

void main() {
  test('airtime and packet deltas skip a reboot; flags are ORed', () {
    final r = DriveContextReport.compute(samples: [
      radio(0, up: 100, tx: 1, rx: 2, flags: 0, sent: 1),
      radio(1, up: 160, tx: 2, rx: 5, flags: 1, sent: 3),
      radio(2, up: 10, tx: 0, rx: 0, flags: 4, sent: 0), // rebooted
      radio(3, up: 70, tx: 1, rx: 2, sent: 2),
    ], pingContexts: const {}, pings: const []);
    expect(r.airtimePct, closeTo(100 * (4 + 3) / 120, 1e-9));
    expect(r.packetsSent, 4);
    expect(r.packetsReceived, 40);
    expect(r.errFlags, 5);
    expect(describeErrFlags(5), ['transmit queue was full', 'receive start timed out']);
    expect(describeErrFlags(1 << 9), ['flag bit 9']);
    expect(r.lastUptimeS, 70);
  });

  test('pings join the nearest radio temperature within 2 minutes; bands of 5 degrees', () {
    DrivePing ping(String id, int min, {double? noise, double? snr}) => DrivePing(
        id: id,
        ts: t0.add(Duration(minutes: min)),
        lat: 40,
        lon: -83,
        noiseFloorDbm: noise,
        echoes: [if (snr != null) Echo(repeater: 'a1', snrDb: snr)]);
    final r = DriveContextReport.compute(
      samples: [radio(0, temp: 24), radio(10, temp: 31)],
      pingContexts: const {},
      pings: [ping('a', 0, noise: -110, snr: 5), ping('b', 1, noise: -100), ping('c', 10, noise: -104, snr: -3), ping('d', 5)],
    );
    expect(r.radioTempC.map((x) => x.$2), [24, 31]);
    expect(r.tempBands.map((b) => b.fromC), [20, 30]);
    expect(r.tempBands.first.pings, 2);
    expect(r.tempBands.first.meanNoiseDbm, -105);
    expect(r.tempBands.first.meanBestSnrDb, 5);
    expect(r.tempBands.last.meanBestSnrDb, -3);
    expect(r.tempBands.fold<int>(0, (n, b) => n + b.pings), 3, reason: 'the ping 5 min from any sample is left out');
  });

  test('empty context', () {
    final r = DriveContextReport.compute(samples: const [], pingContexts: const {}, pings: const []);
    expect(r.isEmpty, isTrue);
    expect(r.tempBands, isEmpty);
  });
}
