// AppState pushes changed auto-ping settings into the running engine (no restart of the drive).
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';

import '../ui/fakes.dart';

void main() {
  test('changing interval/distance while driving updates the running engine; not when idle', () async {
    final h = Harness();
    await h.state.init();
    await h.state.updateSettings(h.state.settings.copyWith(intervalSec: 60));
    expect(h.engines, isEmpty, reason: 'no drive yet: nothing to update');

    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    final engine = h.engines.single;
    expect(engine.config!.intervalSec, 60);

    await h.state.updateSettings(h.state.settings.copyWith(intervalSec: 20, minDistanceM: 250));
    expect(engine.updates, hasLength(1));
    expect(engine.updates.single.intervalSec, 20);
    expect(engine.updates.single.minDistanceM, 250);
    expect(engine.updates.single.txPowerW, closeTo(0.158, 0.001), reason: '22 dBm');

    await h.state.stopDrive();
    await h.state.updateSettings(h.state.settings.copyWith(intervalSec: 90));
    expect(engine.updates, hasLength(1));
  });
}
