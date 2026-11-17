// Battery plan A6: the observer-feedback poll (it only feeds the Drive screen) is skipped while the app is behind and
// asked once on return.
// ignore_for_file: overridden_fields
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/app_foreground.dart';

import '../ui/fakes.dart';

class _StatusClient extends FakeCmatClient {
  _StatusClient(super.baseUrl);
  int asks = 0;
  @override
  Future<List<PingObservation>> driveStatus(String driverKey, String sessionId) async {
    asks++;
    return const [];
  }
}

class _Harness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => _StatusClient(u);
}

const _tick = Duration(milliseconds: 40);

void main() {
  tearDown(AppForeground.debugReset);

  test('observer feedback: polled in front, skipped behind, one ask on return', () async {
    final h = _Harness();
    h.settings.saved = const Settings().copyWith(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved);
    h.state.observerPollEvery = _tick;
    await h.state.init();
    expect(await h.state.connectSimulator(), isTrue);
    await h.state.startDrive();
    expect(h.state.driving, isTrue);
    final c = h.client as _StatusClient;
    await Future<void>.delayed(_tick * 4);
    expect(c.asks, greaterThanOrEqualTo(2), reason: 'in front: every period');

    h.state.debugOnBackground();
    expect(AppForeground.inForeground, isFalse);
    await Future<void>.delayed(_tick ~/ 2);
    final behind = c.asks;
    await Future<void>.delayed(_tick * 5);
    expect(c.asks, behind, reason: 'behind: the poll is skipped');

    h.state.debugOnForeground(); // the ask starts synchronously, before any timer can fire
    expect(c.asks, behind + 1, reason: 'one ask on return');
    await h.state.stopDrive();
  });
}
