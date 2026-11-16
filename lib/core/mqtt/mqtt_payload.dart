// What a feed slot publishes (observer-everywhere-mqtt-plan-2026-11-15.md sections 3.4 and D8; JSON shape pinned from
// docs/protocol/observer-firmware-notes.md section 5, golden tests in test/core/mqtt/mqtt_payload_test.dart):
//   meshcore/{IATA}/{PUBKEY}/packets   one firmware-style JSON per public packet heard
//   meshcore/{IATA}/{PUBKEY}/status    an "online" message on connect, every 5 minutes, and from Settings > Test;
//                                      "offline" when the feed stops on purpose, and as the last will the broker
//                                      publishes when the connection is lost (same topic and retain flag as online)
// The gate ([mqttPacketJson]) is a second, independent check behind the observer privacy filter
// (TelemetryRecord.fromRx): only ADVERT, PATH, TRACE and group packets on a proven Public / #name channel are ever
// published; DMs, requests, responses, anonymous requests, acks, multipart, control and custom packets never are, and
// neither are the person's name, position, cell or drive state. The observer name sent is "MeshSonar " + the first 8
// characters of the radio's public key (already public as the observer id), never the radio's own name.
// Pure Dart: no Flutter imports.
import 'dart:convert';

import '../../radio/packet.dart' show MeshPacket, RouteType;
import '../../radio/radio_api.dart' show RxPacket;
import '../telemetry.dart' show TelemetryRecord, telemetryGroupTypes, telemetryPrivateTypes, telemetryRawTypes;

/// `client_version` in status messages.
const String mqttClientVersion = 'meshsonar-app/1';

abstract final class MqttTopics {
  static final RegExp iataRe = RegExp(r'^[A-Z0-9]{3}$');
  static String packets(String iata, String publicKeyHex) =>
      'meshcore/${iata.toUpperCase()}/${publicKeyHex.toUpperCase()}/packets';
  static String status(String iata, String publicKeyHex) => 'meshcore/${iata.toUpperCase()}/${publicKeyHex.toUpperCase()}/status';
}

/// The observer name brokers show: never the radio's own (often personal) name.
String mqttOrigin(String publicKeyHex) => 'MeshSonar ${publicKeyHex.substring(0, 8).toUpperCase()}';

String _two(int v) => v.toString().padLeft(2, '0');

/// ISO 8601 UTC with microseconds and `+00:00`, as the firmware writes it (`2026-10-17T12:00:00.123456+00:00`).
String mqttTimestamp(DateTime t) {
  final u = t.toUtc();
  final micro = (u.millisecond * 1000 + u.microsecond).toString().padLeft(6, '0');
  return '${u.year.toString().padLeft(4, '0')}-${_two(u.month)}-${_two(u.day)}T${_two(u.hour)}:${_two(u.minute)}:'
      '${_two(u.second)}.$micro+00:00';
}

String _lowerHex(List<int> bytes) {
  final b = StringBuffer();
  for (final x in bytes) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// The packet JSON for [record] / [rx], or null when it must not leave the phone. Both must agree: the bytes in [rx]
/// re-parse to the same type the privacy filter judged, and the filter kept them as [TelemetryRecord.raw].
Map<String, dynamic>? mqttPacketJson(TelemetryRecord record, RxPacket rx, {required String publicKeyHex}) {
  if (!record.mayLeavePhone) return null;
  if (telemetryPrivateTypes.contains(record.payloadType)) return null;
  final raw = record.raw;
  if (raw == null) return null;
  final p = MeshPacket.tryParse(rx.raw);
  if (p == null) return null;
  final type = p.payloadType;
  if (type != record.payloadType || telemetryPrivateTypes.contains(type)) return null;
  final group = telemetryGroupTypes.contains(type);
  if (!telemetryRawTypes.contains(type) && !group) return null;
  if (group && (!record.channelChecked || record.channel == null)) return null;
  if (_lowerHex(rx.raw) != raw) return null;
  final at = rx.at.toUtc();
  final direct = p.routeType == RouteType.direct || p.routeType == RouteType.transportDirect;
  final snr = record.snrDb, rssi = record.rssiDbm;
  return {
    'origin': mqttOrigin(publicKeyHex),
    'origin_id': publicKeyHex.toUpperCase(),
    'timestamp': mqttTimestamp(at),
    'type': 'PACKET',
    'direction': 'rx',
    'len': '${rx.raw.length}',
    'packet_type': '$type',
    'payload_len': '${p.payload.length}',
    'route': direct ? 'D' : 'F',
    'raw': raw.toUpperCase(),
    if (snr != null) 'SNR': snr.toStringAsFixed(1),
    if (rssi != null) 'RSSI': '${rssi.round()}',
    'hash': p.hashHex.toUpperCase(),
    'time': '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}',
    'date': '${_two(at.day)}/${_two(at.month)}/${at.year}',
    if (direct) 'path': p.pathHex,
  };
}

/// [mqttPacketJson] as the published text; null when it must not leave the phone.
String? mqttPacketMessage(TelemetryRecord record, RxPacket rx, {required String publicKeyHex}) {
  final j = mqttPacketJson(record, rx, publicKeyHex: publicKeyHex);
  return j == null ? null : jsonEncode(j);
}

/// The `status` message: online (or offline when [online] is false), who (the radio's key), the radio model and firmware
/// when known. No position. [timestamp] false leaves the time out (the last will: the broker sends it later, at an
/// unknown time).
Map<String, dynamic> mqttStatusJson({
  required String publicKeyHex,
  required DateTime at,
  String? model,
  String? firmware,
  bool online = true,
  bool timestamp = true,
}) => {
  'status': online ? 'online' : 'offline',
  if (timestamp) 'timestamp': mqttTimestamp(at),
  'origin': mqttOrigin(publicKeyHex),
  'origin_id': publicKeyHex.toUpperCase(),
  if (model != null && model.isNotEmpty) 'model': model,
  if (firmware != null && firmware.isNotEmpty) 'firmware_version': firmware,
  'client_version': mqttClientVersion,
};
