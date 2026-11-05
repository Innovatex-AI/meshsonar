// Chat WP7: the three route modes in the outbox (auto | fixed | flood) and the route API of the ContactManager, including the
// set-path radio write that stays behind AppFlags.routeWriteVerified.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/chat/db/misc_repositories.dart' show PathHistoryEntry;
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/path_tools.dart';

import 'contact_support.dart';
import 'support.dart';

void main() {
  late Harness h;
  late FakeRadioPort port;
  setUp(() {
    h = Harness();
    port = FakeRadioPort();
    h.service.contacts.attach(port);
  });
  tearDown(() => h.service.contacts.dispose());

  Future<void> runAll() async {
    for (var i = 0; i < 12; i++) {
      await h.service.pump();
      h.clock.advance(20000);
    }
  }

  Contact bobNow() => h.store.contacts.get(radioA, bobKey)!;

  test('the shipped flag keeps the set-path write off', () {
    expect(AppFlags.routeWriteVerified, isFalse);
    expect(h.service.contacts.routeWriteEnabled(), isFalse);
  });

  group('outbox modes', () {
    test('Automatic is unchanged: 5 tries, direct first, the last one floods and clears the path', () async {
      h.bob(path: true);
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi');
      await runAll();
      expect(h.sink.directs.map((d) => d.forceFlood), [false, false, false, false, true]);
      expect(bobNow().hasPath, isFalse, reason: 'the flood relearns the route');
    });

    test('Always search floods every try', () async {
      h.bob(path: true);
      h.store.contacts.setPathMode(radioA, bobKey, PathMode.flood);
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi');
      await runAll();
      expect(h.sink.directs, isNotEmpty);
      expect(h.sink.directs.every((d) => d.forceFlood), isTrue);
    });

    test('Keep this route never floods on the last try and never clears the path', () async {
      h.bob(path: true);
      expect(h.service.contacts.keepCurrentRoute(bobKey), isTrue);
      expect(bobNow().pathMode, PathMode.fixed);
      expect(bobNow().pinnedPath, '01,02');
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi');
      await runAll();
      expect(h.sink.directs.length, 5);
      expect(h.sink.directs.every((d) => !d.forceFlood), isTrue);
      expect(bobNow().hasPath, isTrue);
      expect(bobNow().outPath, [1, 2]);
    });

    test('Keep this route with the write off: a forgotten path floods (the radio relearns) and nothing is written', () async {
      h.bob(path: true);
      h.service.contacts.keepCurrentRoute(bobKey);
      h.store.contacts.setPath(radioA, bobKey, null, -1); // the radio forgot it
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi');
      await h.service.pump();
      expect(h.sink.directs.single.forceFlood, isTrue);
      expect(port.uploads, isEmpty);
      expect(bobNow().pathMode, PathMode.fixed, reason: 'the pin stays');
    });

    test('Keep this route with the write ON: a path the radio forgot or replaced is written back before the send', () async {
      h.service.contacts.routeWriteEnabled = () => true;
      h.bob(path: true);
      port.radioAdd(bobNow());
      h.service.contacts.keepCurrentRoute(bobKey);
      // an incoming PATH packet replaced the route on the radio and the phone follows it
      h.store.contacts.setPath(radioA, bobKey, Uint8List.fromList([9]), 1);
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi');
      await h.service.pump();
      expect(port.uploads, [bobKey]);
      expect(port.table[bobKey]!.outPath, [1, 2]);
      expect(port.table[bobKey]!.outPathLen, 2);
      expect(h.sink.directs.single.forceFlood, isFalse);
      expect(bobNow().outPath, [1, 2]);
    });
  });

  group('route API', () {
    test('Keep this route needs a route; Automatic and Always search are plain mode changes', () {
      h.bob();
      expect(h.service.contacts.keepCurrentRoute(bobKey), isFalse);
      expect(h.service.contacts.setRouteMode(bobKey, PathMode.flood), isTrue);
      expect(bobNow().pathMode, PathMode.flood);
      expect(bobNow().forceFlood, isTrue);
      h.service.contacts.setRouteMode(bobKey, PathMode.auto);
      expect(bobNow().forceFlood, isFalse);
      expect(h.service.contacts.setRouteMode(bobKey, PathMode.fixed), isFalse);
    });

    test('setRoute is refused while the flag is off and writes nothing', () async {
      h.bob();
      port.radioAdd(bobNow());
      final err = await h.service.contacts.setRoute(bobKey, PathRoute.fromHex(['a1', 'b2']));
      expect(err, isNotNull);
      expect(port.uploads, isEmpty);
      expect(bobNow().pathMode, PathMode.auto);
    });

    test('setRoute with the flag forced on: read-modify-write of the radio copy, 2-byte hashes, then Keep this route', () async {
      h.service.contacts.routeWriteEnabled = () => true;
      h.bob();
      port.radioAdd(bobNow().copyWith(radioFlags: 3));
      final err = await h.service.contacts.setRoute(bobKey, PathRoute.fromHex(['a1b2', 'c3d4']));
      expect(err, isNull);
      final onRadio = port.table[bobKey]!;
      expect(onRadio.outPathLen, 0x42);
      expect(onRadio.outPath, [0xa1, 0xb2, 0xc3, 0xd4]);
      expect(onRadio.radioFlags, 3, reason: 'flags of the radio copy survive');
      expect(bobNow().pathMode, PathMode.fixed);
      expect(bobNow().pinnedPath, 'a1b2,c3d4');
      expect(bobNow().pinnedHashSize, 2);
      expect(h.store.pathHistory.list(bobKey).first.kind, 'set');
    });

    test('setRoute reports a radio that refuses and changes nothing on the phone', () async {
      h.service.contacts.routeWriteEnabled = () => true;
      h.bob();
      port.radioAdd(bobNow());
      port.failUpload = StateError('boom');
      final err = await h.service.contacts.setRoute(bobKey, PathRoute.fromHex(['a1']));
      expect(err, contains('did not accept'));
      expect(bobNow().pathMode, PathMode.auto);
    });

    test('Reset route clears the path on phone and radio, drops a pin back to Automatic and logs it', () async {
      h.bob(path: true);
      port.radioAdd(bobNow());
      h.service.contacts.keepCurrentRoute(bobKey);
      await h.service.contacts.resetPath(bobKey);
      expect(bobNow().hasPath, isFalse);
      expect(bobNow().pathMode, PathMode.auto);
      expect(bobNow().pinnedPath, isNull);
      expect(port.resets, [bobKey]);
      expect(h.store.pathHistory.list(bobKey).first.kind, 'reset');
    });

    test('Reset route keeps Always search', () async {
      h.bob(path: true);
      h.service.contacts.setRouteMode(bobKey, PathMode.flood);
      await h.service.contacts.resetPath(bobKey);
      expect(bobNow().pathMode, PathMode.flood);
    });

    test('a ping is remembered on the contact and in ping_results (trimmed to 50)', () {
      h.bob();
      for (var i = 0; i < 55; i++) {
        h.service.contacts.recordPing(bobKey, kind: 'discovery', ok: i.isEven, rttMs: 1800, hops: 2, out: 'a1 > b2');
      }
      expect(bobNow().lastPingOk, isTrue, reason: 'the 55th ping (index 54) succeeded');
      expect(bobNow().lastPingRttMs, 1800);
      expect(h.store.pingResults.list(bobKey, limit: 100), hasLength(50));
    });

    test('path_history keeps the last 20 per contact', () {
      h.bob();
      for (var i = 0; i < 25; i++) {
        h.service.contacts.setRouteMode(bobKey, PathMode.auto);
        h.store.pathHistory.add(PathHistoryEntry(contactKey: bobKey, tsMs: i, kind: 'learned', hops: const ['a1']));
      }
      expect(h.store.pathHistory.list(bobKey, limit: 100), hasLength(20));
    });

    test('useDiscoveredRoute: Automatic is phone-only; Keep without the write only pins a route the radio holds', () async {
      h.bob(path: true);
      final held = PathRoute.fromHex(['01', '02']);
      expect(await h.service.contacts.useDiscoveredRoute(bobKey, held, keep: true), isNull);
      expect(bobNow().pathMode, PathMode.fixed);
      final other = PathRoute.fromHex(['09']);
      expect(await h.service.contacts.useDiscoveredRoute(bobKey, other, keep: true), isNotNull);
      expect(await h.service.contacts.useDiscoveredRoute(bobKey, other, keep: false), isNull);
      expect(bobNow().pathMode, PathMode.auto);
    });

    test('a route-meta merge from the radio keeps the phone-only settings', () {
      h.bob(path: true);
      h.service.contacts.keepCurrentRoute(bobKey);
      h.service.applyRadioContacts(radioA, [Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob', outPath: Uint8List.fromList([1, 2]), outPathLen: 2)]);
      expect(bobNow().pathMode, PathMode.fixed);
      expect(bobNow().pinnedPath, '01,02');
    });
  });
}
