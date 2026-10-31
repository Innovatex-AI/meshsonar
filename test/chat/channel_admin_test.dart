import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_admin.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/store.dart';

const radio = 'aa00000000000000000000000000000000000000000000000000000000000001';

class FakeChannelRadio implements ChannelRadio {
  final List<RadioSlot> slotList;
  Object? failWrite;
  Object? failList;
  int writes = 0;
  int clears = 0;
  @override
  final int? maxChannels;
  FakeChannelRadio(int n)
      : slotList = List.generate(n, (i) => RadioSlot(i, '', Uint8List(16))),
        maxChannels = n;

  void put(int i, String name, List<int> secret) => slotList[i] = RadioSlot(i, name, Uint8List.fromList(secret));

  @override
  Future<List<RadioSlot>> slots() async {
    if (failList != null) throw failList!;
    return List.of(slotList);
  }

  @override
  Future<void> write(int slot, String name, Uint8List secret16) async {
    if (failWrite != null) throw failWrite!;
    writes++;
    slotList[slot] = RadioSlot(slot, name, Uint8List.fromList(secret16));
  }

  @override
  Future<void> clear(int slot) async {
    if (failWrite != null) throw failWrite!;
    clears++;
    slotList[slot] = RadioSlot(slot, '', Uint8List(16));
  }
}

void main() {
  late ChatStore store;
  late FakeChannelRadio fake;
  late ChannelAdmin admin;
  var connected = true;
  var changes = 0;

  setUp(() {
    store = ChatStore.inMemory();
    fake = FakeChannelRadio(4);
    connected = true;
    changes = 0;
    admin = ChannelAdmin(store: store, radio: () => connected ? fake : null, wardriveChannelName: () => '#wardriving', onChanged: () => changes++);
  });
  tearDown(() => store.close());

  group('names', () {
    test('hashtag names are lower-cased, # is optional, bad characters are refused in plain words', () {
      expect(ChannelAdmin.normaliseHashtag('  #HamRadio '), '#hamradio');
      expect(ChannelAdmin.normaliseHashtag('ohio-2'), '#ohio-2');
      expect(() => ChannelAdmin.normaliseHashtag('#'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.invalidName)));
      expect(() => ChannelAdmin.normaliseHashtag('two words'), throwsA(isA<ChannelAdminException>()));
      expect(() => ChannelAdmin.normaliseHashtag('a' * 40), throwsA(isA<ChannelAdminException>()));
    });

    test('secrets: hex with spaces and 0x are accepted, anything else is refused', () {
      expect(ChannelAdmin.parseSecretHex(' 0x8b3387e9 c5cdea6a c9e5edba a115cd72 '), publicChannelSecret16);
      expect(() => ChannelAdmin.parseSecretHex('abc'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.invalidSecret)));
    });
  });

  group('joining', () {
    test('join Public writes the first empty slot with the well-known key and saves the row + secret', () async {
      fake.put(0, 'Wardrive', hashtagSecret16('#wardriving'));
      final j = await admin.joinPublic(radio);
      expect(j.created, isTrue);
      expect(j.channel.slot, 1);
      expect(j.channel.kind, ChannelKind.public);
      expect(fake.slotList[1].name, 'Public');
      expect(await store.channels.secretOf(j.channel), publicChannelSecret16);
      expect(changes, 1);
    });

    test('joining the same channel twice writes nothing the second time', () async {
      await admin.joinHashtag(radio, '#Ohio');
      final writes = fake.writes;
      final again = await admin.joinHashtag(radio, 'ohio');
      expect(again.created, isFalse);
      expect(fake.writes, writes);
      expect(store.channels.list(radio).length, 1);
    });

    test('hashtag secret comes from the lower-case name (HANDOFF 73)', () async {
      final j = await admin.joinHashtag(radio, 'HamRadio');
      expect(j.channel.name, '#hamradio');
      expect(j.channel.kind, ChannelKind.hashtag);
      expect(await store.channels.secretOf(j.channel), hashtagSecret16('#hamradio'));
    });

    test('a slot that already holds the same key is adopted, not duplicated', () async {
      fake.put(2, '#ohio', hashtagSecret16('#ohio'));
      final j = await admin.joinHashtag(radio, '#ohio');
      expect(j.channel.slot, 2);
      expect(fake.writes, 0);
    });

    test('full radio: plain-language error, nothing changed', () async {
      for (var i = 0; i < 4; i++) {
        fake.put(i, 'c$i', List.filled(16, i + 1));
      }
      await expectLater(admin.joinHashtag(radio, '#new'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.noFreeSlot).having((e) => e.message, 'message', contains('no free channel slot'))));
      expect(store.channels.list(radio), isEmpty);
    });

    test('not connected: asks to connect', () async {
      connected = false;
      await expectLater(admin.joinPublic(radio), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.notConnected)));
    });

    test('radio refuses: phone row is not created', () async {
      fake.failWrite = StateError('boom');
      await expectLater(admin.joinHashtag(radio, '#x'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.radioFailed)));
      expect(store.channels.list(radio), isEmpty);
    });

    test('a firmware without channel support says so', () async {
      final noSlots = FakeChannelRadio(0);
      admin = ChannelAdmin(store: store, radio: () => noSlots, wardriveChannelName: () => '#w', onChanged: () {});
      await expectLater(admin.joinPublic(radio), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.unsupported)));
      fake.failList = Exception('unsupported command');
      admin = ChannelAdmin(store: store, radio: () => fake, wardriveChannelName: () => '#w', onChanged: () {});
      await expectLater(admin.joinPublic(radio), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.unsupported)));
    });

    test('create private: random 16-byte secret, unique name, share link round trips into another phone', () async {
      final j = await admin.createPrivate(radio, 'Trail crew');
      expect(j.channel.kind, ChannelKind.private);
      final secret = (await store.channels.secretOf(j.channel))!;
      expect(secret.length, 16);
      await expectLater(admin.createPrivate(radio, 'trail CREW'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.duplicateName)));

      final link = await admin.shareLink(j.channel);
      final parsed = MeshLinks.parse(link) as ChannelLink;
      expect(parsed.name, 'Trail crew');
      expect(parsed.secret, secret);

      // the second phone / radio
      final store2 = ChatStore.inMemory();
      final fake2 = FakeChannelRadio(8);
      final admin2 = ChannelAdmin(store: store2, radio: () => fake2, wardriveChannelName: () => '#w', onChanged: () {});
      final j2 = await admin2.joinFromLink(radio, link);
      expect(j2.channel.name, 'Trail crew');
      expect(fake2.slotList.first.secret, secret);
      expect(await store2.channels.secretOf(j2.channel), secret);
      store2.close();
    });

    test('links: contact and garbage links give plain errors', () async {
      await expectLater(admin.joinFromLink(radio, 'meshcore://contact/add?name=Bob&public_key=${'ab' * 32}'), throwsA(isA<ChannelAdminException>().having((e) => e.message, 'message', contains('person'))));
      await expectLater(admin.joinFromLink(radio, 'hello'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.badLink)));
      await expectLater(admin.joinFromLink(radio, ''), throwsA(isA<ChannelAdminException>()));
    });

    test('pasted name + secret joins a private channel and keeps the region from a link', () async {
      final j = await admin.joinPrivate(radio, 'Club', toHex(List.filled(16, 7)));
      expect(j.channel.kind, ChannelKind.private);
      final link = MeshLinks.encodeChannel(name: 'Scoped', secret: List.filled(16, 9), regionScope: 'ohio');
      final j2 = await admin.joinFromLink(radio, link);
      expect(j2.channel.regionScope, 'ohio');
    });
  });

  group('editing and deleting', () {
    test('rename rewrites the slot; hashtag cannot be renamed', () async {
      final p = (await admin.createPrivate(radio, 'Old')).channel;
      final r = await admin.edit(p, name: 'New');
      expect(r.name, 'New');
      expect(fake.slotList[p.slot!].name, 'New');
      final h = (await admin.joinHashtag(radio, '#fixed')).channel;
      await expectLater(admin.edit(h, name: 'other'), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.notAllowed)));
    });

    test('region scope is stored on the phone and cleared with null', () async {
      final p = (await admin.createPrivate(radio, 'Scoped')).channel;
      final a = await admin.edit(p, regionScope: 'ohio');
      expect(a.regionScope, 'ohio');
      final b = await admin.edit(a, regionScope: null);
      expect(b.regionScope, isNull);
    });

    test('delete empties the slot, removes row, secret and messages', () async {
      final p = (await admin.createPrivate(radio, 'Gone')).channel;
      final ref = p.secretRef!;
      await admin.delete(p);
      expect(fake.clears, 1);
      expect(fake.slotList[p.slot!].isEmpty, isTrue);
      expect(store.channels.getById(p.id!), isNull);
      expect(await store.secrets.read(ref), isNull);
    });

    test('delete while disconnected is refused (the slot would stay on the radio)', () async {
      final p = (await admin.createPrivate(radio, 'Stay')).channel;
      connected = false;
      await expectLater(admin.delete(p), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.notConnected)));
      expect(store.channels.getById(p.id!), isNotNull);
    });

    test('the wardrive (system) channel cannot be edited or deleted here', () async {
      final s = await store.channels.save(Channel(radioId: radio, slot: 0, name: '#wardriving', kind: ChannelKind.system), secret: hashtagSecret16('#wardriving'));
      await expectLater(admin.delete(s), throwsA(isA<ChannelAdminException>().having((e) => e.error, 'error', ChannelAdminError.notAllowed)));
      await expectLater(admin.edit(s, name: 'x'), throwsA(isA<ChannelAdminException>()));
    });
  });

  group('sync from the radio', () {
    test('channels set up elsewhere appear; the wardrive slot becomes the System channel', () async {
      fake.put(0, 'Public', publicChannelSecret16);
      fake.put(1, '#wardriving', hashtagSecret16('#wardriving'));
      fake.put(2, 'Club', List.filled(16, 5));
      await admin.syncFromRadio(radio);
      final rows = store.channels.list(radio);
      expect(rows.map((c) => c.kind), [ChannelKind.public, ChannelKind.system, ChannelKind.private]);
      expect(store.channels.systemChannels(radio).single.slot, 1);
      expect(changes, 1);
      await admin.syncFromRadio(radio);
      expect(changes, 1, reason: 'nothing changed the second time');
    });

    test('slot conflict: another app overwrote slot 2; the old row keeps its history but loses the slot', () async {
      final old = (await admin.createPrivate(radio, 'Mine')).channel;
      final slot = old.slot!;
      fake.put(slot, 'Intruder', List.filled(16, 99));
      await admin.syncFromRadio(radio);
      final oldNow = store.channels.getById(old.id!)!;
      expect(oldNow.slot, isNull);
      final fresh = store.channels.bySlot(radio, slot)!;
      expect(fresh.name, 'Intruder');
      expect(fresh.id, isNot(old.id));
    });

    test('a slot that was emptied on the radio leaves the row as "not on the radio"; joining again puts it back', () async {
      final p = (await admin.createPrivate(radio, 'Back')).channel;
      fake.slotList[p.slot!] = RadioSlot(p.slot!, '', Uint8List(16));
      await admin.syncFromRadio(radio);
      expect(store.channels.getById(p.id!)!.slot, isNull);
      final secretHex = (await admin.secretHex(p))!;
      final j = await admin.joinPrivate(radio, 'Back', secretHex);
      expect(j.channel.id, p.id, reason: 'same channel, same history');
      expect(j.channel.slot, isNotNull);
    });

    test('a radio that cannot be read leaves the phone alone', () async {
      await admin.createPrivate(radio, 'Keep');
      fake.failList = StateError('x');
      await admin.syncFromRadio(radio);
      expect(store.channels.list(radio).single.slot, isNotNull);
    });
  });
}
