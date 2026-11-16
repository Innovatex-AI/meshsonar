// The observer-engine slot (release 0.38 foundation, lib/app/observer_wiring.dart): AppState tells the engine where things
// stand and hands it only packets that passed the observer privacy filter, only while this phone is an observer.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/observer_engine.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../support/regions_559.dart';
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

Future<(Harness, FakeObserverEngine, _RxLink)> _ready({Settings? settings, void Function(Harness h)? setup}) async {
  final engine = FakeObserverEngine();
  late _RxLink link;
  final h = Harness()
    ..approveKey()
    ..observerEngineFactory = (() => engine)
    ..linkMaker = (info) => link = _RxLink(info);
  if (settings != null) h.settings.saved = settings;
  setup?.call(h);
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

  test('the region found after the radio connected, and each region change, reach the engine (MQTT topic code)', () async {
    final (h, engine, _) = await _ready(setup: (h) {
      h.location.currentFix = () => null; // no fix at launch: the region is not known when the radio connects
      h.client.regionsIndexResult = [square('AAA', 0, 0, 1, 1), square('BBB', 2, 0, 3, 1)];
    });
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the region index loads
    expect(engine.last!.regionCode, isNull);
    h.state.debugUpdateRegion(GeoFix(lat: 0.5, lon: 0.5, at: DateTime.now().toUtc()));
    expect(h.state.currentRegion?.code, 'AAA');
    expect(engine.last!.regionCode, 'AAA');
    for (var i = 0; i < 3; i++) {
      // the region tracker commits a crossing after 3 consecutive fixes (no flapping on a border)
      h.state.debugUpdateRegion(GeoFix(lat: 0.5, lon: 2.5 + i * 0.01, at: DateTime.now().toUtc()));
    }
    expect(h.state.currentRegion?.code, 'BBB');
    expect(engine.last!.regionCode, 'BBB');
  });

  test('dismissing the first-run disclosure starts the observer at once (sharing true, no link change needed)', () async {
    final tmp = Directory.systemTemp.createTempSync('obs_disclose');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final (h, engine, _) = await _ready(setup: (h) => h.uiPrefsFile = File('${tmp.path}/ui_prefs.json')..writeAsStringSync('{}'));
    expect(engine.last!.sharing, isFalse, reason: 'the disclosure has not been seen yet');
    h.state.noteCollectionDisclosed();
    expect(engine.last!.sharing, isTrue);
    expect(engine.last!.active, isTrue);
  });

  test('echoes of our own non-public ping never reach the MQTT feeds; other packets heard meanwhile are only held', () async {
    final (h, engine, link) = await _ready();
    // Not driving, so the ping does not go up publicly (_pingPublic false): its echoes are private like the ping.
    final echo = _group(10, publicChannelSecret16), other = _group(11, publicChannelSecret16);
    final echoHash = MeshPacket.tryParse(echo.raw)!.hashHex;
    h.state.debugObserverPingSent(DateTime.utc(2026, 10, 16, 18));
    link.rx.add(echo);
    link.rx.add(other);
    await Future<void>.delayed(Duration.zero);
    expect(engine.packets, isEmpty, reason: 'held while our ping is in flight (its hash is not known yet)');
    h.state.debugOnPing(DrivePing(id: 'p1', ts: DateTime.utc(2026, 10, 16, 18), lat: 40, lon: -83, pktHash: echoHash));
    expect(engine.packets, hasLength(1), reason: 'the unrelated packet is released, the echo dropped');
    expect(engine.packets.single.$1.packetHash, isNot(echoHash));
    link.rx.add(_group(10, publicChannelSecret16)); // a later repeat of the same echo
    await Future<void>.delayed(Duration.zero);
    expect(engine.packets, hasLength(1));
    h.state.dispose();
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
