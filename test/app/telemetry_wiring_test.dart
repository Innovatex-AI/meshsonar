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

RxPacket _pkt(DateTime at, int salt) => RxPacket(
    at: at, raw: Uint8List.fromList([0x15, 0x01, 0xA1, 0xDE, 0xAD, 0xBE, 0xEF, salt]), snrDb: 5, rssiDbm: -90);

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
    expect(h.tele.bodies.single.toLowerCase().contains('deadbeef'), isFalse);
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
    final hash = TelemetryRecord.fromRx(p)!.packetHash!;
    // The engine reports the ping afterwards, with its packet hash.
    h.state.debugOnPing(DrivePing(id: 'p1', ts: h.now, lat: 0, lon: 0, pktHash: hash));
    h.now = h.now.add(const Duration(minutes: 2));
    await h.state.flushTelemetry();
    expect(h.tele.bodies, isEmpty);
  });

  test('erase calls DELETE on the server', () async {
    final h = await _ready();
    expect(await h.state.eraseTelemetry(), 2);
    expect(h.tele.deletes, 1);
  });
}
