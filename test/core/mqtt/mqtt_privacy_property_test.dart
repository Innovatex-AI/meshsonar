// Property test (OE2 done-when): over EVERY payload type 0..15, every route type, with and without a path, every channel
// verdict and several payload sizes, a private packet never reaches a feed slot. Three ways in:
//   (a) the real path: the observer privacy filter (TelemetryRecord.fromRx), then the engine;
//   (b) a forged record that claims a private type is "checked" with raw bytes (bypassing the filter);
//   (c) a public record paired with the bytes of a different (private) packet.
// Positive control: every public kind (ADVERT, PATH, TRACE, proven Public / #name group packets) does get published.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/mqtt/mqtt_payload.dart';
import 'package:meshsonar/core/mqtt/mqtt_engine.dart';
import 'package:meshsonar/core/mqtt_contract.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/packet.dart';

import '../../support/meshtrack_packets.dart';
import 'support.dart';

const _publicTypes = {PayloadType.advert, PayloadType.path, PayloadType.trace};
const _groupTypes = {PayloadType.grpTxt, PayloadType.grpData};

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late FakeNet net;
  late MqttObserverEngine engine;

  setUp(() async {
    net = FakeNet();
    engine = MqttObserverEngine(
      secrets: InMemorySecretStore(),
      clock: () => DateTime.utc(2026, 11, 15, 18),
      transport: net.create,
      queueCap: 100000,
      ratePerMinute: 100000,
    );
    engine.update(
      engineState(
        slots: [
          slot('slot-1', auth: MqttAuth.none),
          slot('slot-2', auth: MqttAuth.none, iata: 'DAY'),
        ],
      ),
    );
    await pump();
    expect(engine.statuses.map((s) => s.state.label), ['Connected', 'Connected']);
  });

  tearDown(() => engine.dispose());

  List<Map<String, dynamic>> published() => [for (final p in net.packets()) jsonDecode(p.payload) as Map<String, dynamic>];

  test('(a) through the privacy filter: only public kinds are ever published', () {
    final expectedPublished = <String>{};
    var n = 0;
    for (var type = 0; type < 16; type++) {
      for (var route = 0; route < 4; route++) {
        for (final path in [
          <int>[],
          <int>[0xaa, 0x01],
        ]) {
          for (final size in [0, 24, telemetryMinAdvertPayload, 300]) {
            for (final channel in <String?>[null, 'public', '#wardriving', 'Private Club', 'secret']) {
              final payload = List<int>.generate(size, (i) => (i + type * 3 + route + n) & 0xff);
              n++;
              final p = rx(rawPacket(type, route: route, path: path, payload: payload));
              final rec = filtered(p, channel: channel);
              if (rec == null) continue;
              engine.onPublicPacket(rec, p);
              final proven = channel != null && telemetryChannelRe.hasMatch(channel);
              final public = _publicTypes.contains(type) || (_groupTypes.contains(type) && proven);
              if (public && p.raw.length <= telemetryMaxRawBytes && MeshPacket.tryParse(p.raw) != null) {
                expectedPublished.add(_hex(p.raw).toUpperCase());
              }
            }
          }
        }
      }
    }
    final out = published();
    expect(out, isNotEmpty);
    for (final j in out) {
      final type = int.parse(j['packet_type'] as String);
      expect(telemetryPrivateTypes.contains(type), isFalse, reason: 'private type $type published');
      expect(_publicTypes.contains(type) || _groupTypes.contains(type), isTrue, reason: 'non-public type $type published');
      expect(expectedPublished.contains(j['raw']), isTrue, reason: 'unexpected packet ${j['raw']}');
    }
    // Both slots got the same set; every public kind was published (positive control).
    final raws = out.map((j) => j['raw']).toSet();
    expect(raws, expectedPublished);
    expect(out.map((j) => int.parse(j['packet_type'] as String)).toSet(), {..._publicTypes, ..._groupTypes});
    expect(
      net.packets().where((p) => p.topic.contains('/CMH/')).length,
      net.packets().where((p) => p.topic.contains('/DAY/')).length,
    );
  });

  test('(b) forged records claiming a private or non-public type with raw bytes never publish', () {
    for (var type = 0; type < 16; type++) {
      if (_publicTypes.contains(type) || _groupTypes.contains(type)) continue;
      for (var route = 0; route < 4; route++) {
        final p = rx(rawPacket(type, route: route, payload: List<int>.filled(24, type)));
        final forged = TelemetryRecord(
          at: p.at,
          payloadType: type,
          routeType: route,
          channelChecked: true,
          raw: _hex(p.raw),
          channel: 'public',
        );
        engine.onPublicPacket(forged, p);
      }
    }
    // A group packet whose channel was never proven, forged as checked.
    final g = rx(rawPacket(PayloadType.grpTxt));
    engine.onPublicPacket(
      TelemetryRecord(at: g.at, payloadType: PayloadType.grpTxt, routeType: 1, channelChecked: true, raw: _hex(g.raw)),
      g,
    );
    engine.onPublicPacket(
      TelemetryRecord(
        at: g.at,
        payloadType: PayloadType.grpTxt,
        routeType: 1,
        channelChecked: false,
        raw: _hex(g.raw),
        channel: 'public',
      ),
      g,
    );
    expect(net.packets(), isEmpty);
  });

  test('(c) a public verdict paired with private bytes never publishes', () {
    final advert = rx(rawPacket(PayloadType.advert));
    final rec = filtered(advert)!;
    for (final t in telemetryPrivateTypes) {
      for (var route = 0; route < 4; route++) {
        engine.onPublicPacket(rec, rx(rawPacket(t, route: route, payload: Uint8List(telemetryMinAdvertPayload))));
      }
    }
    expect(net.packets(), isEmpty);
    engine.onPublicPacket(rec, advert);
    expect(net.packets(), hasLength(2)); // control: the matching pair goes to both slots
  });

  // MT-8 privacy pin (MeshTrack plan sections 6, 9, 15): a MeshTrack position on a private group channel, from a friend or
  // our own send heard back through repeaters (path > 0), never makes a feed message, by any way in.
  test('a MeshTrack position on a private channel never publishes (friend, own send heard back, forged verdicts)', () {
    final shareable = ShareableChannels(
      () => [publicChannelSecret16, hashtagSecret16('#ohio')],
      named: () => [(name: 'public', key: publicChannelSecret16), (name: '#ohio', key: hashtagSecret16('#ohio'))],
    );
    final key = 'ab' * 32;
    for (final route in [RouteType.flood, RouteType.direct]) {
      for (final pathLen in [0, 1, 2, 5]) {
        final base = meshTrackRx(pathLen: pathLen, name: pathLen == 0 ? 'Sam' : 'KE4BFI');
        final pk = MeshPacket.tryParse(base.raw)!;
        final p = rx(rawPacket(PayloadType.grpTxt, route: route, path: [for (final h in pk.path) ...h], payload: pk.payload));
        // (a) the real filter: no record.
        expect(TelemetryRecord.fromRx(p, region: 'CMH', channelMatch: shareable.match), isNull);
        // A key proven but unnamed ('' = a key that slipped into the shareable set without a public name): no channel.
        final unnamed = TelemetryRecord.fromRx(p, region: 'CMH', channelMatch: (_) => '');
        expect(unnamed?.channel, isNull);
        if (unnamed != null) {
          expect(mqttPacketJson(unnamed, p, publicKeyHex: key), isNull);
          engine.onPublicPacket(unnamed, p);
        }
        // (b) forged records over the same bytes: unchecked, or checked without a channel.
        for (final forged in [
          TelemetryRecord(at: p.at, payloadType: PayloadType.grpTxt, routeType: route, raw: _hex(p.raw), channel: 'public'),
          TelemetryRecord(at: p.at, payloadType: PayloadType.grpTxt, routeType: route, channelChecked: true, raw: _hex(p.raw)),
        ]) {
          expect(mqttPacketJson(forged, p, publicKeyHex: key), isNull);
          engine.onPublicPacket(forged, p);
        }
      }
    }
    expect(net.packets(), isEmpty);
    // Control: the same text on Public publishes.
    final pub = meshTrackRx(key: publicChannelSecret16, pathLen: 2);
    final rec = TelemetryRecord.fromRx(pub, region: 'CMH', channelMatch: shareable.match)!;
    expect(mqttPacketJson(rec, pub, publicKeyHex: key), isNotNull);
  });

  test('nothing is published while the phone is not an observer', () async {
    final p = rx(rawPacket(PayloadType.advert));
    engine.update(engineState(sharing: false, slots: [slot('slot-1', auth: MqttAuth.none)]));
    await pump();
    engine.onPublicPacket(filtered(p)!, p);
    expect(net.packets(), isEmpty);
    expect(net.live, isEmpty);
  });
}
