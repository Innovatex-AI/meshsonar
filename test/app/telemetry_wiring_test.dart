// AppState -> telemetry uploader: what the radio hears becomes header-only uploads, honouring the opt-out, the key and our own TX.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

class _TeleClient extends FakeCmatClient implements TelemetryTransport {
  _TeleClient(super.baseUrl);
  final bodies = <String>[];
  int deletes = 0;
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) async {
    bodies.add(utf8.decode(body));
    return const TelemetryHttpResult(200, body: {'stored': 1});
  }

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) async {
    deletes++;
    return const TelemetryHttpResult(200, body: {'deleted': 2});
  }
}

class _RxLink extends FakeLink {
  _RxLink(super.info);
  final rx = StreamController<RxPacket>.broadcast();
  @override
  Stream<RxPacket> get rxPackets => rx.stream;
}

class _H extends Harness {
  DateTime now = DateTime.utc(2026, 10, 16, 18);
  late final _RxLink link = _RxLink(selfInfo);
  @override
  FakeCmatClient newClient(Uri u) => _TeleClient(u);
  @override
  AppServices buildServices() {
    final b = super.buildServices();
    return AppServices(
      store: b.store,
      settingsStore: b.settingsStore,
      cmatClientFactory: b.cmatClientFactory,
      syncServiceFactory: b.syncServiceFactory,
      bluetoothScanner: b.bluetoothScanner,
      simulatorScanner: b.simulatorScanner,
      linkFactory: (_) => link,
      location: b.location,
      simulatedLocation: b.simulatedLocation,
      engineFactory: b.engineFactory,
      repeaterCache: b.repeaterCache,
      exportDir: b.exportDir,
      shareFile: b.shareFile,
      newId: b.newId,
      clock: () => now,
      regionIndexCache: b.regionIndexCache,
    );
  }

  _TeleClient get tele => state.client as _TeleClient;
}

/// A real flood group text, one hop (a1), encrypted with [key] (default: the well-known Public channel).
RxPacket _pkt(DateTime at, int salt, {List<int>? key}) => RxPacket(
    at: at,
    raw: MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.grpTxt),
      pathLenByte: 1,
      path: [Uint8List.fromList([0xa1])],
      payload: buildGroupTextPayload(key ?? publicChannelSecret16, 1000 + salt, 'Ann', 'secret words $salt'),
    ).toBytes(),
    snrDb: 5,
    rssiDbm: -90);

Future<_H> _ready() async {
  final h = _H()..approveKey();
  await h.state.init();
  expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
  return h;
}

void main() {
  test('radio packets are uploaded as headers only, after the hold', () async {
    final h = await _ready();
    h.link.rx.add(_pkt(h.now, 1));
    await Future<void>.delayed(Duration.zero);
    await h.state.flushTelemetry();
    expect(h.tele.bodies, isEmpty, reason: 'held so our own echoes can be recognised');
    h.now = h.now.add(const Duration(minutes: 2));
    await h.state.flushTelemetry();
    expect(h.tele.bodies, hasLength(1));
    expect(h.tele.bodies.single.contains('secret words'), isFalse);
    expect(h.tele.bodies.single.contains('Ann'), isFalse);
    final j = jsonDecode(h.tele.bodies.single) as Map;
    expect(j['format'], 'meshsonar-telemetry/1');
    expect((j['packets'] as List).single['path'], ['a1']);
  });

  test('the Settings opt-out stops collection and discards what is queued', () async {
    final h = await _ready();
    h.link.rx.add(_pkt(h.now, 1));
    await Future<void>.delayed(Duration.zero);
    await h.state.updateSettings(h.state.settings.copyWith(telemetryEnabled: false));
    h.link.rx.add(_pkt(h.now, 2));
    await Future<void>.delayed(Duration.zero);
    h.now = h.now.add(const Duration(minutes: 2));
    await h.state.flushTelemetry();
    expect(h.tele.bodies, isEmpty);
  });

  test('a ping we sent is never uploaded', () async {
    final h = await _ready();
    final p = _pkt(h.now, 3);
    h.link.rx.add(p);
    await Future<void>.delayed(Duration.zero);
    final hash = TelemetryRecord.fromRx(p, shareableChannel: (_) => true)!.packetHash!;
    // The engine reports the ping afterwards, with its packet hash.
    h.state.debugOnPing(DrivePing(id: 'p1', ts: h.now, lat: 0, lon: 0, pktHash: hash));
    h.now = h.now.add(const Duration(minutes: 2));
    await h.state.flushTelemetry();
    expect(h.tele.bodies, isEmpty);
  });

  test('a private channel packet is never uploaded (Nov 8 fix: the disclosure promised it, the app recorded it)', () async {
    final h = await _ready();
    h.link.rx.add(_pkt(h.now, 4, key: List.generate(16, (i) => 200 - i)));
    await Future<void>.delayed(Duration.zero);
    h.now = h.now.add(const Duration(minutes: 2));
    await h.state.flushTelemetry();
    expect(h.tele.bodies, isEmpty);
    expect(h.state.telemetryQueued, 0);
  });

  test('a # channel packet is shared only when this phone holds that channel', () async {
    final h = await _ready();
    final cmh = hashtagSecret16('#cmh');
    h.link.rx.add(_pkt(h.now, 5, key: cmh));
    await Future<void>.delayed(Duration.zero);
    expect(h.state.telemetryQueued, 0, reason: 'unknown channel: it could be private');
    h.state.hashtagChannelKeys = () => [cmh];
    h.link.rx.add(_pkt(h.now, 6, key: cmh));
    await Future<void>.delayed(Duration.zero);
    expect(h.state.telemetryQueued, 1);
  });

  test('erase calls DELETE on the server', () async {
    final h = await _ready();
    expect(await h.state.eraseTelemetry(), 2);
    expect(h.tele.deletes, 1);
  });
}
