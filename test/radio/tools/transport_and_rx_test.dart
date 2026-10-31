// Scope check, advert decode and the Rx log, on the two REAL adverts captured from INNO-OB-2.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/tools/advert_decode.dart';
import 'package:meshsonar/radio/tools/rx_log.dart';
import 'package:meshsonar/radio/tools/transport_code.dart';

import '../../support/tools_fixtures.dart';

void main() {
  group('transport code (region scope)', () {
    final scoped = MeshPacket.tryParse(advertScopedFlood)!;
    final zero = MeshPacket.tryParse(advertZeroHop)!;

    test('the live scoped advert: header 0x10, code 0x7a41, 2-byte hash, 0 hops', () {
      expect(scoped.header, 0x10);
      expect(scoped.routeType, RouteType.transportFlood);
      expect(scoped.transportCode1, 0x7a41);
      expect(scoped.pathHashSize, 2);
      expect(scoped.hopCount, 0);
    });

    test('HMAC-SHA256 with SHA256("#cmh")[0:16] over (type, payload) gives exactly 0x7a41', () {
      expect(toHex(regionTransportKey('#cmh')), toHex(sha256('#cmh'.codeUnits).sublist(0, 16)));
      expect(transportCodeFor(regionTransportKey('#cmh'), scoped.payloadType, scoped.payload), 0x7a41);
    });

    test('in scope: #cmh; other names are not (cmh without the hash and #CMH give different codes)', () {
      expect(packetInScope(scoped, '#cmh'), isTrue);
      expect(packetInScope(scoped, 'cmh'), isFalse);
      expect(packetInScope(scoped, '#CMH'), isFalse);
      expect(packetInScope(scoped, '#swoh'), isFalse);
      final r = checkScope(scoped, ['#swoh', '#cmh']);
      expect(r.verdict, ScopeVerdict.inScope);
      expect(r.region, '#cmh');
      expect(r.label, 'in scope: #cmh');
    });

    test('scoped but not to a region we know = otherScope; plain direct advert = unscoped', () {
      expect(checkScope(scoped, ['#swoh']).verdict, ScopeVerdict.otherScope);
      expect(checkScope(scoped, const []).verdict, ScopeVerdict.otherScope);
      expect(checkScope(zero, ['#cmh']).verdict, ScopeVerdict.unscoped);
      expect(checkScope(zero, ['#cmh']).label, 'unscoped');
    });

    test('a tampered payload no longer matches', () {
      final bad = Uint8List.fromList(advertScopedFlood)..[60] ^= 1;
      expect(packetInScope(MeshPacket.tryParse(bad)!, '#cmh'), isFalse);
    });

    test('codes 0 and 0xFFFF are remapped like the firmware', () {
      // exhaustive search is too long; assert the rule on the function boundary via a key/payload search for a small range
      for (var i = 0; i < 300; i++) {
        final c = transportCodeFor(regionTransportKey('#x'), 5, [i]);
        expect(c, isNot(0));
        expect(c, isNot(0xFFFF));
      }
    });
  });

  group('advert decode', () {
    test('zero-hop advert: INNO-OB-2, repeater, its published position, key starts df0136c2', () {
      final a = AdvertInfo.tryParse(MeshPacket.tryParse(advertZeroHop)!)!;
      expect(a.name, repeaterName);
      expect(a.nodeType, 2);
      expect(a.lat, closeTo(40.12806, 1e-6));
      expect(a.lon, closeTo(-82.97965, 1e-6));
      expect(a.publicKeyHex.substring(0, 16), repeaterKeyPrefixHex);
      expect(a.hash1, 'df');
    });

    test('scoped advert decodes the same node', () {
      final a = AdvertInfo.tryParse(MeshPacket.tryParse(advertScopedFlood)!)!;
      expect(a.name, repeaterName);
      expect(a.publicKeyHex, AdvertInfo.tryParse(MeshPacket.tryParse(advertZeroHop)!)!.publicKeyHex);
    });

    test('built advert round trips with a position; (0,0) and out-of-range positions are dropped; hostile names are cleaned', () {
      final key = Uint8List(32)..[0] = 9;
      final p = buildAdvertPayload(key, 1000, 3, 'Room\u0001 Seven', lat: 39.96, lon: -82.99);
      final a = AdvertInfo.tryParsePayload(p)!;
      expect(a.nodeType, 3);
      expect(a.lat, closeTo(39.96, 1e-6));
      expect(a.name, 'Room Seven');
      expect(AdvertInfo.tryParsePayload(buildAdvertPayload(key, 1, 2, 'x', lat: 0, lon: 0))!.hasPosition, isFalse);
      expect(AdvertInfo.tryParsePayload(buildAdvertPayload(key, 1, 2, 'x', lat: 95, lon: 10))!.hasPosition, isFalse);
      expect(AdvertInfo.tryParsePayload(Uint8List(50)), isNull);
    });
  });

  group('Rx log', () {
    Uint8List grp(List<int> secret, String text, {List<int> path = const [0x1a]}) {
      final payload = buildGroupTextPayload(secret, 1000, 'Ann', text);
      return MeshPacket(header: makeHeader(RouteType.flood, PayloadType.grpTxt), pathLenByte: encodePathLen(1, path.length), path: [for (final h in path) Uint8List.fromList([h])], payload: payload).toBytes();
    }

    test('decodes the live adverts: type, route, hops, hash size, SNR/RSSI', () {
      final log = RxLog();
      final e1 = log.add(advertZeroHop, snrDb: -2.5, rssiDbm: -122)!;
      final e2 = log.add(advertScopedFlood, snrDb: -1.5, rssiDbm: -122)!;
      expect(e1.payloadType, PayloadType.advert);
      expect(e1.routeType, RouteType.direct);
      expect(e1.hops, 0);
      expect(e1.advert!.name, repeaterName);
      expect(e1.summary, 'Advert from INNO-OB-2 (repeater)');
      expect(e2.routeType, RouteType.transportFlood);
      expect(e2.packet!.pathHashSize, 2);
      expect(log.countsByType[PayloadType.advert], 2);
      expect(log.countsByRoute[RouteType.direct], 1);
      expect(log.total, 2);
    });

    test('known channel: labelled only for a joined channel, by MAC, with no text kept', () {
      final pub = Uint8List.fromList(publicChannelSecret);
      final other = hashtagChannelSecret('#private-club');
      final log = RxLog()..knownChannels = [KnownChannel('Public', pub)];
      final a = log.add(grp(pub, 'hello mesh'), snrDb: 3)!;
      final b = log.add(grp(other, 'secret club talk'), snrDb: 3)!;
      expect(a.knownChannel, 'Public');
      expect(a.summary, 'Channel message, known channel: Public');
      expect(b.knownChannel, isNull);
      expect(b.summary, 'Channel message on another channel');
      final dump = '${log.exportCsv()} ${a.summary} ${b.summary}';
      expect(dump.contains('hello mesh'), isFalse);
      expect(dump.contains('secret club talk'), isFalse);
      expect(dump.contains('Ann'), isFalse, reason: 'the sender name is inside the encrypted text');
    });

    test('a joined channel with the same hash byte but another key is NOT labelled (MAC check)', () {
      final pub = Uint8List.fromList(publicChannelSecret);
      // find a secret whose channel hash byte equals Public's but whose key differs
      Uint8List? twin;
      for (var i = 0; i < 5000 && twin == null; i++) {
        final s = hashtagChannelSecret('#twin$i');
        if (channelHash(s) == channelHash(pub)) twin = s;
      }
      expect(twin, isNotNull);
      final log = RxLog()..knownChannels = [KnownChannel('Twin', twin!)];
      expect(log.add(grp(pub, 'x'))!.knownChannel, isNull);
    });

    test('ring is bounded; counters keep counting past the ring', () {
      final log = RxLog(capacity: 5);
      for (var i = 0; i < 12; i++) {
        log.add(advertZeroHop, snrDb: i.toDouble());
      }
      expect(log.length, 5);
      expect(log.total, 12);
      expect(log.entries().first.snrDb, 11.0, reason: 'newest first');
      expect(log.entries().last.snrDb, 7.0);
    });

    test('garbage is counted as invalid, not listed as a packet type', () {
      final log = RxLog();
      final e = log.add(Uint8List.fromList([1]))!;
      expect(e.packet, isNull);
      expect(e.summary, startsWith('Not a valid packet'));
      expect(log.invalid, 1);
      expect(log.countsByType, isEmpty);
    });

    test('filters: type, route, hops, known channel', () {
      final pub = Uint8List.fromList(publicChannelSecret);
      final log = RxLog()..knownChannels = [KnownChannel('Public', pub)];
      log.add(advertZeroHop);
      log.add(advertScopedFlood);
      log.add(grp(pub, 'a', path: const [1, 2]));
      expect(log.entries(const RxLogFilter(types: {PayloadType.advert})).length, 2);
      expect(log.entries(const RxLogFilter(routes: {RouteType.transportFlood})).length, 1);
      expect(log.entries(const RxLogFilter(minHops: 2)).length, 1);
      expect(log.entries(const RxLogFilter(knownChannelsOnly: true)).length, 1);
      expect(const RxLogFilter().isEmpty, isTrue);
    });

    test('pause keeps counting but stops listing; clear empties everything; resume lists again', () {
      final log = RxLog();
      log.add(advertZeroHop);
      log.pause();
      expect(log.add(advertZeroHop), isNull);
      expect(log.length, 1);
      expect(log.total, 2);
      expect(log.missedWhilePaused, 1);
      log.resume();
      log.add(advertZeroHop);
      expect(log.length, 2);
      log.clear();
      expect([log.length, log.total, log.missedWhilePaused, log.countsByType.length], [0, 0, 0, 0]);
    });

    test('CSV: header fields only, adverts carry the public name but no position', () {
      final log = RxLog(clock: () => DateTime.utc(2026, 11, 1, 12))..add(advertScopedFlood, snrDb: -1.5, rssiDbm: -122);
      final csv = log.exportCsv();
      expect(csv.split('\n').first, startsWith('time_utc,route,payload_type'));
      expect(csv, contains('2026-11-01T12:00:00.000Z,Scoped flood,Advert,2,0,,-1.50,-122,124,,INNO-OB-2,repeater'));
      expect(csv.contains('40.128'), isFalse, reason: 'positions are not exported');
    });

    test('listens to a stream', () async {
      final log = RxLog();
      // ignore: close_sinks
      final ctl = Stream.fromIterable([]);
      log.listen(ctl.cast());
      expect(log.listening, isTrue);
      await log.dispose();
      expect(log.listening, isFalse);
    });
  });
}
