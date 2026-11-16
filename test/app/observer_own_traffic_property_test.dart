// Property test (WS-OUT 4, observer-and-data-platform-plan-2026-11-16.md): over EVERY payload type 0..15, every channel
// verdict for group packets (Public, a # channel the phone holds, a private channel, the drive channel) and every own
// state (overheard, our own non-public ping's echo, our own public ping's echo, each one resolved before the echo or held
// until the ping resolves), only overheard, non-own, public packets reach the MQTT engine, and of those only the public
// kinds (ADVERT, PATH, TRACE, proven Public / # group packets) make a feed message.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/mqtt/mqtt_payload.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

class _RxLink extends FakeLink {
  _RxLink(super.info);
  final rx = StreamController<RxPacket>.broadcast();
  @override
  Stream<RxPacket> get rxPackets => rx.stream;
}

enum _Chan { none, public, held, private, drive }

enum _Own { overheard, ownPrivateBefore, ownPrivateHeld, ownPublicBefore, ownPublicHeld }

void main() {
  test('only overheard non-own public packets reach the MQTT engine, over every packet type', () async {
    final engine = FakeObserverEngine();
    late _RxLink link;
    final h = Harness()
      ..approveKey()
      ..observerEngineFactory = (() => engine)
      ..linkMaker = (info) => link = _RxLink(info);
    await h.state.init();
    expect(await h.state.connect(const RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck'), RadioKind.bluetooth), isTrue);
    h.state
      ..hashtagChannelKeys = (() => [hashtagSecret16('#ohio')])
      ..hashtagChannelNames = (() => ['#ohio']);
    await h.state.startDrive(); // a public drive, so an own ping at a real position goes up publicly
    expect(h.state.observerSharing, isTrue);

    final keys = <_Chan, List<int>>{
      _Chan.public: publicChannelSecret16,
      _Chan.held: hashtagSecret16('#ohio'),
      _Chan.private: List<int>.generate(16, (i) => 0x40 + i),
      _Chan.drive: hashtagSecret16(h.state.settings.channel),
    };
    final expected = <String>{}, all = <String>{};
    var salt = 0, pingId = 0;
    for (var type = 0; type < 16; type++) {
      final group = telemetryGroupTypes.contains(type);
      for (final chan in group ? [_Chan.public, _Chan.held, _Chan.private, _Chan.drive] : [_Chan.none]) {
        for (final own in _Own.values) {
          salt++;
          final payload = group
              ? buildGroupTextPayload(keys[chan]!, 5000 + salt, 'Ann', 'words $salt')
              : Uint8List.fromList(
                  List<int>.generate(type == PayloadType.advert ? telemetryMinAdvertPayload : 24, (i) => (i * 7 + salt) & 0xff)
                    ..[0] = salt & 0xff
                    ..[1] = salt >> 8);
          final p = RxPacket(
            at: DateTime.utc(2026, 11, 16, 12),
            raw: MeshPacket(
              header: makeHeader(RouteType.flood, type),
              pathLenByte: 1,
              path: [Uint8List.fromList([0xa1])],
              payload: payload,
            ).toBytes(),
            snrDb: 4,
            rssiDbm: -95);
          final hash = MeshPacket.tryParse(p.raw)!.hashHex;
          all.add(hash);
          final ownPing = own != _Own.overheard;
          final public = own == _Own.ownPublicBefore || own == _Own.ownPublicHeld;
          final held = own == _Own.ownPrivateHeld || own == _Own.ownPublicHeld;
          // A position at 0,0 never goes up publicly (_pingPublic), a real one does on this public drive.
          DrivePing ping() => DrivePing(
              id: 'p${pingId++}', ts: DateTime.utc(2026, 11, 16, 12), lat: public ? 39.97 : 0, lon: public ? -82.99 : 0,
              pktHash: hash, kind: PingKind.tx);
          if (ownPing && !held) h.state.debugOnPing(ping());
          if (held) h.state.debugObserverPingSent(DateTime.utc(2026, 11, 16, 12));
          link.rx.add(p);
          await Future<void>.delayed(Duration.zero);
          if (held) h.state.debugOnPing(ping());
          final passesFilter = !telemetryPrivateTypes.contains(type) && (!group || chan == _Chan.public || chan == _Chan.held || chan == _Chan.drive);
          if (!ownPing && chan != _Chan.drive && passesFilter) expected.add(hash);
        }
      }
    }
    final reached = [for (final (r, _) in engine.packets) r.packetHash!];
    expect(reached.toSet(), expected, reason: 'exactly the overheard, non-own packets the privacy filter passed');
    expect(reached, hasLength(expected.length), reason: 'each once');
    expect(all.length, salt, reason: 'every case is a distinct packet');
    // Of what reached the engine, only the public kinds become a feed message.
    final key = 'ab' * 32;
    for (final (r, rx) in engine.packets) {
      final publicKind = telemetryRawTypes.contains(r.payloadType) || telemetryGroupTypes.contains(r.payloadType);
      expect(r.own, isFalse);
      expect(r.channel, isNot(h.state.settings.channel.toLowerCase()));
      expect(mqttPacketMessage(r, rx, publicKeyHex: key) != null, publicKind, reason: 'type ${r.payloadType}');
    }
    // Positive control: every public kind is among what reached the engine.
    final kinds = {for (final (r, _) in engine.packets) if (telemetryRawTypes.contains(r.payloadType)) r.payloadType};
    expect(kinds, telemetryRawTypes);
    expect({for (final (r, _) in engine.packets) if (r.channel != null) r.channel}, {'public', '#ohio'});
    await h.state.stopDrive();
    h.state.dispose();
  });
}
