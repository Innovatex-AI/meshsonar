// Shared test pieces for the MQTT engine: an Ed25519 "radio" signer (RFC 8032 test key 1), packet builders, a fake
// transport that records connects and publishes, and engine state builders.
import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:meshsonar/core/mqtt/mqtt_transport.dart';
import 'package:meshsonar/core/mqtt_contract.dart';
import 'package:meshsonar/core/observer_engine.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

Uint8List hexBytes(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// RFC 8032 section 7.1, TEST 1.
const rfcSeedHex = '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const rfcPublicHex = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
const rfcEmptySigHex =
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';

/// Signs like a companion radio with the RFC 8032 test key, counting calls and optionally failing.
class TestRadioSigner {
  int calls = 0;
  Object? failWith;
  Duration delay = Duration.zero;
  cr.SimpleKeyPair? _kp;

  Future<Uint8List> sign(Uint8List data) async {
    calls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failWith != null) throw failWith!;
    _kp ??= await cr.Ed25519().newKeyPairFromSeed(hexBytes(rfcSeedHex));
    final s = await cr.Ed25519().sign(data, keyPair: _kp!);
    return Uint8List.fromList(s.bytes);
  }
}

Future<bool> verifyEd25519(List<int> msg, List<int> sig, String publicHex) => cr.Ed25519().verify(
  msg,
  signature: cr.Signature(sig, publicKey: cr.SimplePublicKey(hexBytes(publicHex), type: cr.KeyPairType.ed25519)),
);

/// Raw on-air bytes: header, transport codes for transport routes, path_len, path, payload.
Uint8List rawPacket(int type, {int route = RouteType.flood, List<int> path = const [], List<int>? payload}) {
  final pl =
      payload ?? List<int>.generate(type == PayloadType.advert ? telemetryMinAdvertPayload : 24, (i) => (i * 7 + type) & 0xff);
  final transport = route == RouteType.transportFlood || route == RouteType.transportDirect;
  return Uint8List.fromList([
    makeHeader(route, type),
    if (transport) ...[0x34, 0x12, 0x78, 0x56],
    path.length,
    ...path,
    ...pl,
  ]);
}

RxPacket rx(Uint8List raw, {double? snr = 7.25, double? rssi = -92.4, DateTime? at}) =>
    RxPacket(at: at ?? DateTime.utc(2026, 11, 15, 18, 4, 5, 123, 456), raw: raw, snrDb: snr, rssiDbm: rssi);

/// The record the observer privacy filter makes for [p] (null = filtered out). [channel]: what the group MAC proved.
TelemetryRecord? filtered(RxPacket p, {String? channel}) =>
    TelemetryRecord.fromRx(p, region: 'CMH', channelMatch: (_) => channel);

ObserverEngineState engineState({
  bool sharing = true,
  bool connected = true,
  bool foreground = true,
  String? key = rfcPublicHex,
  String? region = 'CMH',
  List<MqttSlotSettings> slots = const [],
  ObserverSigner? sign,
}) => ObserverEngineState(
  sharing: sharing,
  connected: connected,
  foreground: foreground,
  radioPublicKey: key,
  radioModel: 'Heltec V3',
  firmware: 'v1.10.0',
  regionCode: region,
  slots: slots,
  sign: sign,
);

MqttSlotSettings slot(
  String id, {
  bool enabled = true,
  MqttAuth auth = MqttAuth.jwt,
  String host = 'mqtt.example.org',
  String? iata,
  String? username,
  int ttlSec = 3600,
  String? presetId,
}) => MqttSlotSettings(
  id: id,
  name: 'Feed $id',
  host: host,
  enabled: enabled,
  auth: auth,
  iata: iata,
  username: username,
  ttlSec: ttlSec,
  presetId: presetId,
);

class Published {
  final String topic, payload;
  final int qos;
  final bool retain;
  final String clientId;
  const Published(this.topic, this.payload, this.qos, this.retain, this.clientId);
}

/// Every [FakeTransport] made by [create] reports here.
class FakeNet {
  final List<MqttConnectRequest> connects = [];
  final List<Published> published = [];
  final List<FakeTransport> live = [];
  MqttConnectResult Function(MqttConnectRequest r) answer = (_) => const MqttConnectResult(MqttConnectOutcome.accepted);
  Duration connectDelay = Duration.zero;

  MqttTransport create() => FakeTransport(this);

  List<Published> packets() => published.where((p) => p.topic.endsWith('/packets')).toList();
  List<Published> statuses() => published.where((p) => p.topic.endsWith('/status')).toList();

  /// The broker drops every connection.
  void dropAll() {
    for (final t in live.toList()) {
      t.drop();
    }
  }
}

class FakeTransport implements MqttTransport {
  final FakeNet net;
  FakeTransport(this.net);
  void Function()? _dropped;
  MqttConnectRequest? _req;
  bool up = false;

  @override
  set onDropped(void Function()? callback) => _dropped = callback;

  @override
  Future<MqttConnectResult> connect(MqttConnectRequest request) async {
    net.connects.add(request);
    if (net.connectDelay > Duration.zero) await Future<void>.delayed(net.connectDelay);
    final r = net.answer(request);
    if (r.ok) {
      up = true;
      _req = request;
      net.live.add(this);
    }
    return r;
  }

  @override
  bool publish(String topic, String payload, {int qos = 0, bool retain = false}) {
    if (!up) return false;
    net.published.add(Published(topic, payload, qos, retain, _req!.clientId));
    return true;
  }

  @override
  Future<void> disconnect() async {
    up = false;
    net.live.remove(this);
  }

  void drop() {
    if (!up) return;
    up = false;
    net.live.remove(this);
    _dropped?.call();
  }
}

/// Lets pending microtasks and zero timers run (outside fake time).
Future<void> pump([int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A completer-backed stream listener that collects status lists.
class StatusLog {
  final List<List<ObserverFeedStatus>> seen = [];
  late final StreamSubscription<List<ObserverFeedStatus>> _sub;
  StatusLog(ObserverEngine e) {
    _sub = e.statusChanges.listen(seen.add);
  }
  Future<void> cancel() => _sub.cancel();
}
