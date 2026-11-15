// The observer-engine slot (release 0.38 foundation, lib/app/observer_wiring.dart): AppState tells the engine where things
// stand and hands it only packets that passed the observer privacy filter, only while this phone is an observer.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/observer_engine.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

class _RxLink extends FakeLink {
  _RxLink(super.info);
  final rx = StreamController<RxPacket>.broadcast();
  @override
  Stream<RxPacket> get rxPackets => rx.stream;
}

RxPacket _group(int salt, List<int> key) => RxPacket(
    at: DateTime.utc(2026, 10, 16, 18),
    raw: MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.grpTxt),
      pathLenByte: 1,
      path: [Uint8List.fromList([0xa1])],
      payload: buildGroupTextPayload(key, 1000 + salt, 'Ann', 'words $salt'),
    ).toBytes(),
    snrDb: 5,
    rssiDbm: -90);

Future<(Harness, FakeObserverEngine, _RxLink)> _ready({Settings? settings}) async {
  final engine = FakeObserverEngine();
  late _RxLink link;
  final h = Harness()
    ..approveKey()
    ..observerEngineFactory = (() => engine)
    ..linkMaker = (info) => link = _RxLink(info);
  if (settings != null) h.settings.saved = settings;
  await h.state.init();
  expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
  return (h, engine, link);
}

void main() {
  test('after a connect the engine knows: observer on, radio connected, its key, and a signer', () async {
    final (h, engine, _) = await _ready();
    final s = engine.last!;
    expect(s.sharing, isTrue);
    expect(s.connected, isTrue);
    expect(s.active, isTrue);
    expect(s.radioPublicKey, 'abcdef0123');
    expect(s.firmware, 'v1.9.0');
    expect(s.sign, isNotNull);
    expect(s.slots, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // launch work (region index) settles before dispose
    h.state.dispose();
    expect(engine.disposed, isTrue);
  });

  test('only packets that passed the privacy filter reach the engine (Public yes, a private channel no)', () async {
    final (h, engine, link) = await _ready();
    link.rx.add(_group(1, publicChannelSecret16));
    link.rx.add(_group(2, List<int>.generate(16, (i) => 0x40 + i))); // a private channel nobody can prove
    await Future<void>.delayed(Duration.zero);
    expect(engine.packets, hasLength(1));
    expect(engine.packets.single.$1.channel, 'public');
    expect(engine.packets.single.$2.snrDb, 5);
  });

  test('sharing off: the engine is told, and gets no packet', () async {
    final (h, engine, link) = await _ready();
    await h.state.updateSettings(h.state.settings.copyWith(telemetryEnabled: false));
    expect(engine.last!.sharing, isFalse);
    link.rx.add(_group(3, publicChannelSecret16));
    await Future<void>.delayed(Duration.zero);
    expect(engine.packets, isEmpty);
  });

  test('the MQTT slots from Settings reach the engine; a disconnect says connected: false', () async {
    const slot = MqttSlotSettings(id: 'slot-1', name: 'CoreComms', host: 'mqtt.corecomms.net', wsPath: '/mqtt', enabled: true);
    final (h, engine, _) = await _ready();
    await h.state.updateSettings(h.state.settings.copyWith(mqttSlots: const [slot]));
    expect(engine.last!.slots, [slot]);
    await h.state.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(engine.last!.connected, isFalse);
    expect(engine.last!.active, isFalse);
  });

  test('without an engine factory the app runs the engine that runs nothing', () async {
    final h = Harness()..approveKey();
    await h.state.init();
    expect(h.state.observerEngine, isA<NoObserverEngine>());
    expect(h.state.observerEngine.statuses, isEmpty);
    final t = await h.state.observerEngine.test(const MqttSlotSettings(id: 's', name: 'x', host: 'h'));
    expect(t.state, ObserverFeedState.error);
  });
}
