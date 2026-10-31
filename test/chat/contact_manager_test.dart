import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/contact_manager.dart';
import 'package:meshsonar/chat/contact_port.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/packet.dart';

import 'contact_support.dart';
import 'support.dart';

void main() {
  late ChatStore store;
  late FakeRadioPort port;
  late ContactManager cm;
  late FakeClock clock;
  var changes = 0;

  setUp(() {
    store = ChatStore.inMemory();
    port = FakeRadioPort(capacity: 100);
    clock = FakeClock();
    changes = 0;
    cm = ContactManager(store: store, nowMs: clock.call, onChanged: () => changes++);
  });
  tearDown(() => cm.dispose());

  Future<void> attachAndSync({bool full = false}) async {
    cm.attach(port);
    await cm.syncNow(full: full);
  }

  List<Contact> book() => store.contacts.list(radioA);

  group('download', () {
    test('first sync fills the book, marks them on the radio, stores the cursor and says idle', () async {
      for (var i = 1; i <= 12; i++) {
        port.radioAdd(radioContact(i, type: i % 3 == 0 ? ContactType.repeater : ContactType.companion));
      }
      await attachAndSync();
      expect(book(), hasLength(12));
      expect(book().every((c) => c.onRadio && c.source == ContactSource.radio), isTrue);
      expect(cm.state.phase, SyncPhase.idle);
      expect(cm.state.radioCount, 12);
      expect(cm.state.capacity, 100);
      expect(cm.state.lastSyncMs, isNotNull);
      expect(port.downloads, [0]);
      expect(changes, greaterThan(0));
    });

    test('idempotent: the same radio three times leaves the same book; later runs are incremental and empty', () async {
      for (var i = 1; i <= 30; i++) {
        port.radioAdd(radioContact(i));
      }
      await attachAndSync();
      final first = [for (final c in book()) (c.publicKey, c.name, c.onRadio, c.lat, c.lastAdvertTs)];
      await cm.syncNow();
      await cm.syncNow();
      await cm.syncNow(full: true);
      expect([for (final c in book()) (c.publicKey, c.name, c.onRadio, c.lat, c.lastAdvertTs)], first);
      expect(port.downloads.first, 0);
      expect(port.downloads[1], greaterThan(0), reason: 'incremental');
      expect(port.downloads.last, 0, reason: 'the explicit full read');
    });

    test('phone-only fields survive; the radio wins for what the radio knows', () async {
      port.radioAdd(radioContact(1, name: 'Old name'));
      await attachAndSync();
      cm.setFavourite(keyN(1), true);
      cm.rename(keyN(1), 'Mum');
      cm.setNotes(keyN(1), 'blue car');
      cm.setForceFlood(keyN(1), true);
      port.radioAdd(radioContact(1, name: 'New name', path: true));
      await cm.syncNow();
      final c = store.contacts.get(radioA, keyN(1))!;
      expect(c.name, 'New name');
      expect(c.hasPath, isTrue);
      expect(c.favourite, isTrue);
      expect(c.customName, 'Mum');
      expect(c.displayName, 'Mum');
      expect(c.notes, 'blue car');
      expect(c.forceFlood, isTrue);
    });

    test('a new contact with the radio-side favourite flag arrives as a favourite', () async {
      port.radioAdd(radioContact(1, radioFlags: 1));
      await attachAndSync();
      expect(store.contacts.get(radioA, keyN(1))!.favourite, isTrue);
    });

    test('the radio lost a contact while we were away: the count mismatch forces a full read; the phone keeps the contact', () async {
      for (var i = 1; i <= 10; i++) {
        port.radioAdd(radioContact(i));
      }
      await attachAndSync();
      port.table.remove(keyN(4));
      port.lastMod.remove(keyN(4));
      port.radioAdd(radioContact(11));
      await cm.syncNow();
      expect(port.downloads.length, 3, reason: 'incremental, then the full read the mismatch asked for');
      expect(port.downloads.last, 0);
      final four = store.contacts.get(radioA, keyN(4))!;
      expect(four.onRadio, isFalse);
      expect(book(), hasLength(11));
      expect(cm.state.radioCount, 10);
    });

    test('control characters and bidi overrides in a name are stripped; an empty name becomes the key start', () async {
      port.radioAdd(radioContact(1, name: 'A${String.fromCharCode(0x202E)}evil${String.fromCharCode(7)}'));
      port.radioAdd(radioContact(2, name: ' '));
      await attachAndSync();
      expect(store.contacts.get(radioA, keyN(1))!.name, 'Aevil');
      expect(store.contacts.get(radioA, keyN(2))!.name, keyN(2).substring(0, 8));
    });
  });

  group('radio drops mid-sync', () {
    test('what arrived is kept, the state is failed with a plain sentence, the retry completes with no duplicates', () async {
      for (var i = 1; i <= 250; i++) {
        port.radioAdd(radioContact(i % 250 + 1 + (i > 250 ? 0 : 0)));
      }
      port.dropAfter = 130;
      await attachAndSync();
      expect(cm.state.phase, SyncPhase.failed);
      expect(cm.state.error, contains('What arrived is saved'));
      expect(book().length, 130, reason: 'every contact that came before the drop is in the book, including the unflushed batch');
      expect(store.db.setting('contacts.cursor:$radioA'), isNull, reason: 'the cursor only moves when a list ends properly');
      await cm.syncNow();
      expect(cm.state.phase, SyncPhase.idle);
      expect(book(), hasLength(250));
      expect(port.dropCount, 1);
      expect(store.db.setting('contacts.cursor:$radioA'), isNotNull);
    });

    test('the radio is not linked at all: offline, nothing thrown, the book still readable', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      port.isConnected = false;
      await cm.syncNow();
      expect(cm.state.phase, SyncPhase.offline);
      expect(book(), hasLength(1));
      cm.detach();
      expect(cm.state.phase, SyncPhase.offline);
      expect(cm.radioId, radioA, reason: 'the last radio is remembered, so the list shows offline');
    });

    test('an unexpected error becomes the generic plain sentence, not a stack trace', () async {
      port.failUpload = StateError('boom');
      store.contacts.upsert(radioContact(1).copyWith(source: ContactSource.manual));
      await attachAndSync();
      expect(cm.state.phase, SyncPhase.failed);
      expect(cm.state.error, isNot(contains('boom')));
      expect(cm.state.error, isNotEmpty);
    });
  });

  group('the phone is the master', () {
    test('user-added contacts and favourites are put on the radio, anyone else is not pushed unasked', () async {
      store.contacts.upsert(radioContact(1).copyWith(source: ContactSource.manual)); // added by hand
      store.contacts.upsert(radioContact(2).copyWith(favourite: true));
      store.contacts.upsert(radioContact(3)); // known from an earlier radio session, nothing special
      await attachAndSync();
      expect(port.table.keys, containsAll([keyN(1), keyN(2)]));
      expect(port.table.containsKey(keyN(3)), isFalse);
      expect(port.table[keyN(2)]!.radioFlags & 1, 1, reason: 'the favourite is the radio\'s "never replace me"');
      expect(store.contacts.get(radioA, keyN(1))!.onRadio, isTrue);
      expect(store.contacts.get(radioA, keyN(3))!.onRadio, isFalse);
    });

    test('a contact with a conversation goes back on the radio so its DMs can be decrypted', () async {
      store.contacts.upsert(radioContact(7));
      store.messages.insert(ChatMessage(
          id: 'x', radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(keyN(7).substring(0, 12)), direction: Direction.incoming,
          tsSender: 1, tsLocalMs: clock.ms, text: 'hi', state: MessageState.received, dedupeKey: 'k1'));
      await attachAndSync();
      expect(port.table.containsKey(keyN(7)), isTrue);
    });

    test('cache fill stops short of the reserve for the radio\'s own use, but never for contacts the user added by hand', () async {
      port.capacity = 10;
      for (var i = 1; i <= 8; i++) {
        port.radioAdd(radioContact(i));
      }
      for (var i = 20; i < 24; i++) {
        store.contacts.upsert(radioContact(i).copyWith(favourite: true)); // want to go on
      }
      store.contacts.upsert(radioContact(30).copyWith(source: ContactSource.manual));
      await attachAndSync();
      // 8 on the radio, capacity 10, reserve 5: favourites find no room (3 would breach the reserve); the manual add takes a slot
      expect(port.table.length, 9);
      expect(port.table.containsKey(keyN(30)), isTrue);
      expect(store.contacts.list(radioA).where((c) => c.favourite && !c.onRadio), hasLength(4));
    });

    test('no contact is ever deleted from the phone because the radio is full', () async {
      port.capacity = 3;
      for (var i = 1; i <= 3; i++) {
        port.radioAdd(radioContact(i, radioFlags: 1)); // favourites on the radio: nothing may be taken off it
      }
      await attachAndSync();
      final r = await cm.addByKey(keyN(9), name: 'Newcomer');
      expect(r.ok, isTrue);
      expect(r.onRadio, isFalse);
      expect(r.note, contains('full'));
      expect(cm.state.tableFull, isTrue);
      expect(book(), hasLength(4));
    });

    test('adding with a full radio makes room by taking the least useful contact off the radio, and says so', () async {
      port.capacity = 3;
      for (var i = 1; i <= 3; i++) {
        port.radioAdd(radioContact(i));
      }
      await attachAndSync();
      final notice = cm.notices.first;
      final r = await cm.addByKey(keyN(9), name: 'Newcomer');
      expect(r.onRadio, isTrue);
      expect(port.table.length, 3);
      expect(book(), hasLength(4), reason: 'the evicted contact is still in the phone\'s book');
      expect((await notice).message, contains('still in your contacts'));
    });
  });

  group('ensureOnRadio (DM to a contact the radio let go)', () {
    test('already there: no radio traffic at all', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      port.uploads.clear();
      await cm.ensureOnRadio(keyN(1));
      expect(port.uploads, isEmpty);
    });

    test('not there: uploaded with its saved route; learns the radio\'s route when the radio has a newer one', () async {
      store.contacts.upsert(radioContact(1, path: true));
      await attachAndSync();
      port.table.remove(keyN(1));
      store.contacts.setOnRadio(radioA, keyN(1), false);
      await cm.ensureOnRadio(keyN(1));
      expect(port.table[keyN(1)]!.hasPath, isTrue);
      expect(store.contacts.get(radioA, keyN(1))!.onRadio, isTrue);
      // the radio holds a newer route: ensureOnRadio(force) reads it back
      port.radioAdd(radioContact(1, path: true).copyWith(outPath: Uint8List.fromList([9, 9]), outPathLen: 2));
      await cm.ensureOnRadio(keyN(1), force: true);
      expect(store.contacts.get(radioA, keyN(1))!.outPathLen, 2);
    });

    test('full: takes the least useful non-favourite, non-conversation contact off the RADIO only, says so, and uploads', () async {
      port.capacity = 4;
      port.radioAdd(radioContact(1).copyWith(lastHeardMs: 5000)); // oldest heard, no conversation: the victim
      port.radioAdd(radioContact(2).copyWith(lastHeardMs: 9000));
      port.radioAdd(radioContact(3));
      port.radioAdd(radioContact(4));
      store.contacts.upsert(radioContact(10));
      await attachAndSync();
      store.contacts.upsert(store.contacts.get(radioA, keyN(1))!.copyWith(lastHeardMs: 5000));
      store.contacts.upsert(store.contacts.get(radioA, keyN(2))!.copyWith(lastHeardMs: 9000));
      store.contacts.upsert(store.contacts.get(radioA, keyN(3))!.copyWith(favourite: true));
      store.messages.insert(ChatMessage(
          id: 'c4', radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(keyN(4).substring(0, 12)), direction: Direction.incoming,
          tsSender: 1, tsLocalMs: clock.ms, text: 'hi', state: MessageState.received, dedupeKey: 'k4'));
      final notice = cm.notices.first;
      await cm.ensureOnRadio(keyN(10));
      expect(port.removes, [keyN(1)]);
      expect(port.table.containsKey(keyN(10)), isTrue);
      expect(store.contacts.get(radioA, keyN(1)), isNotNull, reason: 'still in the phone\'s book');
      expect(store.contacts.get(radioA, keyN(1))!.onRadio, isFalse);
      expect((await notice).message, allOf(contains('Node 1'), contains('still in your contacts')));
    });

    test('full and nothing can go (all favourites): ContactTableFull and the state says full', () async {
      port.capacity = 2;
      port.radioAdd(radioContact(1, radioFlags: 1));
      port.radioAdd(radioContact(2, radioFlags: 1));
      store.contacts.upsert(radioContact(10));
      await attachAndSync();
      await expectLater(cm.ensureOnRadio(keyN(10)), throwsA(isA<ContactTableFull>()));
      expect(cm.state.tableFull, isTrue);
    });

    test('not linked: RadioUnavailable, not a crash', () async {
      store.contacts.upsert(radioContact(1));
      await attachAndSync();
      port.isConnected = false;
      await expectLater(cm.ensureOnRadio(keyN(1)), throwsA(isA<RadioUnavailable>()));
    });
  });

  group('pushes', () {
    test('path updated: the radio\'s route is read back for that contact', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      port.radioAdd(radioContact(1, path: true));
      await cm.pathUpdated(keyN(1));
      expect(store.contacts.get(radioA, keyN(1))!.hasPath, isTrue);
      expect(port.downloads, hasLength(1), reason: 'one contact, not the whole list');
    });

    test('a node the radio added by itself (key-only ADVERT) is read back; a known contact is refreshed at most every 10 minutes', () async {
      cm.attach(port);
      port.radioAdd(radioContact(5));
      await cm.advertHeard(keyN(5));
      expect(store.contacts.get(radioA, keyN(5))!.name, 'Node 5');
      port.radioAdd(radioContact(5, name: 'Renamed'));
      await cm.advertHeard(keyN(5));
      expect(store.contacts.get(radioA, keyN(5))!.name, 'Node 5', reason: 'too soon');
      clock.advance(11 * 60 * 1000);
      await cm.advertHeard(keyN(5));
      expect(store.contacts.get(radioA, keyN(5))!.name, 'Renamed');
    });

    test('contact deleted (the radio replaced it) keeps the phone copy; contacts full sets the state', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      cm.radioDropped(keyN(1));
      expect(store.contacts.get(radioA, keyN(1))!.onRadio, isFalse);
      expect(cm.state.radioCount, 0);
      cm.radioFull();
      expect(cm.state.tableFull, isTrue);
    });
  });

  group('New nodes nearby', () {
    void heard(int n, {String? name, int adv = 1760000500}) => store.adverts.record(AdvertSeen(
        radioId: radioA, publicKey: keyN(n), type: ContactType.repeater, name: name ?? 'Hill $n', lat: 40, lon: -83, firstTsMs: 1, lastTsMs: 1000 + n, advertTs: adv));

    test('heard but not added: listed newest first; contacts and ignored ones are not', () async {
      cm.attach(port);
      heard(1);
      heard(2);
      heard(3);
      heard(4, name: '');
      store.contacts.upsert(radioContact(3));
      cm.ignoreNearby(keyN(2));
      expect([for (final a in cm.nearby()) a.publicKey], [keyN(1)]);
      expect(cm.ignored().single.publicKey, keyN(2));
      cm.restoreIgnored(keyN(2));
      expect([for (final a in cm.nearby()) a.publicKey], [keyN(2), keyN(1)]);
    });

    test('Add: the contact is stored, goes on the radio with the ADVERT\'s own timestamp, and leaves the nearby list', () async {
      cm.attach(port);
      heard(1, adv: 1760000500);
      final r = await cm.addNearby(cm.nearby().single);
      expect(r.ok, isTrue);
      expect(r.onRadio, isTrue);
      expect(port.table[keyN(1)]!.lastAdvertTs, 1760000500, reason: 'never the phone clock, or the radio would reject the next real advert as a replay');
      expect(cm.nearby(), isEmpty);
      expect(store.contacts.get(radioA, keyN(1))!.source, ContactSource.discovered);
    });

    test('Add with the radio away: saved, honest note, goes on at the next sync', () async {
      cm.attach(port);
      heard(1);
      port.isConnected = false;
      final r = await cm.addNearby(cm.nearby().single);
      expect(r.ok, isTrue);
      expect(r.onRadio, isFalse);
      expect(r.note, contains('next time it connects'));
      port.isConnected = true;
      await cm.syncNow();
      expect(port.table.containsKey(keyN(1)), isTrue);
    });
  });

  group('adding by link, key or scan', () {
    test('contact link', () async {
      cm.attach(port);
      final r = await cm.addFromLink('meshcore://contact/add?name=Sam%20K8SAM&public_key=${keyN(8)}&type=2');
      expect(r.ok, isTrue);
      expect(r.created, isTrue);
      expect(r.contact!.name, 'Sam K8SAM');
      expect(r.contact!.type, ContactType.repeater);
      expect(r.contact!.source, ContactSource.imported);
      expect(port.table.containsKey(keyN(8)), isTrue);
      final again = await cm.addFromLink('meshcore://contact/add?name=Sam&public_key=${keyN(8)}&type=2');
      expect(again.created, isFalse, reason: 'adding the same contact twice is not an error and not a second row');
      expect(book(), hasLength(1));
    });

    test('plain-language errors, never an exception: junk, wrong link kind, short key, own key', () async {
      cm.attach(port);
      expect((await cm.addFromLink('hello')).error, contains('not a MeshCore link'));
      expect((await cm.addFromLink('')).error, contains('Nothing to add'));
      final ch = await cm.addFromLink('meshcore://channel/add?name=Ohio&secret=${'ab' * 16}');
      expect(ch.isChannelLink, isTrue);
      expect(ch.error, contains('Channels'));
      expect((await cm.addByKey('abc')).error, contains('64 characters'));
      expect((await cm.addByKey('zz' * 32)).error, contains('64 characters'));
      expect((await cm.addByKey(radioA)).error, contains('your own radio'));
      expect((await cm.addFromLink('meshcore://contact/add?name=X&public_key=${'0' * 63}')).error, contains('not valid'));
      expect(book(), isEmpty);
    });

    test('pasted key with spaces and capitals', () async {
      cm.attach(port);
      final spaced = keyN(0xab).toUpperCase().replaceAllMapped(RegExp('.{8}'), (m) => '${m[0]} ');
      final r = await cm.addByKey(spaced, name: 'Pat');
      expect(r.ok, isTrue);
      expect(r.contact!.publicKey, keyN(0xab));
    });

    test('advert link: parsed, saved with the advert\'s name and time, handed to the radio to verify', () async {
      cm.attach(port);
      final raw = buildUnsignedAdvertPacket(Uint8List.fromList(List.filled(32, 0x44)), type: 2, name: 'Ridge', timestamp: 1760000600, lat: 40, lon: -83);
      final r = await cm.addFromLink('meshcore://${raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      expect(r.ok, isTrue);
      expect(r.contact!.name, 'Ridge');
      expect(r.contact!.lastAdvertTs, 1760000600);
      expect(port.imports, hasLength(1));
      final bad = await cm.addFromLink('meshcore://${'11' * 120}');
      expect(bad.error, contains('valid MeshCore advert'));
    });

    test('before any radio was ever connected there is nowhere to put a contact: says so', () async {
      final r = await cm.addByKey(keyN(1));
      expect(r.error, contains('Connect your radio once'));
    });
  });

  group('remove, route, favourites, share', () {
    test('remove: gone from the phone and the radio; with the radio away it is remembered and done later, and it does not come back', () async {
      port.radioAdd(radioContact(1));
      port.radioAdd(radioContact(2));
      await attachAndSync();
      port.isConnected = false;
      await cm.remove(keyN(1));
      expect(store.contacts.get(radioA, keyN(1)), isNull);
      expect(cm.pendingRemovals, {keyN(1)});
      expect(port.table.containsKey(keyN(1)), isTrue);
      port.isConnected = true;
      await cm.syncNow(full: true);
      expect(port.table.containsKey(keyN(1)), isFalse);
      expect(store.contacts.get(radioA, keyN(1)), isNull, reason: 'the radio\'s copy did not resurrect it');
      expect(cm.pendingRemovals, isEmpty);
      await cm.remove(keyN(2));
      expect(port.removes, contains(keyN(2)));
      expect(cm.state.radioCount, 0);
    });

    test('adding a contact again cancels its pending removal', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      port.isConnected = false;
      await cm.remove(keyN(1));
      await cm.addByKey(keyN(1), name: 'Back');
      expect(cm.pendingRemovals, isEmpty);
    });

    test('reset path: forgotten on the phone and the radio', () async {
      port.radioAdd(radioContact(1, path: true));
      await attachAndSync();
      expect(store.contacts.get(radioA, keyN(1))!.hasPath, isTrue);
      await cm.resetPath(keyN(1));
      expect(store.contacts.get(radioA, keyN(1))!.hasPath, isFalse);
      expect(port.resets, [keyN(1)]);
    });

    test('favourite pushes the radio flag; unfavourite clears it', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      cm.setFavourite(keyN(1), true);
      await Future<void>.delayed(Duration.zero);
      expect(port.table[keyN(1)]!.radioFlags & 1, 1);
      cm.setFavourite(keyN(1), false);
      await Future<void>.delayed(Duration.zero);
      expect(port.table[keyN(1)]!.radioFlags & 1, 0);
    });

    test('a favourite changed while the radio was away is pushed at the next sync', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      cm.detach();
      cm.setFavourite(keyN(1), true);
      cm.attach(port);
      await cm.syncNow();
      expect(port.table[keyN(1)]!.radioFlags & 1, 1);
    });

    test('link text for sharing is a contact link that parses back to the same contact', () async {
      port.radioAdd(radioContact(1, name: 'Ann KE8ANN'));
      await attachAndSync();
      final link = cm.linkFor(store.contacts.get(radioA, keyN(1))!);
      cm.detach();
      final cm2 = ContactManager(store: ChatStore.inMemory(), nowMs: clock.call);
      final back = await (cm2..attach(port)).addFromLink(link);
      expect(back.contact!.publicKey, keyN(1));
      expect(back.contact!.name, 'Ann KE8ANN');
      cm2.dispose();
    });

    test('share to nearby radios needs a link; says no when the radio holds no advert for the contact', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      expect(await cm.shareToNearbyRadios(keyN(1)), isFalse);
      port.hasAdvert = {keyN(1)};
      expect(await cm.shareToNearbyRadios(keyN(1)), isTrue);
    });
  });

  group('cleanup suggestions', () {
    test('never favourites, conversations or messages in flight; oldest first; reasons in words', () async {
      for (var i = 1; i <= 6; i++) {
        port.radioAdd(radioContact(i));
      }
      await attachAndSync();
      final now = clock.ms;
      store.contacts.upsert(store.contacts.get(radioA, keyN(1))!.copyWith(lastHeardMs: now - 40 * 86400000));
      store.contacts.upsert(store.contacts.get(radioA, keyN(2))!.copyWith(lastHeardMs: now - 3 * 86400000, type: ContactType.repeater));
      store.contacts.upsert(store.contacts.get(radioA, keyN(3))!.copyWith(favourite: true));
      store.contacts.upsert(store.contacts.get(radioA, keyN(4))!.copyWith(lastHeardMs: now - 90 * 86400000));
      store.contacts.upsert(store.contacts.get(radioA, keyN(5))!.copyWith(lastHeardMs: now - 80 * 86400000));
      store.contacts.upsert(store.contacts.get(radioA, keyN(6))!.copyWith(lastHeardMs: null, lastAdvertTs: null));
      ChatMessage msg(String id, int n, MessageState s) => ChatMessage(
          id: id, radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(keyN(n).substring(0, 12)), direction: Direction.outgoing,
          tsSender: 1, tsLocalMs: now, text: id, state: s, dedupeKey: id);
      store.messages.insert(msg('m4', 4, MessageState.acked)); // has a conversation
      store.messages.insert(msg('m5', 5, MessageState.sending)); // in flight
      final s = cm.cleanupSuggestions();
      expect([for (final c in s) c.contact.publicKey], [keyN(6), keyN(1), keyN(2)]);
      expect(s[0].reason, 'Never heard on this phone');
      expect(s[1].reason, 'Last heard 40 days ago');
      expect(s[2].reason, 'Last heard 3 days ago, a repeater');
      expect(await cm.removeFromRadio([keyN(6), keyN(1)]), 2);
      expect(store.contacts.get(radioA, keyN(1)), isNotNull);
      expect(store.contacts.get(radioA, keyN(1))!.onRadio, isFalse);
      expect(cm.state.tableFull, isFalse);
    });
  });

  group('what the radio does with new nodes (policy)', () {
    test('the one-time offer: only while the radio auto-adds everything and the user has not answered', () async {
      port.radioAdd(radioContact(1));
      await attachAndSync();
      expect(cm.shouldOfferAskFirst, isTrue);
      cm.answerPolicyPrompt('keep');
      expect(cm.shouldOfferAskFirst, isFalse);
      expect(cm.policyPromptAnswer, 'keep');
    });

    test('no offer when the radio already asks, or does not say', () async {
      port.policy = const ContactPolicy(askBeforeAdding: true);
      await attachAndSync();
      expect(cm.shouldOfferAskFirst, isFalse);
    });

    test('setPolicy goes to the radio and into the state', () async {
      await attachAndSync();
      await cm.setPolicy(port.policy.copyWith(askBeforeAdding: true, autoAddRepeaters: true));
      expect(port.policy.askBeforeAdding, isTrue);
      expect(cm.state.policy!.autoAddRepeaters, isTrue);
      cm.detach();
      await expectLater(cm.setPolicy(port.policy), throwsA(isA<RadioUnavailable>()));
    });
  });

  test('automatic syncs are held back while a drive runs; a button press is not', () async {
    var driving = true;
    final held = ContactManager(store: ChatStore.inMemory(), nowMs: clock.call, shouldDefer: () => driving);
    port.radioAdd(radioContact(1));
    held.attach(port);
    await held.syncNow(auto: true);
    expect(port.downloads, isEmpty);
    await held.syncNow();
    expect(port.downloads, hasLength(1));
    driving = false;
    await held.syncNow(auto: true);
    expect(port.downloads, hasLength(2));
    held.dispose();
  });

  test('a second syncNow while one runs joins it (one download, not two)', () async {
    for (var i = 1; i <= 40; i++) {
      port.radioAdd(radioContact(i));
    }
    cm.attach(port);
    await Future.wait([cm.syncNow(), cm.syncNow(), cm.syncNow()]);
    expect(port.downloads, hasLength(1));
  });

  // Random interleavings of everything a user and a radio can do, then check the invariants that must always hold.
  for (var seed = 0; seed < 25; seed++) {
    test('property (seed $seed): random operations keep the book and the radio table consistent', () async {
      final rnd = Random(seed);
      final st = ChatStore.inMemory();
      final p = FakeRadioPort(capacity: 20 + rnd.nextInt(20));
      final m = ContactManager(store: st, nowMs: clock.call);
      for (var i = 1; i <= 15; i++) {
        p.radioAdd(radioContact(i));
      }
      m.attach(p);
      final userAdded = <String>{};
      final removed = <String>{};
      for (var step = 0; step < 60; step++) {
        final n = 1 + rnd.nextInt(60);
        switch (rnd.nextInt(10)) {
          case 0:
            p.radioAdd(radioContact(n));
            removed.remove(keyN(n)); // a fresh advert after the removal is a new contact, the radio may add it again
          case 1:
            await m.addByKey(keyN(n), name: 'User $n');
            userAdded.add(keyN(n));
            removed.remove(keyN(n));
          case 2:
            await m.remove(keyN(n));
            removed.add(keyN(n));
            userAdded.remove(keyN(n));
          case 3:
            p.dropAfter = rnd.nextInt(10);
            await m.syncNow();
          case 4:
            p.isConnected = rnd.nextBool();
          case 5:
            if (st.contacts.get(radioA, keyN(n)) != null) m.setFavourite(keyN(n), rnd.nextBool());
          case 6:
            if (p.table.isNotEmpty) {
              final k = p.table.keys.elementAt(rnd.nextInt(p.table.length));
              p.table.remove(k);
              p.lastMod.remove(k);
            }
          case 7:
            p.radioTouch(keyN(n));
          default:
            await m.syncNow(full: rnd.nextInt(4) == 0);
        }
        expect(p.table.length, lessThanOrEqualTo(p.capacity!), reason: 'seed $seed step $step');
      }
      p.isConnected = true;
      p.dropAfter = null;
      await m.syncNow(full: true);
      // after a complete read the book agrees with the radio about what is on it...
      expect({for (final c in st.contacts.list(radioA)) if (c.onRadio) c.publicKey}, p.table.keys.toSet(), reason: 'seed $seed');
      // ... nothing the user deleted came back and nothing the user added was lost
      for (final k in removed) {
        expect(st.contacts.get(radioA, k), isNull, reason: 'removed $k came back (seed $seed)');
      }
      for (final k in userAdded) {
        expect(st.contacts.get(radioA, k), isNotNull, reason: 'added $k vanished (seed $seed)');
      }
      m.dispose();
    });
  }
}
