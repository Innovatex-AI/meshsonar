// The engine against real brokers over real WebSockets (mqtt_client):
//   * an in-process broker that checks logins like the MeshCore reference broker (radio-signed JWT, uppercase-hex
//     signature, audience, topic key = login key): always runs;
//   * a local mosquitto 2 in Docker (colima on Andy's Mac): anonymous and password listeners, a subscriber that reads
//     what the phone published, a broker restart. Skipped (with the reason printed) when Docker is not available.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/mqtt/mqtt_engine.dart';
import 'package:meshsonar/core/mqtt_contract.dart';
import 'package:meshsonar/core/observer_engine.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'support.dart';
import 'support_broker.dart';

Future<void> _until(bool Function() ok, {Duration within = const Duration(seconds: 15), String? what}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

MqttSlotSettings _local(String id, int port, {MqttAuth auth = MqttAuth.jwt, String? aud, String? username, int ttlSec = 3600}) =>
    MqttSlotSettings(
      id: id,
      name: 'Local $id',
      host: '127.0.0.1',
      port: port,
      tls: false,
      aud: aud,
      auth: auth,
      username: username,
      ttlSec: ttlSec,
      enabled: true,
    );

void _feed(ObserverEngine e, int i, {int type = PayloadType.advert}) {
  final p = rx(rawPacket(type, payload: List<int>.generate(101, (k) => (k * 3 + i) & 0xff)), at: DateTime.now().toUtc());
  final rec = filtered(p); // a private type is filtered out here, as in the app
  if (rec != null) e.onPublicPacket(rec, p);
}

void main() {
  group('in-process broker with reference login checks', () {
    late JwtBroker broker;
    late MqttObserverEngine engine;
    late TestRadioSigner radio;

    setUp(() async {
      broker = JwtBroker(audience: 'mqtt.test.meshsonar');
      await broker.start();
      radio = TestRadioSigner();
      engine = MqttObserverEngine(secrets: InMemorySecretStore(), clock: () => DateTime.now().toUtc());
    });

    tearDown(() async {
      await engine.dispose();
      await broker.stop();
    });

    test('radio-signed JWT login is accepted; status then packets arrive under meshcore/CMH/<KEY>/', () async {
      engine.update(
        engineState(
          slots: [_local('s1', broker.port, aud: 'mqtt.test.meshsonar')],
          sign: radio.sign,
        ),
      );
      await _until(() => engine.statuses.single.state == ObserverFeedState.connected, what: 'connected');
      expect(broker.rejected, isEmpty);
      _feed(engine, 1);
      _feed(engine, 2, type: PayloadType.txtMsg); // filtered before the engine: never arrives
      await _until(() => broker.messages.any((m) => m.topic.endsWith('/packets')), what: 'packet');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final key = rfcPublicHex.toUpperCase();
      final status = broker.messages.firstWhere((m) => m.topic.endsWith('/status'));
      expect(status.topic, 'meshcore/CMH/$key/status');
      expect(status.qos, 1);
      final packets = broker.messages.where((m) => m.topic.endsWith('/packets')).toList();
      expect(packets, hasLength(1));
      expect(packets.single.topic, 'meshcore/CMH/$key/packets');
      expect(packets.single.qos, 0);
      final j = jsonDecode(packets.single.payload) as Map<String, dynamic>;
      expect(j['origin_id'], key);
      expect(j['packet_type'], '4');
      expect(j['type'], 'PACKET');
      await _until(() => engine.statuses.single.sent24h == 1, within: const Duration(seconds: 3), what: 'count');
    });

    test('wrong audience is refused: Auth failed', () async {
      engine.update(
        engineState(
          slots: [_local('s1', broker.port, aud: 'someone.else')],
          sign: radio.sign,
        ),
      );
      await _until(() => engine.statuses.single.state == ObserverFeedState.authFailed, what: 'auth failed');
      expect(broker.rejected, contains('aud'));
      expect(engine.statuses.single.lastError, contains('refused the login'));
    });

    test('the broker drops the link: the engine reconnects and keeps publishing', () async {
      engine.update(
        engineState(
          slots: [_local('s1', broker.port, aud: 'mqtt.test.meshsonar')],
          sign: radio.sign,
        ),
      );
      await _until(() => engine.statuses.single.state == ObserverFeedState.connected, what: 'connected');
      await broker.dropAll();
      await _until(() => broker.connectedClients.length == 2, what: 'reconnect');
      await _until(() => engine.statuses.single.state == ObserverFeedState.connected, what: 'connected again');
      _feed(engine, 5);
      await _until(() => broker.messages.any((m) => m.topic.endsWith('/packets')), what: 'packet after reconnect');
      expect(radio.calls, 1);
    });

    test('token refresh: a short-lived token is re-signed before it ends and the broker accepts the new one', () async {
      // ttl 62 s: re-signed 60 s before the end, i.e. about 2 s after connecting.
      engine.update(
        engineState(
          slots: [_local('s1', broker.port, aud: 'mqtt.test.meshsonar', ttlSec: 62)],
          sign: radio.sign,
        ),
      );
      await _until(() => broker.passwords.length >= 2, within: const Duration(seconds: 10), what: 'second login');
      expect(broker.passwords[0], isNot(broker.passwords[1]));
      expect(radio.calls, greaterThanOrEqualTo(2));
      expect(broker.rejected, isEmpty);
      await _until(() => engine.statuses.single.state == ObserverFeedState.connected, what: 'connected after refresh');
    });

    test('Test publishes one status message and nothing else', () async {
      engine.update(engineState(sign: radio.sign));
      final r = await engine.test(_local('t', broker.port, aud: 'mqtt.test.meshsonar'));
      expect(r.state, ObserverFeedState.connected, reason: r.lastError);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(broker.messages, hasLength(1));
      expect(broker.messages.single.topic, endsWith('/status'));
      expect(broker.messages.single.retain, isFalse);
    });

    test('nothing listening: Error with plain words, then backoff', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final dead = s.port;
      await s.close();
      engine.update(engineState(slots: [_local('s1', dead, auth: MqttAuth.none)]));
      await _until(() => engine.statuses.single.state == ObserverFeedState.error, what: 'error');
      expect(engine.statuses.single.lastError, startsWith('Could not connect to 127.0.0.1'));
    });
  });

  group('local mosquitto (Docker)', () {
    String? skip;
    String? container;
    late int anonPort, pwPort;

    Future<int> freePort() async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final p = s.port;
      await s.close();
      return p;
    }

    Future<MqttServerClient?> subscriber(int port, {String? user, String? pass}) async {
      final c = MqttServerClient.withPort('ws://127.0.0.1/', 'sub${DateTime.now().microsecondsSinceEpoch % 100000}', port)
        ..useWebSocket = true
        ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
        ..logging(on: false)
        ..setProtocolV311()
        ..keepAlivePeriod = 30;
      try {
        await c.connect(user, pass);
      } catch (_) {
        return null;
      }
      return c.connectionStatus?.state == MqttConnectionState.connected ? c : null;
    }

    setUpAll(() async {
      ProcessResult info;
      try {
        info = await Process.run('docker', ['info', '--format', '{{.ServerVersion}}']);
      } catch (e) {
        skip = 'Docker is not installed ($e)';
        return;
      }
      if (info.exitCode != 0) {
        skip = 'Docker is not running: ${info.stderr}';
        return;
      }
      anonPort = await freePort();
      pwPort = await freePort();
      container = 'ms-a2-mosquitto-$pid';
      const conf =
          'per_listener_settings true\\n'
          'listener 9001\\nprotocol websockets\\nallow_anonymous true\\n'
          'listener 9002\\nprotocol websockets\\nallow_anonymous false\\npassword_file /mosquitto/config/pw\\n';
      final run = await Process.run('docker', [
        'run', '-d', '--rm', '--name', container!, //
        '-p', '127.0.0.1:$anonPort:9001', '-p', '127.0.0.1:$pwPort:9002',
        'eclipse-mosquitto:2.0.20', 'sh', '-c',
        "printf '$conf' > /mosquitto/config/m.conf && mosquitto_passwd -b -c /mosquitto/config/pw andy s3cret && "
            'chown mosquitto:mosquitto /mosquitto/config/pw && chmod 0700 /mosquitto/config/pw && exec mosquitto -c /mosquitto/config/m.conf',
      ]);
      if (run.exitCode != 0) {
        skip = 'Could not start eclipse-mosquitto:2.0.20: ${run.stderr}';
        container = null;
        return;
      }
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(end)) {
        final c = await subscriber(anonPort);
        if (c != null) {
          c.disconnect();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      skip = 'mosquitto did not come up';
    });

    tearDownAll(() async {
      if (container != null) await Process.run('docker', ['rm', '-f', container!]);
    });

    test('JWT slot publishes status and packets a subscriber receives; survives a broker restart', () async {
      if (skip != null) {
        markTestSkipped(skip!);
        // ignore: avoid_print
        print('SKIPPED mosquitto integration: $skip');
        return;
      }
      final sub = (await subscriber(anonPort))!;
      final got = <String, String>{};
      sub.subscribe('meshcore/#', MqttQos.atMostOnce);
      sub.updates!.listen((events) {
        for (final ev in events) {
          final m = ev.payload as MqttPublishMessage;
          got['${ev.topic}#${got.length}'] = MqttPublishPayload.bytesToStringAsString(m.payload.message);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final radio = TestRadioSigner();
      final engine = MqttObserverEngine(secrets: InMemorySecretStore(), clock: () => DateTime.now().toUtc());
      addTearDown(engine.dispose);
      engine.update(
        engineState(
          slots: [_local('s1', anonPort, aud: '127.0.0.1')],
          sign: radio.sign,
        ),
      );
      await _until(() => engine.statuses.single.state == ObserverFeedState.connected, what: 'connected');
      _feed(engine, 1);
      _feed(engine, 2, type: PayloadType.anonReq); // private: dropped by the filter
      final key = rfcPublicHex.toUpperCase();
      await _until(() => got.keys.any((k) => k.startsWith('meshcore/CMH/$key/packets')), what: 'packet at subscriber');
      expect(got.keys.any((k) => k.startsWith('meshcore/CMH/$key/status')), isTrue);
      final pkt = jsonDecode(got.entries.firstWhere((e) => e.key.contains('/packets')).value) as Map;
      expect(pkt['packet_type'], '4');
      expect(pkt['origin_id'], key);
      sub.disconnect();

      // Broker restart: the slot comes back by itself.
      final restart = await Process.run('docker', ['restart', '-t', '0', container!]);
      expect(restart.exitCode, 0, reason: '${restart.stderr}');
      await _until(
        () => engine.statuses.single.state != ObserverFeedState.connected,
        within: const Duration(seconds: 10),
        what: 'drop seen',
      );
      await _until(
        () => engine.statuses.single.state == ObserverFeedState.connected,
        within: const Duration(seconds: 45),
        what: 'reconnected',
      );
      final sub2 = (await subscriber(anonPort))!;
      var after = 0;
      sub2.subscribe('meshcore/+/$key/packets', MqttQos.atMostOnce);
      sub2.updates!.listen((events) => after += events.length);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _feed(engine, 3);
      await _until(() => after == 1, what: 'packet after restart');
      sub2.disconnect();
    });

    test('password slot: the Keychain password logs in; a wrong one is Auth failed', () async {
      if (skip != null) {
        markTestSkipped(skip!);
        return;
      }
      final secrets = InMemorySecretStore();
      await secrets.write('mqtt.pw', utf8.encode('s3cret'));
      await secrets.write('mqtt.bad', utf8.encode('nope'));
      final engine = MqttObserverEngine(secrets: secrets, clock: () => DateTime.now().toUtc());
      addTearDown(engine.dispose);
      final sub = (await subscriber(pwPort, user: 'andy', pass: 's3cret'))!;
      var n = 0;
      sub.subscribe('meshcore/#', MqttQos.atMostOnce);
      sub.updates!.listen((events) => n += events.where((e) => e.topic.endsWith('/packets')).length);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      engine.update(
        engineState(
          slots: [
            _local('pw', pwPort, auth: MqttAuth.password, username: 'andy'),
            _local('bad', pwPort, auth: MqttAuth.password, username: 'andy'),
          ],
        ),
      );
      await _until(
        () => engine.statuses[0].state == ObserverFeedState.connected && engine.statuses[1].state == ObserverFeedState.authFailed,
        what: 'pw connected, bad refused',
      );
      _feed(engine, 7);
      await _until(() => n == 1, what: 'packet via password slot');
      sub.disconnect();
    });
  });
}
