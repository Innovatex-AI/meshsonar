// Build 78 (builder A): the Simulator's MeshSonar radio is a second, opt-in device; the stock simulated radio stays first
// and unchanged.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/simulator.dart';

void main() {
  test('stock simulator: one device, stock firmware', () async {
    final s = SimulatedRadioScanner();
    expect((await s.scan().first).map((d) => d.id), [SimulatedRadioScanner.device.id]);
    final t = await s.connect(SimulatedRadioScanner.device) as SimulatedTransport;
    expect(t.meshSonar, isFalse);
    await t.disconnect();
    expect(() => s.connect(SimulatedRadioScanner.meshSonarDevice), throwsStateError);
  });

  test('offerMeshSonar: the stock device first, then the MeshSonar radio', () async {
    final s = SimulatedRadioScanner(offerMeshSonar: true);
    expect((await s.scan().first).map((d) => d.id), [SimulatedRadioScanner.device.id, SimulatedRadioScanner.meshSonarDevice.id]);
    final stock = await s.connect(SimulatedRadioScanner.device) as SimulatedTransport;
    expect(stock.meshSonar, isFalse);
    await stock.disconnect();
    final ms = await s.connect(SimulatedRadioScanner.meshSonarDevice) as SimulatedTransport;
    expect(ms.meshSonar, isTrue);
    expect(ms.firmwareVersion, simMeshSonarFirmware);
    await ms.disconnect();
  });
}
