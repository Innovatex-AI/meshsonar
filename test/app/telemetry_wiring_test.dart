// AppState -> telemetry uploader: what the radio hears becomes header-only uploads, honouring the opt-out, the key and our own TX.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';

import 'package:h3_ffi/h3_ffi.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart' show DriverKeyStatus, KeyRequestResult, Settings;
import 'package:meshsonar/core/drive_end.dart';
import 'package:meshsonar/core/observer_status.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/radio/protocol.dart' show AdvType;
import 'package:meshsonar/radio/tools/advert_decode.dart' show buildAdvertPayload;
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

class _TeleClient extends FakeCmatClient implements TelemetryTransport, ObserverStatusTransport, DriveEndTransport {
  _TeleClient(super.baseUrl);
  final driveEnds = <Map<String, dynamic>>[];
  @override
  Future<int> driveEnd(String driverKey, Map<String, dynamic> body) async {
    driveEnds.add(body);
    return 200;
  }

  final bodies = <String>[];
  int deletes = 0;
  final observerCalls = <String>[];
  Map<String, dynamic> meBody = const {'observers': []};

  @override
  Future<ObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body) async {
    observerCalls.add('HEARTBEAT ${jsonEncode(body)}');
    return const ObserverHttpResult(200);
  }

  @override
  Future<ObserverHttpResult> me(String driverKey) async {
    observerCalls.add('ME');
    return ObserverHttpResult(200, body: meBody);
  }

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
      mayAutoCreateKey: b.mayAutoCreateKey,
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

H3? _loadH3() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib']) {
    if (!File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

RxPacket _advert(DateTime at, List<int> key) => RxPacket(
    at: at,
    raw: MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.advert),
      pathLenByte: 1,
      path: [Uint8List.fromList([0xb2])],
      payload: buildAdvertPayload(key, 1000, AdvType.repeater, 'Hilltop'),
    ).toBytes(),
    snrDb: 3,
    rssiDbm: -100);

Future<_H> _ready({void Function(_H h)? before}) async {
  final h = _H()..approveKey();
  before?.call(h);
  await h.state.init();
  h.state.debugHexEngine = null; // no libh3 unless a test sets it: cells only where a test asks for them
  expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
  return h;
}

void main() {
  test('radio packets go at the next flush when no own ping is in flight (P1), as telemetry v2 (Public channel: raw + channel, never plain text)', () async {
    final h = await _ready();
    h.link.rx.add(_pkt(h.now, 1));
    await Future<void>.delayed(Duration.zero);
    await h.state.flushTelemetry();
    expect(h.tele.bodies, hasLength(1), reason: 'no 90 s hold without an own ping in flight');
    expect(h.tele.bodies.single.contains('secret words'), isFalse);
    expect(h.tele.bodies.single.contains('Ann'), isFalse);
    final j = jsonDecode(h.tele.bodies.single) as Map;
    // Nov 8 2026 (phone observer O2): v2 once the observer id is loaded; a Public-channel packet carries its raw bytes
    // (anyone can read Public) with channel "public"; no cell without a fix; never coordinates.
    expect(j['format'], 'meshsonar-telemetry/2');
    expect((j['observer'] as Map)['id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect((j['observer'] as Map)['mode'], 'background');
    final pk = (j['packets'] as List).single as Map;
    expect(pk['path'], ['a1']);
    expect(pk['channel'], 'public');
    expect(pk['raw'], isA<String>());
    expect(pk.containsKey('cell'), isFalse);
    for (final k in ['lat', 'lon', 'latitude', 'longitude']) {
      expect(h.tele.bodies.single.contains('"$k"'), isFalse);
    }
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

  test('an echo of a ping we sent goes as own: true, header only when the ping is not public (section 8.1)', () async {
    final h = await _ready();
    final p = _pkt(h.now, 3);
    h.link.rx.add(p);
    await Future<void>.delayed(Duration.zero);
    final hash = TelemetryRecord.fromRx(p, shareableChannel: (_) => true)!.packetHash!;
    // The engine reports the ping afterwards, with its packet hash.
    h.state.debugOnPing(DrivePing(id: 'p1', ts: h.now, lat: 0, lon: 0, pktHash: hash));
    h.now = h.now.add(const Duration(minutes: 2));
    await h.state.flushTelemetry();
    final pk = ((jsonDecode(h.tele.bodies.single) as Map)['packets'] as List).single as Map;
    expect(pk['own'], isTrue);
    expect(pk.containsKey('raw'), isFalse, reason: 'no drive uploads it publicly (no position, no drive): header only');
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

  group('phone observer v2 (Nov 8 2026)', () {
    final h3 = _loadH3();

    Future<Map> sendOne(_H h, RxPacket p) async {
      h.link.rx.add(p);
      await Future<void>.delayed(Duration.zero);
      h.now = h.now.add(const Duration(minutes: 2));
      await h.state.flushTelemetry();
      expect(h.tele.bodies, isNotEmpty);
      return jsonDecode(h.tele.bodies.last) as Map;
    }

    test('Approximate (default): each packet carries the H3 res-7 cell of the phone, never lat/lon', () async {
      final h = await _ready(before: (h) => h.location.currentFix = () => GeoFix(lat: 39.9612, lon: -82.9988, at: h.now));
      h.state.debugHexEngine = h3;
      final j = await sendOne(h, _advert(h.now, List.filled(32, 0x11)));
      final pk = (j['packets'] as List).single as Map;
      expect(pk['cell'], matches(RegExp(r'^87[0-9a-f]{13}$')));
      expect(h3!.getResolution(BigInt.parse(pk['cell'] as String, radix: 16)), 7);
      expect(h.tele.bodies.last.contains('39.96'), isFalse);
      expect(h.tele.bodies.last.contains('-82.99'), isFalse);
      expect(pk['raw'], isA<String>(), reason: 'adverts are public: raw allowed');
      expect(pk.containsKey('channel'), isFalse);
    }, skip: h3 == null ? 'libh3 not found (brew install h3)' : false);

    test('Region only: no cell', () async {
      final h = await _ready(before: (h) => h.location.currentFix = () => GeoFix(lat: 39.9612, lon: -82.9988, at: h.now));
      h.state.debugHexEngine = h3;
      await h.state.updateSettings(h.state.settings.copyWith(telemetryRegionOnly: true));
      final j = await sendOne(h, _advert(h.now, List.filled(32, 0x12)));
      expect(((j['packets'] as List).single as Map).containsKey('cell'), isFalse);
    }, skip: h3 == null ? 'libh3 not found (brew install h3)' : false);

    test('the observer block: random id, mode, radio settings; never the radio name or public key', () async {
      final h = await _ready();
      final j = await sendOne(h, _advert(h.now, List.filled(32, 0x13)));
      final o = j['observer'] as Map;
      expect(o['id'], h.state.observerIdentity.id);
      final r = o['radio'] as Map;
      expect(r['firmware'], 'v1.9.0');
      expect(r['freq_mhz'], 910.525);
      expect(r['bw_khz'], 62.5);
      expect(r['sf'], 7);
      expect(r['cr'], 5);
      final body = h.tele.bodies.last.toLowerCase();
      expect(body.contains('truck radio'), isFalse);
      expect(body.contains('abcdef0123'), isFalse);
      expect(body.contains('secretkey'), isFalse);
    });

    test('an advert of the connected radio itself is never shared (it would carry its key and name)', () async {
      final h = _H()..approveKey();
      final own = List<int>.generate(32, (i) => i + 1);
      h.selfInfo = SelfInfo(
          publicKey: [for (final b in own) b.toRadixString(16).padLeft(2, '0')].join().toUpperCase(),
          name: 'Truck Radio',
          radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5));
      await h.state.init();
      expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
      h.link.rx.add(_advert(h.now, own));
      await Future<void>.delayed(Duration.zero);
      expect(h.state.telemetryQueued, 0);
      h.link.rx.add(_advert(h.now, List.filled(32, 0x44)));
      await Future<void>.delayed(Duration.zero);
      expect(h.state.telemetryQueued, 1);
    });

    test('no Home observer (0.38): a phone sitting still observes as background with its ~5 km cell; old home settings are ignored', () async {
      final h = await _ready(before: (h) {
        h.location.currentFix = () => GeoFix(lat: 39.9612, lon: -82.9988, at: h.now);
        // What a build 61-63 phone with Home observer on left in settings.json.
        h.settings.saved = Settings.fromJson({
          ...h.settings.saved.toJson(),
          'home_observer': {'on': true, 'lat': 39.95, 'lon': -83.01, 'location_public': 'exact'},
          'home_antenna': 'fixedMast',
        });
      });
      h.state.debugHexEngine = h3;
      expect(h.state.observerMode, ObserverMode.background);
      expect(h.state.settings.toJson().containsKey('home_observer'), isFalse, reason: 'never written again');
      expect(h.state.settings.toJson().containsKey('home_antenna'), isFalse);
      final j = await sendOne(h, _advert(h.now, List.filled(32, 0x15)));
      expect((j['observer'] as Map)['mode'], 'background');
      expect(((j['packets'] as List).single as Map)['cell'], matches(RegExp(r'^87[0-9a-f]{13}$')));
    }, skip: h3 == null ? 'libh3 not found (brew install h3)' : false);

    // P2 (Nov 10 2026), simplified in 0.38: the radio block always carries the drive antenna profile's mount.
    test('the observer radio block sends the drive antenna, also in the heartbeat', () async {
      final h = await _ready(
          before: (h) => h.settings.saved = h.settings.saved.copyWith(antennaProfiles: {
                'abcdef0123': AntennaProfile(mount: AntennaMount.insideCar, heightM: 1.2, updatedAt: DateTime.utc(2026, 11, 1)),
              }));
      final j = await sendOne(h, _advert(h.now, List.filled(32, 0x21)));
      expect((j['observer'] as Map)['mode'], 'background');
      expect(((j['observer'] as Map)['radio'] as Map)['antenna'], 'inside_car');
      final n = h.tele.observerCalls.length;
      await h.state.observerStatusService.heartbeatNow();
      final hb = h.tele.observerCalls.skip(n).firstWhere((c) => c.startsWith('HEARTBEAT '));
      final hbBody = jsonDecode(hb.substring('HEARTBEAT '.length)) as Map;
      expect(hbBody['mode'], 'background');
      expect((hbBody['radio'] as Map)['antenna'], 'inside_car');
    });

    test('an erase makes a new observer id', () async {
      final h = await _ready();
      final before = h.state.observerIdentity.id;
      expect(await h.state.eraseTelemetry(), 2);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.observerIdentity.id, isNot(before));
      expect(h.state.observerIdentity.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('GET observer/me fills this phone\'s status', () async {
      final h = await _ready();
      h.tele.meBody = {
        'observers': [
          {'id': h.state.observerIdentity.id, 'kind': 'mobile', 'packets_24h': 12}
        ]
      };
      expect(await h.state.refreshObserverStatus(), ObserverCallOutcome.ok);
      expect(h.state.observerStatusService.status!.packets24h, 12);
    });
  });

  group('observer whenever a radio is connected (observer everywhere, Nov 15 2026)', () {
    test('a fresh install makes its own driver key (ensureKey) and observes as soon as a radio connects', () async {
      final h = _H();
      h.settings.autoKeyOn = true; // the real default (Settings.autoKey = true); the test kit turns it off
      h.tele.requestResult =
          const KeyRequestResult(driverId: 'd1', key: 'ms_autokey0123456789abcdef', status: DriverKeyStatus.approved, display: 'Driver 7');
      await h.state.init();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.state.keyApproved, isTrue, reason: 'no form, no tap: every install gets a key');
      expect(h.state.settings.telemetryEnabled, isTrue, reason: 'ON by default');
      expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
      expect(h.state.observerSharing, isTrue);
      h.link.rx.add(_advert(h.now, List.filled(32, 0x41)));
      await Future<void>.delayed(Duration.zero);
      expect(h.state.telemetryQueued, 1);
    });

    test('a radio that drops by itself outside a drive asks the saved-radio auto-connect to bring it back', () async {
      final h = await _ready();
      var asked = 0;
      h.state.onRadioDropped = () => asked++;
      await h.link.rx.close(); // the link is gone (out of range, rebooted)
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(asked, 1);
    });

    test('a disconnect by the person is not a drop: nothing pulls the radio back', () async {
      final h = await _ready();
      var asked = 0;
      h.state.onRadioDropped = () => asked++;
      await h.state.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(asked, 0);
    });

    test('a drop during a drive is left to the drive\'s own reconnect loop', () async {
      final h = await _ready();
      await h.state.startDrive();
      var asked = 0;
      h.state.onRadioDropped = () => asked++;
      await h.link.rx.close();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(asked, 0);
    });

    test('the one opt-out clears the queue on the phone and stops the heartbeat', () async {
      final h = await _ready();
      h.link.rx.add(_advert(h.now, List.filled(32, 0x31)));
      await Future<void>.delayed(Duration.zero);
      expect(h.state.telemetryQueued, 1);
      expect(h.state.observerStatusService.heartbeatRunning, isTrue);
      await h.state.updateSettings(h.state.settings.copyWith(telemetryEnabled: false));
      expect(h.state.telemetryQueued, 0, reason: 'turning it off deletes what is still waiting');
      expect(h.state.observerSharing, isFalse);
      expect(h.state.observerStatusService.heartbeatRunning, isFalse);
    });
  });

  group('always-on observer, contract section 8 (Nov 9 2026)', () {
    final h3 = _loadH3();

    Future<_H> drivingReady() async {
      final h = _H()..approveKey();
      h.settings.saved = h.settings.saved.copyWith(syncEveryMin: 5);
      await h.state.init();
      h.state.debugHexEngine = h3;
      expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
      await h.state.privacyZones.setTrim(0);
      await h.state.startDrive();
      expect(h.state.driving, isTrue);
      return h;
    }

    Future<Map> flushOne(_H h) async {
      h.now = h.now.add(const Duration(minutes: 2));
      await h.state.flushTelemetry();
      return jsonDecode(h.tele.bodies.last) as Map;
    }

    test('while a drive records: mode drive, exact pos from the drive fix nearest rx_ts (<= 10 s), no cell', () async {
      final h = await drivingReady();
      expect(h.state.observerMode, ObserverMode.drive);
      h.state.debugDriveFix(GeoFix(lat: 39.961234, lon: -82.998765, accuracyM: 5, at: h.now.subtract(const Duration(seconds: 30))));
      h.state.debugDriveFix(GeoFix(lat: 39.970001, lon: -82.990002, accuracyM: 6, at: h.now.subtract(const Duration(seconds: 2))));
      h.link.rx.add(_advert(h.now, List.filled(32, 0x61)));
      await Future<void>.delayed(Duration.zero);
      final j = await flushOne(h);
      expect((j['observer'] as Map)['mode'], 'drive');
      final pk = (j['packets'] as List).single as Map;
      expect(pk['pos'], {'lat': 39.970001, 'lon': -82.990002, 'acc_m': 6.0});
      expect(pk.containsKey('cell'), isFalse);
    });

    test('P2: drive mode sends the drive antenna', () async {
      final h = _H()..approveKey();
      h.settings.saved = h.settings.saved.copyWith(antennaProfiles: {
        'abcdef0123': AntennaProfile(mount: AntennaMount.roofMagMount, heightM: 1.8, updatedAt: DateTime.utc(2026, 11, 1)),
      });
      await h.state.init();
      expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
      await h.state.privacyZones.setTrim(0);
      await h.state.startDrive();
      expect(h.state.observerMode, ObserverMode.drive);
      h.link.rx.add(_advert(h.now, List.filled(32, 0x68)));
      await Future<void>.delayed(Duration.zero);
      final j = await flushOne(h);
      expect((j['observer'] as Map)['mode'], 'drive');
      expect(((j['observer'] as Map)['radio'] as Map)['antenna'], 'roof_mag_mount');
    });

    test('no drive fix within 10 s: the cell instead (or nothing for Region only)', () async {
      final h = await drivingReady();
      h.state.debugDriveFix(GeoFix(lat: 39.96, lon: -83.0, at: h.now.subtract(const Duration(seconds: 40))));
      h.location.currentFix = () => GeoFix(lat: 39.96, lon: -83.0, at: h.now);
      h.link.rx.add(_advert(h.now, List.filled(32, 0x62)));
      await Future<void>.delayed(Duration.zero);
      final pk = ((await flushOne(h))['packets'] as List).single as Map;
      expect(pk.containsKey('pos'), isFalse);
    });

    test('drive privacy first: a fix inside a privacy zone or the start trim gives no pos', () async {
      final h = await drivingReady();
      await h.state.privacyZones.setZones([PrivacyZone.normalized(lat: 39.97, lon: -82.99, radiusM: 300)]);
      h.state.debugDriveFix(GeoFix(lat: 39.9701, lon: -82.9901, at: h.now));
      h.link.rx.add(_advert(h.now, List.filled(32, 0x63)));
      await Future<void>.delayed(Duration.zero);
      expect((((await flushOne(h))['packets'] as List).single as Map).containsKey('pos'), isFalse, reason: 'privacy zone');
      await h.state.privacyZones.setZones(const []);
      await h.state.privacyZones.setTrim(500);
      h.state.debugDriveFix(GeoFix(lat: 39.9705, lon: -82.9905, at: h.now)); // 50 m from the first (start) fix
      h.link.rx.add(_advert(h.now, List.filled(32, 0x64)));
      await Future<void>.delayed(Duration.zero);
      expect((((await flushOne(h))['packets'] as List).last as Map).containsKey('pos'), isFalse, reason: 'start trim');
    });

    test('Region only: a drive sends neither pos nor cell', () async {
      final h = await drivingReady();
      await h.state.updateSettings(h.state.settings.copyWith(telemetryRegionOnly: true));
      h.state.debugDriveFix(GeoFix(lat: 39.97, lon: -82.99, at: h.now));
      h.link.rx.add(_advert(h.now, List.filled(32, 0x65)));
      await Future<void>.delayed(Duration.zero);
      final pk = ((await flushOne(h))['packets'] as List).single as Map;
      expect(pk.containsKey('pos'), isFalse);
      expect(pk.containsKey('cell'), isFalse);
    });

    test('APP-6: a heard advert is kept and queued in drive mode with its raw bytes; a forged-short advert is not', () async {
      final h = await drivingReady();
      expect(h.state.observerMode, ObserverMode.drive);
      final short = RxPacket(
          at: h.now,
          raw: MeshPacket(header: makeHeader(RouteType.flood, PayloadType.advert), pathLenByte: 0, path: const [], payload: Uint8List(20)).toBytes(),
          snrDb: 4,
          rssiDbm: -99);
      h.link.rx.add(short);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.telemetryQueued, 0);
      final good = _advert(h.now, List.filled(32, 0x1b));
      h.link.rx.add(good);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.telemetryQueued, 1);
      final pk = ((await flushOne(h))['packets'] as List).single as Map;
      expect(pk['type'], 4);
      expect((pk['raw'] as String).length, good.raw.length * 2);
    });

    test('an echo of a public drive ping goes own: true WITH raw; inside a zone, header only', () async {
      final h = await drivingReady();
      final p1 = _advert(h.now, List.filled(32, 0x66));
      final p2 = _advert(h.now, List.filled(32, 0x67));
      h.link.rx.add(p1);
      h.link.rx.add(p2);
      await Future<void>.delayed(Duration.zero);
      final h1 = TelemetryRecord.fromRx(p1)!.packetHash!, h2 = TelemetryRecord.fromRx(p2)!.packetHash!;
      await h.state.privacyZones.setZones([PrivacyZone.normalized(lat: 40.5, lon: -83.5, radiusM: 500)]);
      h.state.debugOnPing(DrivePing(id: 'a', ts: h.now, lat: 39.97, lon: -82.99, pktHash: h1));
      h.state.debugOnPing(DrivePing(id: 'b', ts: h.now, lat: 40.5, lon: -83.5, pktHash: h2));
      final ps = [for (final p in (await flushOne(h))['packets'] as List) p as Map];
      final a = ps.firstWhere((p) => p['pkt_hash'] == h1), b = ps.firstWhere((p) => p['pkt_hash'] == h2);
      expect(a['own'], isTrue);
      expect(a['raw'], isA<String>());
      expect(b['own'], isTrue);
      expect(b.containsKey('raw'), isFalse);
    });

    test('status heartbeat for every connected phone: once at connect, with mode and radio (section 8.3)', () async {
      final h = await _ready();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final hb = h.tele.observerCalls.where((c) => c.startsWith('HEARTBEAT ')).toList();
      expect(hb, isNotEmpty);
      final body = jsonDecode(hb.first.substring('HEARTBEAT '.length)) as Map;
      expect(body['id'], h.state.observerIdentity.id);
      expect(body['mode'], 'background');
      expect((body['radio'] as Map)['sf'], 7);
      expect(h.state.observerStatusService.heartbeatRunning, isTrue);
      expect(hb, hasLength(1), reason: 'once at connect (the 5-minute timer runs only in the app wiring)');
      await h.state.updateSettings(h.state.settings.copyWith(telemetryEnabled: false));
      final n = h.tele.observerCalls.length;
      expect(await h.state.observerStatusService.heartbeatNow(), isNull, reason: 'sharing off: no heartbeat');
      expect(h.tele.observerCalls.length, n);
    });
  });

  group('drive privacy for exact positions, contract section 8.7', () {
    Future<_H> drivingReady() async {
      final h = _H()..approveKey();
      await h.state.init();
      expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
      await h.state.privacyZones.setTrim(500);
      await h.state.startDrive();
      return h;
    }

    test('stop queues drive-end: id, drive_ref = the drive id, the trimmed keep window, after the last packets', () async {
      final h = await drivingReady();
      final sid = h.state.currentSession!.id;
      final start = h.now;
      for (var i = 0; i < 30; i++) {
        h.state.debugDriveFix(GeoFix(lat: 39.9 + 0.001 * i, lon: -83.0, at: start.add(Duration(seconds: 10 * i))));
      }
      h.now = start.add(const Duration(minutes: 5));
      await h.state.stopDrive();
      final r = h.state.driveEnds.pending.single;
      expect(r.observerId, h.state.observerIdentity.id);
      expect(r.driveRef, sid);
      expect(r.keepFrom, start.add(const Duration(seconds: 50)));
      expect(r.keepUntil, start.add(const Duration(seconds: 240)));
      expect(r.hidden, isFalse);
      expect(r.notBefore.isAfter(r.endedAt), isTrue);
      // Deleting the drive on this phone before the confirmation went: nothing kept.
      await h.state.deleteSession(sid, quiet: true);
      expect(h.state.driveEnds.pending.single.toWire()['keep_from'], isNull);
      expect(h.state.driveEnds.pending.single.hidden, isTrue);
    });

    test('a drive that is not uploaded keeps nothing (drive_ref null, keep null)', () async {
      final h = await drivingReady();
      await h.state.updateSettings(h.state.settings.copyWith(autoSync: false));
      h.state.debugDriveFix(GeoFix(lat: 39.9, lon: -83.0, at: h.now));
      await h.state.stopDrive();
      final w = h.state.driveEnds.pending.single.toWire();
      expect(w['drive_ref'], isNull);
      expect(w['keep_from'], isNull);
    });

    test('regression (build 55): the end trim really runs at stop: a waiting pos near the end becomes the cell', () async {
      final h = await drivingReady();
      await h.state.privacyZones.setTrim(0); // no start trim, so the pos is sent ...
      h.state.debugDriveFix(GeoFix(lat: 39.95, lon: -83.0, at: h.now));
      h.link.rx.add(_advert(h.now, List.filled(32, 0x71)));
      await Future<void>.delayed(Duration.zero);
      await h.state.privacyZones.setTrim(500); // ... and the end trim (500 m) covers it at stop
      await h.state.stopDrive();
      h.now = h.now.add(const Duration(minutes: 2));
      await h.state.flushTelemetry();
      final pk = ((jsonDecode(h.tele.bodies.last) as Map)['packets'] as List).single as Map;
      expect(pk.containsKey('pos'), isFalse);
    });

    test('flushDriveEnds sends it once due (POST observer/drive-end)', () async {
      final h = await drivingReady();
      h.state.debugDriveFix(GeoFix(lat: 39.9, lon: -83.0, at: h.now));
      await h.state.stopDrive();
      await h.state.flushDriveEnds();
      expect(h.tele.driveEnds, isEmpty, reason: 'not yet: the last packets go first');
      h.now = h.now.add(const Duration(minutes: 4));
      await h.state.flushDriveEnds();
      expect(h.tele.driveEnds, hasLength(1));
      expect(h.state.driveEnds.pending, isEmpty);
    });
  });
}
