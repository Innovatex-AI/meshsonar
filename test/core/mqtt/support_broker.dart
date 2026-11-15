// An in-process MQTT 3.1.1 broker over WebSocket (subprotocol `mqtt`) on 127.0.0.1, enough for the engine: CONNECT /
// CONNACK, PUBLISH (QoS 0 and 1 with PUBACK), PINGREQ / PINGRESP, DISCONNECT. Its login check follows the MeshCore
// reference broker (observer-firmware-notes.md section 3.1): username `v1_<64 hex>`, a three-part token with header
// alg Ed25519 / typ JWT, payload publicKey = username key, exp not passed, aud = the expected audience, and a valid
// Ed25519 signature over `header.payload` by that key. Publishes must be under meshcore/{IATA}/{the same key}/ and carry
// origin_id = the key.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'support.dart';

class BrokerMessage {
  final String clientId, topic, payload;
  final int qos;
  final bool retain;
  const BrokerMessage(this.clientId, this.topic, this.payload, this.qos, this.retain);
}

class JwtBroker {
  final String audience;
  final DateTime Function() clock;
  HttpServer? _server;
  final List<WebSocket> _sockets = [];
  final List<BrokerMessage> messages = [];
  final List<String> rejected = [];
  final List<String> connectedClients = [];
  final List<String> passwords = [];
  final StreamController<BrokerMessage> _onMessage = StreamController.broadcast();

  /// When set, every login is refused with this CONNACK code.
  int? forceReturnCode;

  JwtBroker({required this.audience, DateTime Function()? clock}) : clock = clock ?? (() => DateTime.now().toUtc());

  int get port => _server!.port;
  Stream<BrokerMessage> get onMessage => _onMessage.stream;

  Future<void> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req, protocolSelector: (p) => p.contains('mqtt') ? 'mqtt' : p.first);
      _sockets.add(ws);
      _Session(this, ws).run();
    });
  }

  /// Drops every client (network loss as the phone sees it).
  Future<void> dropAll() async {
    for (final ws in _sockets.toList()) {
      await ws.close();
    }
    _sockets.clear();
  }

  Future<void> stop() async {
    await dropAll();
    await _server?.close(force: true);
    await _onMessage.close();
  }

  Future<int> _authorise(String? user, String? pass) async {
    if (forceReturnCode != null) return forceReturnCode!;
    if (user == null || pass == null || pass.isEmpty) return _no('no credentials');
    if (!RegExp(r'^v1_[0-9A-Fa-f]{64}$').hasMatch(user)) return _no('username');
    final key = user.substring(3);
    final parts = pass.split('.');
    if (parts.length != 3) return _no('token parts');
    Map<String, dynamic> j(String s) => jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(s)))) as Map<String, dynamic>;
    final h = j(parts[0]), p = j(parts[1]);
    if (h['alg'] != 'Ed25519' || h['typ'] != 'JWT') return _no('header');
    if ((p['publicKey'] as String?)?.toUpperCase() != key.toUpperCase() || p['iat'] is! int) return _no('publicKey');
    final exp = p['exp'];
    if (exp is int && clock().millisecondsSinceEpoch ~/ 1000 > exp) return _no('expired');
    if (p['aud'] != audience) return _no('aud');
    if (!RegExp(r'^[0-9A-F]{128}$').hasMatch(parts[2])) return _no('signature not uppercase hex');
    final ok = await verifyEd25519(ascii.encode('${parts[0]}.${parts[1]}'), hexBytes(parts[2].toLowerCase()), key.toLowerCase());
    if (!ok) return _no('signature');
    passwords.add(pass);
    return 0;
  }

  int _no(String why) {
    rejected.add(why);
    return 5;
  }
}

class _Session {
  final JwtBroker b;
  final WebSocket ws;
  _Session(this.b, this.ws);
  final List<int> _buf = [];
  String? _clientId;
  String? _key;
  bool _busy = false;

  void run() {
    ws.listen(
      (data) {
        if (data is List<int>) _buf.addAll(data);
        unawaited(_pump());
      },
      onDone: () {},
      onError: (_) {},
    );
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        final f = _frame();
        if (f == null) break;
        await _handle(f.$1, f.$2);
      }
    } finally {
      _busy = false;
    }
  }

  (int, Uint8List)? _frame() {
    if (_buf.length < 2) return null;
    var mult = 1, len = 0, i = 1;
    while (true) {
      if (i >= _buf.length) return null;
      final d = _buf[i++];
      len += (d & 0x7f) * mult;
      if (d & 0x80 == 0) break;
      mult *= 128;
    }
    if (_buf.length < i + len) return null;
    final head = _buf[0];
    final body = Uint8List.fromList(_buf.sublist(i, i + len));
    _buf.removeRange(0, i + len);
    return (head, body);
  }

  void _send(List<int> bytes) {
    try {
      ws.add(Uint8List.fromList(bytes));
    } catch (_) {}
  }

  Future<void> _handle(int head, Uint8List body) async {
    final type = head >> 4;
    var o = 0;
    String str() {
      final n = (body[o] << 8) | body[o + 1];
      final s = utf8.decode(body.sublist(o + 2, o + 2 + n));
      o += 2 + n;
      return s;
    }

    switch (type) {
      case 1: // CONNECT
        str(); // protocol name
        o += 1; // level
        final flags = body[o++];
        o += 2; // keepalive
        _clientId = str();
        if (flags & 0x04 != 0) {
          str();
          str();
        }
        final user = flags & 0x80 != 0 ? str() : null;
        final pass = flags & 0x40 != 0 ? str() : null;
        final rc = await b._authorise(user, pass);
        _send([0x20, 2, 0, rc]);
        if (rc != 0) {
          await ws.close();
          return;
        }
        _key = user!.substring(3).toUpperCase();
        b.connectedClients.add(_clientId!);
      case 3: // PUBLISH
        final qos = (head >> 1) & 3;
        final topic = str();
        int? id;
        if (qos > 0) {
          id = (body[o] << 8) | body[o + 1];
          o += 2;
        }
        final payload = utf8.decode(body.sublist(o));
        final parts = topic.split('/');
        final origin = (jsonDecode(payload) as Map)['origin_id'];
        if (parts.length < 4 || parts[0] != 'meshcore' || parts[2] != _key || origin != _key) {
          b.rejected.add('topic $topic');
        } else {
          final m = BrokerMessage(_clientId!, topic, payload, qos, head & 1 == 1);
          b.messages.add(m);
          b._onMessage.add(m);
        }
        if (id != null) _send([0x40, 2, id >> 8, id & 0xff]);
      case 12: // PINGREQ
        _send([0xD0, 0]);
      case 14: // DISCONNECT
        await ws.close();
    }
  }
}
