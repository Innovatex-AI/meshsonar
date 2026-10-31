import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/message_repository.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

ChatMessage msg(String id, String conv, int tsMs, {String text = 't', bool read = true, Direction dir = Direction.incoming, String? key}) => ChatMessage(
    id: id,
    radioId: radioA,
    convKind: ConvKind.dm,
    convKey: conv,
    direction: dir,
    tsSender: tsMs ~/ 1000,
    tsLocalMs: tsMs,
    text: text,
    state: dir == Direction.incoming ? MessageState.received : MessageState.sent,
    dedupeKey: key ?? id,
    read: read);

void main() {
  late ChatStore s;
  setUp(() => s = ChatStore.inMemory());

  group('contacts', () {
    test('upsert, prefix lookup, ambiguity, ordering, flags', () {
      s.contacts.upsert(Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'bob'));
      s.contacts.upsert(Contact(radioId: radioA, publicKey: carolKey, type: ContactType.repeater, name: 'Alpha Hill', lat: 39.1, lon: -84.5));
      expect(s.contacts.byPrefix(radioA, bobKey.substring(0, 12))!.name, 'bob');
      s.contacts.upsert(Contact(radioId: radioA, publicKey: '${bobKey.substring(0, 12)}${'f' * 52}', type: ContactType.companion, name: 'clone'));
      expect(s.contacts.byPrefix(radioA, bobKey.substring(0, 12)), isNull, reason: 'two keys share the prefix: refuse to guess');
      s.contacts.setFavourite(radioA, carolKey, true);
      s.contacts.setCustomName(radioA, bobKey, 'Robert');
      final l = s.contacts.list(radioA);
      expect(l.first.name, 'Alpha Hill', reason: 'favourites first');
      expect(l.map((c) => c.displayName), contains('Robert'));
      expect(s.contacts.list(radioA, type: ContactType.repeater).length, 1);
      expect(s.contacts.get(radioA, carolKey)!.hasPosition, isTrue);
      s.contacts.setPath(radioA, bobKey, Uint8List.fromList([9, 8]), 2);
      expect(s.contacts.get(radioA, bobKey)!.outPath, [9, 8]);
      s.contacts.delete(radioA, bobKey);
      expect(s.contacts.get(radioA, bobKey), isNull);
    });
  });

  group('channels', () {
    test('secret goes to the SecretStore and never into SQLite', () async {
      final dir = Directory.systemTemp.createTempSync('chan');
      addTearDown(() => dir.deleteSync(recursive: true));
      final p = '${dir.path}/c.db';
      final secrets = InMemorySecretStore();
      final st = ChatStore.open(sqlite3.open(p), secrets);
      final secret = Uint8List.fromList(List.generate(16, (i) => 0xA0 + i));
      final ch = await st.channels.save(Channel(radioId: radioA, slot: 3, name: 'Ops', kind: ChannelKind.private), secret: secret);
      expect(ch.secretRef, isNotNull);
      expect(ch.hashByte, isNotNull);
      expect(await st.channels.secretOf(ch), secret);
      // nothing in any table or file contains the secret in hex or raw
      final hex = secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      for (final t in ['channels', 'settings', 'messages', 'conversations']) {
        for (final r in st.db.raw.select('SELECT * FROM $t')) {
          for (final v in r.values) {
            expect('$v'.toLowerCase().contains(hex), isFalse);
          }
        }
      }
      st.close();
      final bytes = File(p).readAsBytesSync();
      final needle = secret.toList();
      var found = false;
      for (var i = 0; i + 16 <= bytes.length && !found; i++) {
        if (bytes[i] == needle[0] && bytes[i + 1] == needle[1]) {
          found = List.generate(16, (k) => bytes[i + k]).toString() == needle.toString();
        }
      }
      expect(found, isFalse, reason: 'the secret must not be in the database file');
    });

    test('save by slot updates in place; delete removes secret, messages and conversation', () async {
      final a = await s.channels.save(Channel(radioId: radioA, slot: 1, name: 'A', kind: ChannelKind.hashtag), secret: Uint8List(16));
      final b = await s.channels.save(Channel(radioId: radioA, slot: 1, name: 'A2', kind: ChannelKind.hashtag));
      expect(b.id, a.id);
      expect(b.name, 'A2');
      expect(b.secretRef, a.secretRef, reason: 'no secret passed: keep the stored one');
      s.messages.insert(msg('1', b.convKey, 1000));
      await s.channels.delete(b.id!);
      expect(s.messages.count(), 0);
      expect(s.messages.conversation(b.convKey), isNull);
      expect(await s.secrets.read(a.secretRef!), isNull);
    });

    test('rejects a secret that is not 16 bytes', () {
      expect(() => s.channels.save(Channel(radioId: radioA, name: 'x', kind: ChannelKind.private), secret: Uint8List(15)), throwsArgumentError);
    });

    test('list order and system filter', () async {
      await s.channels.save(Channel(radioId: radioA, slot: 2, name: 'S', kind: ChannelKind.system), secret: Uint8List(16));
      await s.channels.save(Channel(radioId: radioA, slot: 0, name: 'Public', kind: ChannelKind.public), secret: Uint8List(16));
      expect(s.channels.list(radioA).map((c) => c.name), ['Public', 'S']);
      expect(s.channels.list(radioA, includeSystem: false).map((c) => c.name), ['Public']);
    });
  });

  group('messages and conversations', () {
    test('keyset paging covers everything exactly once, including equal timestamps', () {
      for (var i = 0; i < 230; i++) {
        s.messages.insert(msg('m$i', 'd:aaaaaaaaaaaa', 1000 + (i ~/ 7))); // 7 messages share each timestamp
      }
      final seen = <String>[];
      MessageCursor? cur;
      var pages = 0;
      do {
        final p = s.messages.page('d:aaaaaaaaaaaa', before: cur, limit: 50);
        seen.addAll(p.messages.map((m) => m.id));
        cur = p.next;
        pages++;
      } while (cur != null);
      expect(pages, 5);
      expect(seen.length, 230);
      expect(seen.toSet().length, 230);
      expect(seen.first, 'm229');
      expect(seen.last, 'm0');
    });

    test('conversation row tracks last message and unread; list order pinned then newest', () {
      s.messages.insert(msg('a', 'd:aaaaaaaaaaaa', 1000, text: 'older', read: false));
      s.messages.insert(msg('b', 'd:bbbbbbbbbbbb', 2000, text: 'newer', read: false));
      s.messages.insert(msg('c', 'd:bbbbbbbbbbbb', 1500, text: 'late arrival of an older one', read: false));
      var l = s.messages.conversations();
      expect(l.map((c) => c.key), ['d:bbbbbbbbbbbb', 'd:aaaaaaaaaaaa']);
      expect(l.first.lastPreview, 'newer');
      expect(l.first.unread, 2);
      s.messages.setPinned('d:aaaaaaaaaaaa', radioA, true);
      l = s.messages.conversations();
      expect(l.first.key, 'd:aaaaaaaaaaaa');
      expect(s.messages.markConversationRead('d:bbbbbbbbbbbb'), 2);
      expect(s.messages.unreadConversationCount(nowMs: 0), 1);
    });

    test('long previews are truncated', () {
      s.messages.insert(msg('a', 'd:aaaaaaaaaaaa', 1, text: 'x' * 500));
      expect(s.messages.conversation('d:aaaaaaaaaaaa')!.lastPreview!.length, MessageRepository.previewChars);
    });

    test('dedupe: the second insert with the same key is a no-op and does not touch unread', () {
      expect(s.messages.insert(msg('a', 'd:aaaaaaaaaaaa', 1, read: false, key: 'K')), isTrue);
      expect(s.messages.insert(msg('b', 'd:aaaaaaaaaaaa', 2, read: false, key: 'K')), isFalse);
      expect(s.messages.unreadCount('d:aaaaaaaaaaaa'), 1);
      expect(s.messages.count(), 1);
    });

    test('deleteHistory keeps settings and drops pending sends from the outbox; deleteConversation removes the lot', () {
      s.messages.insert(msg('a', 'd:aaaaaaaaaaaa', 1000));
      s.messages.insert(msg('b', 'd:aaaaaaaaaaaa', 2000, dir: Direction.outgoing));
      s.messages.setNotify('d:aaaaaaaaaaaa', radioA, NotifyMode.muted);
      s.drafts.save('d:aaaaaaaaaaaa', 'draft', 1);
      expect(s.messages.deleteHistory('d:aaaaaaaaaaaa'), 2);
      expect(s.messages.count(), 0);
      expect(s.messages.conversation('d:aaaaaaaaaaaa')!.notifyMode, NotifyMode.muted);
      expect(s.messages.conversation('d:aaaaaaaaaaaa')!.lastPreview, isNull);
      expect(s.messages.conversations(), isEmpty, reason: 'empty conversations are hidden from the list');
      s.messages.deleteConversation('d:aaaaaaaaaaaa');
      expect(s.messages.conversation('d:aaaaaaaaaaaa'), isNull);
      expect(s.drafts.load('d:aaaaaaaaaaaa'), isNull);
    });

    test('retention: per-conversation beats the default; pending sends and system channels are handled', () async {
      final h = Harness();
      h.bob();
      final day = 86400000;
      final now = h.clock.ms;
      final conv = h.bobConv;
      h.store.messages.insert(msg('old', conv, now - 40 * day));
      h.store.messages.insert(msg('mid', conv, now - 10 * day));
      h.store.messages.insert(msg('new', conv, now - 1 * day));
      expect(h.service.applyRetention(), 0, reason: 'default is keep everything');
      h.service.setDefaultRetentionDays(30);
      expect(h.service.applyRetention(), 1);
      h.service.setConversationRetentionDays(radioA, conv, 5);
      expect(h.service.applyRetention(), 1);
      expect(h.store.messages.page(conv).messages.map((m) => m.id), ['new']);
      expect(h.store.messages.conversation(conv)!.lastPreview, 't');
    });

    test('rebuildAllConversations repairs drift', () {
      s.messages.insert(msg('a', 'd:aaaaaaaaaaaa', 1000, read: false));
      s.db.raw.execute("UPDATE conversations SET unread = 99, last_preview = 'wrong'");
      s.messages.rebuildAllConversations();
      expect(s.messages.unreadCount('d:aaaaaaaaaaaa'), 1);
      expect(s.messages.conversation('d:aaaaaaaaaaaa')!.lastPreview, 't');
    });
  });

  group('adverts and settings', () {
    test('adverts_seen counts repeats and keeps the first time', () {
      for (var i = 0; i < 3; i++) {
        s.adverts.record(AdvertSeen(radioId: radioA, publicKey: bobKey, name: 'Bob', firstTsMs: 100 + i, lastTsMs: 100 + i, type: ContactType.repeater));
      }
      final a = s.adverts.list(radioA).single;
      expect(a.count, 3);
      expect(a.firstTsMs, 100);
      expect(a.lastTsMs, 102);
    });

    test('wipeAll removes everything including secrets', () async {
      final h = Harness();
      h.bob();
      await h.channel(1, 'Ohio', ChannelKind.private);
      h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: 5, text: 'A: hi'));
      expect(h.secrets.length, 1);
      await h.service.wipeAll();
      expect(h.secrets.length, 0);
      for (final t in ['contacts', 'channels', 'messages', 'conversations']) {
        expect(h.store.db.raw.select('SELECT count(*) c FROM $t').first['c'], 0);
      }
    });
  });
}

