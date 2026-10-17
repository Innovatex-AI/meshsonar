// R MAJOR 1 (spec m1-app-0.4.0 §4): AppState itself refuses a drive with no antenna profile for the connected radio,
// for the simulator exactly as for a real radio — not only the disabled button.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

void main() {
  for (final kind in [RadioKind.bluetooth, RadioKind.simulator]) {
    test('startDrive with a ${kind.name} radio and no profile: no session, no engine, a plain message', () async {
      final h = Harness(antennaProfile: false);
      await h.state.init();
      final device = kind == RadioKind.simulator ? h.sim.devices.single : h.bt.devices.first;
      expect(await h.state.connect(device, kind), isTrue);
      expect(h.state.needsAntennaSetup, isTrue);

      await h.state.startDrive();
      expect(h.state.driving, isFalse);
      expect(h.store.sessionsById, isEmpty, reason: 'nothing is recorded without the antenna');
      expect(h.engines, isEmpty, reason: 'the radio is never asked to ping');
      expect(h.state.pendingNotice, contains('antenna'));

      await h.state.saveAntennaProfile(
          AntennaProfile(mount: AntennaMount.handheld, gainDbi: null, heightM: 1, updatedAt: DateTime.utc(2026, 10, 17)));
      await h.state.startDrive();
      expect(h.state.driving, isTrue);
      expect(h.store.sessionsById.values.single.antenna.toJson(), {'type': 'internal', 'gain_dbi': null, 'height_m': 1});
      await h.state.stopDrive();
    });
  }

  test('a different radio needs its own profile: switching radios re-arms the gate', () async {
    final h = Harness(); // the default radio abcdef0123 has a profile
    await h.state.init();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    expect(h.state.needsAntennaSetup, isFalse);
    await h.state.disconnect();
    h.selfInfo = SelfInfo(publicKey: 'FFEE000111', name: 'Mast Radio', radio: h.selfInfo.radio, firmware: 'v1.9.0');
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    expect(h.state.needsAntennaSetup, isTrue);
    await h.state.startDrive();
    expect(h.state.driving, isFalse);
  });
}
