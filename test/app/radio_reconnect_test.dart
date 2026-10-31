// A radio that drops mid-drive is reconnected and the SAME drive carries on (ROADMAP P1 "Radio drop mid-drive").
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

Future<void> settle([int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Harness> drivingHarness() async {
  final h = Harness();
  await h.state.init();
  h.state.reconnectDelay = (_) => Duration.zero;
  expect(await h.state.connectSimulator(), isTrue);
  await h.state.startDrive();
  expect(h.state.driving, isTrue);
  return h;
}

void dropRadio(Harness h) {
  h.links.last.drop();
  h.engines.last.setStatus(const EngineStatus(EngineState.error, message: 'Radio disconnected'));
}

void main() {
  test('a dropped radio is reconnected and the engine resumes on the new link in the same session', () async {
    final h = await drivingHarness();
    final sid = h.state.currentSession!.id;
    h.engines.last.emit(heardPing('p1', const [Echo(repeater: 'a1', snrDb: 5, hops: 1)]));
    await settle();
    dropRadio(h);
    await settle();
    expect(h.engines.last.resumedOn, hasLength(1));
    expect(identical(h.engines.last.resumedOn.single, h.links.last), isTrue);
    expect(h.links, hasLength(2), reason: 'a fresh link was opened for the reconnect');
    expect(h.state.currentSession!.id, sid, reason: 'same drive, never a new session');
    expect(h.state.driving, isTrue);
    expect(h.state.reconnecting, isFalse);
    expect(h.state.connected, isTrue);
    expect(h.store.sessionsById, hasLength(1));
    // Pings after the resume still land in the same drive.
    h.engines.last.emit(heardPing('p2', const []));
    await settle();
    expect(h.store.pingsBySession[sid]!.map((p) => p.id), ['p1', 'p2']);
    expect(h.state.takeNotice(), contains('reconnected'));
  });

  test('a failed reconnect keeps trying with a plain-language reason until the radio is back', () async {
    final h = await drivingHarness();
    h.sim.connectError = StateError('Bluetooth adapter is turned off');
    dropRadio(h);
    await settle(30);
    expect(h.state.reconnecting, isTrue);
    expect(h.state.reconnectAttempt, greaterThan(1));
    expect(h.state.reconnectProblem, contains('Bluetooth is off'));
    expect(h.state.statusLine, contains('Bluetooth is off'));
    expect(h.state.driving, isTrue, reason: 'the drive stays open while the radio is away');
    h.sim.connectError = null; // Bluetooth is back on
    await settle(30);
    expect(h.state.reconnecting, isFalse);
    expect(h.engines.last.resumedOn, hasLength(1));
  });

  test('stopping the drive ends the reconnect loop', () async {
    final h = await drivingHarness();
    h.sim.connectError = StateError('nope');
    dropRadio(h);
    await settle(10);
    expect(h.state.reconnecting, isTrue);
    await h.state.stopDrive();
    await settle(20);
    expect(h.state.reconnecting, isFalse);
    expect(h.state.driving, isFalse);
    final tries = h.sim.connects;
    await settle(20);
    expect(h.sim.connects, tries, reason: 'no more tries once the drive is stopped');
  });

  test('an engine that cannot rejoin the channel leaves the loop trying again', () async {
    final h = await drivingHarness();
    h.engines.last.resumeError = StateError('channel full');
    dropRadio(h);
    await settle(20);
    expect(h.state.reconnecting, isTrue);
    h.engines.last.resumeError = null;
    await settle(20);
    expect(h.state.reconnecting, isFalse);
    expect(h.engines.last.resumedOn, isNotEmpty);
  });

  test('reconnectProblemText maps the common causes', () {
    expect(AppState.reconnectProblemText(StateError('Bluetooth must be turned on')), contains('Bluetooth is off'));
    expect(AppState.reconnectProblemText(StateError('permission denied')), contains('permission'));
    expect(AppState.reconnectProblemText(StateError('x')), contains('Trying again'));
  });
}
