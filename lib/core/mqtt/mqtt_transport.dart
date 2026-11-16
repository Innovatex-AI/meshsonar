// One MQTT connection, behind a small interface so the slot logic is tested without sockets
// (test/core/mqtt/fake_transport.dart) and against real brokers (mosquitto, an in-process broker) with
// [MqttClientTransport]. MQTT 3.1.1 over WebSocket only (`wss`, or `ws` for a slot with TLS off), never plain tcp;
// QoS 0 packets, QoS 1 status and last will; keepalive 55 s; no auto-reconnect inside the client (the slot owns backoff).
// Pure Dart (dart:io through mqtt_client): no Flutter imports.
import 'dart:async';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

enum MqttConnectOutcome {
  /// CONNACK 0.
  accepted,

  /// CONNACK 4 (bad username or password) or 5 (not authorised).
  authRejected,

  /// Any other refusal (protocol, identifier, server unavailable).
  refused,

  /// No answer: DNS, TCP, TLS, WebSocket upgrade or timeout.
  failed,
}

class MqttConnectResult {
  final MqttConnectOutcome outcome;

  /// Plain words for the slot's last error; null when accepted.
  final String? detail;
  const MqttConnectResult(this.outcome, [this.detail]);
  bool get ok => outcome == MqttConnectOutcome.accepted;
}

class MqttConnectRequest {
  final String host;
  final int port;

  /// WebSocket path (`/`, `/mqtt`).
  final String wsPath;
  final bool tls;
  final String clientId;
  final String? username;
  final String? password;
  final int keepAliveSec;
  final Duration timeout;

  /// Last will: what the broker publishes for this client when the connection ends without a clean disconnect (the
  /// slot's `offline` status). Both null = no will. [willRetain] and the topic match the slot's online status.
  final String? willTopic;
  final String? willMessage;
  final int willQos;
  final bool willRetain;
  const MqttConnectRequest({
    required this.host,
    required this.port,
    required this.wsPath,
    required this.tls,
    required this.clientId,
    this.username,
    this.password,
    this.keepAliveSec = 55,
    this.timeout = const Duration(seconds: 10),
    this.willTopic,
    this.willMessage,
    this.willQos = 1,
    this.willRetain = false,
  });

  /// A last will is set (topic and message both present).
  bool get hasWill => willTopic != null && willTopic!.isNotEmpty && willMessage != null;

  /// `wss://host/path` (port set separately).
  String get url => '${tls ? 'wss' : 'ws'}://$host${wsPath.startsWith('/') ? wsPath : '/$wsPath'}';
}

abstract class MqttTransport {
  Future<MqttConnectResult> connect(MqttConnectRequest request);

  /// Sends one message; false when the connection is not up (the caller keeps the message queued or drops it).
  bool publish(String topic, String payload, {int qos = 0, bool retain = false});

  /// Ends the connection on purpose ([onDropped] is not called).
  Future<void> disconnect();

  /// An accepted connection ended without [disconnect] (broker gone, network lost, keepalive missed).
  set onDropped(void Function()? callback);
}

typedef MqttTransportFactory = MqttTransport Function();

/// [MqttTransport] on the `mqtt_client` package.
class MqttClientTransport implements MqttTransport {
  MqttServerClient? _c;
  bool _closing = false;
  bool _up = false;
  void Function()? _onDropped;

  @override
  set onDropped(void Function()? callback) => _onDropped = callback;

  @override
  Future<MqttConnectResult> connect(MqttConnectRequest r) async {
    await disconnect();
    _closing = false;
    final c = MqttServerClient.withPort(r.url, r.clientId, r.port)
      ..useWebSocket = true
      ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
      ..keepAlivePeriod = r.keepAliveSec
      ..connectTimeoutPeriod = r.timeout.inMilliseconds
      ..autoReconnect = false
      ..logging(on: false)
      ..setProtocolV311();
    var m = MqttConnectMessage().withClientIdentifier(r.clientId).startClean();
    if (r.hasWill) {
      m = m
          .withWillTopic(r.willTopic!)
          .withWillMessage(r.willMessage!)
          .withWillQos(r.willQos >= 1 ? MqttQos.atLeastOnce : MqttQos.atMostOnce);
      if (r.willRetain) m = m.withWillRetain();
    }
    c.connectionMessage = m;
    c.onDisconnected = () {
      final was = _up;
      _up = false;
      if (was && !_closing && identical(_c, c)) _onDropped?.call();
    };
    _c = c;
    MqttConnectReturnCode? rc;
    String? why;
    try {
      final st = await c.connect(r.username, r.password).timeout(r.timeout + const Duration(seconds: 2));
      rc = st?.returnCode;
      if (st?.state == MqttConnectionState.connected && rc == MqttConnectReturnCode.connectionAccepted) {
        _up = true;
        return const MqttConnectResult(MqttConnectOutcome.accepted);
      }
    } on TimeoutException {
      why = 'No answer from ${r.host} within ${r.timeout.inSeconds} s.';
    } catch (e) {
      rc = c.connectionStatus?.returnCode;
      why = e.toString();
    }
    _closing = true;
    try {
      c.disconnect();
    } catch (_) {}
    if (identical(_c, c)) _c = null;
    switch (rc) {
      case MqttConnectReturnCode.badUsernameOrPassword:
        return const MqttConnectResult(MqttConnectOutcome.authRejected, 'The site refused the login (bad username or password).');
      case MqttConnectReturnCode.notAuthorized:
        return const MqttConnectResult(MqttConnectOutcome.authRejected, 'The site refused the login (not authorised).');
      case MqttConnectReturnCode.unacceptedProtocolVersion:
      case MqttConnectReturnCode.identifierRejected:
      case MqttConnectReturnCode.brokerUnavailable:
        return MqttConnectResult(MqttConnectOutcome.refused, 'The site refused the connection (${rc!.name}).');
      default:
        return MqttConnectResult(MqttConnectOutcome.failed, _plain(why, r.host));
    }
  }

  static String _plain(String? why, String host) {
    if (why == null) return 'Could not connect to $host.';
    if (why.startsWith('No answer')) return why;
    final w = why.replaceFirst(RegExp(r'^[A-Za-z]*Exception:\s*'), '');
    return 'Could not connect to $host: ${w.length > 160 ? '${w.substring(0, 160)}...' : w}';
  }

  @override
  bool publish(String topic, String payload, {int qos = 0, bool retain = false}) {
    final c = _c;
    if (c == null || !_up || c.connectionStatus?.state != MqttConnectionState.connected) return false;
    try {
      final b = MqttClientPayloadBuilder()..addUTF8String(payload);
      c.publishMessage(topic, qos >= 1 ? MqttQos.atLeastOnce : MqttQos.atMostOnce, b.payload!, retain: retain);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    final c = _c;
    _c = null;
    _up = false;
    if (c == null) return;
    _closing = true;
    try {
      c.disconnect();
    } catch (_) {}
  }
}
