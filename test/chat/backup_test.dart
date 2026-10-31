import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/backup.dart';
import 'package:meshsonar/chat/backup_crypto.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';

import 'support.dart';

const _secretHex = '0102030405060708090a0b0c0d0e0f10';

/// A populated harness: contacts, three channels (one system, one private with a secret), conversations, messages, drafts.
Future<Harness> populated({int burnChannelIds = 0}) async {
  final h = Harness();
  for (var i = 0; i < burnChannelIds; i++) {
    final c = await h.store.channels.save(Channel(radioId: radioA, slot: 20 + i, name: 'burn$i', kind: ChannelKind.private));
    await h.store.channels.delete(c.id!);
  }
  h.bob(path: true);
  h.store.contacts.setFavourite(radioA, bobKey, true);
  await h.store.channels.save(Channel(radioId: radioA, slot: 0, name: 'Public', kind: ChannelKind.public), secret: Uint8List.fromList(List.filled(16, 0x8b)));
  await h.store.channels.save(Channel(radioId: radioA, slot: 1, name: 'Ohio Ops', kind: ChannelKind.private), secret: fromHex(_secretHex));
  await h.store.channels.save(Channel(radioId: radioA, slot: 2, name: '#wardriving', kind: ChannelKind.system), secret: Uint8List(16));
  final ops = h.store.channels.bySlot(radioA, 1)!;
  h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: 100, text: 'Ann: ☕ coffee at the tower', snr: 4.5, pathLen: 1));
  h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 2, timestamp: 101, text: 'X: MS:abc1234567'));
  h.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: 102, text: 'dm from bob'));
  h.service.send(radioId: radioA, convKey: h.bobConv, text: 'reply to bob');
  h.service.send(radioId: radioA, convKey: ops.convKey, text: 'hello ops');
  h.service.saveDraft(h.bobConv, 'unsent draft');
  h.service.setNotifyMode(radioA, ops.convKey, NotifyMode.muted);
  h.service.setDefaultRetentionDays(90);
  return h;
}

ChatBackup backupOf(Harness h) => ChatBackup(h.store, nowMs: h.clock.call, appVersion: '9.9.9', newId: () => 'imp${h.clock.ms++}');

void main() {
  test('round trip into a fresh device: contacts, channels, messages, settings, drafts', () async {
    final src = await populated(burnChannelIds: 4); // channel ids differ between the devices on purpose
    final bytes = await backupOf(src).export(const BackupOptions(), file: BackupFile.zip);

    final dst = Harness();
    final rep = await backupOf(dst).import(bytes);
    expect(rep.contacts, 1);
    expect(rep.channels, 3);
    expect(rep.messages, 4, reason: '2 in + 2 out; system traffic excluded');
    expect(rep.skipped, 0);

    expect(dst.store.contacts.get(radioA, bobKey)!.favourite, isTrue);
    expect(dst.store.contacts.get(radioA, bobKey)!.outPath, [1, 2]);
    final ops = dst.store.channels.list(radioA).firstWhere((c) => c.name == 'Ohio Ops');
    expect(ops.slot, 1);
    final page = dst.service.page(ops.convKey).messages;
    expect(page.map((m) => m.text), containsAll(['☕ coffee at the tower', 'hello ops']));
    final ann = page.firstWhere((m) => m.senderName == 'Ann');
    expect(ann.snr, 4.5);
    expect(ann.pathLen, 1);
    expect(dst.service.loadDraft(dst.bobConv), 'unsent draft');
    expect(dst.service.conversation(ops.convKey)!.notifyMode, NotifyMode.muted);
    expect(dst.service.defaultRetentionDays, 90);
    expect(dst.store.messages.count(convKey: dst.store.channels.systemChannels(radioA).single.convKey), 0);
  });

  test('queued messages restore as failed(cancelled): a restore never re-sends an old queue', () async {
    final src = await populated();
    final dst = Harness();
    await backupOf(dst).import(await backupOf(src).export(const BackupOptions()));
    final outgoing = dst.store.messages.page(dst.bobConv).messages.firstWhere((m) => m.isOutgoing);
    expect(outgoing.state, MessageState.failed);
    expect(outgoing.failReason, FailReason.cancelled);
    expect(dst.store.outbox.count(), 0);
  });

  test('restoring twice, or onto the same device, adds nothing', () async {
    final src = await populated();
    final bytes = await backupOf(src).export(const BackupOptions());
    final before = src.store.messages.count();
    final r1 = await backupOf(src).import(bytes);
    expect(r1.messages, 0);
    expect(r1.duplicateMessages, greaterThan(0));
    expect(src.store.messages.count(), before);
    expect(src.store.channels.list(radioA).length, 3);

    final dst = Harness();
    await backupOf(dst).import(bytes);
    final n = dst.store.messages.count();
    final r2 = await backupOf(dst).import(bytes);
    expect(r2.messages, 0);
    expect(dst.store.messages.count(), n);
  });

  test('after a restore, the same message arriving live is still recognised as a duplicate', () async {
    final src = await populated(burnChannelIds: 3);
    final dst = Harness();
    await backupOf(dst).import(await backupOf(src).export(const BackupOptions()));
    final n = dst.store.messages.count();
    dst.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: 100, text: 'Ann: ☕ coffee at the tower'));
    dst.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: 102, text: 'dm from bob'));
    expect(dst.store.messages.count(), n);
  });

  group('secrets', () {
    test('NOT in the file by default (json, zip or text search)', () async {
      final src = await populated();
      for (final f in BackupFile.values) {
        final bytes = await backupOf(src).export(const BackupOptions(), file: f);
        final text = f == BackupFile.zip ? utf8.decode(ZipDecoder().decodeBytes(bytes).files.single.content as List<int>) : utf8.decode(bytes);
        expect(text.contains(_secretHex), isFalse);
        expect(text.contains('"secret"'), isFalse);
        expect(jsonDecode(text)['includesSecrets'], false);
      }
    });

    test('opt in: included, restored into the SecretStore, private channel usable', () async {
      final src = await populated();
      final bytes = await backupOf(src).export(const BackupOptions(includeSecrets: true), file: BackupFile.json);
      expect(utf8.decode(bytes).contains(_secretHex), isTrue);
      final dst = Harness();
      final rep = await backupOf(dst).import(bytes);
      expect(rep.secretsRestored, greaterThanOrEqualTo(1));
      expect(rep.channelsNeedingSecret, isEmpty);
      final ops = dst.store.channels.list(radioA).firstWhere((c) => c.name == 'Ohio Ops');
      expect(toHex((await dst.store.channels.secretOf(ops))!), _secretHex);
    });

    test('without secrets: private channel is reported as needing its key; public and hashtag secrets are re-derived', () async {
      final src = await populated();
      await src.store.channels.save(Channel(radioId: radioA, slot: 5, name: '#ohio', kind: ChannelKind.hashtag), secret: Uint8List(16));
      final dst = Harness();
      final rep = await backupOf(dst).import(await backupOf(src).export(const BackupOptions()));
      expect(rep.channelsNeedingSecret, ['Ohio Ops']);
      final pub = dst.store.channels.list(radioA).firstWhere((c) => c.kind == ChannelKind.public);
      expect(toHex((await dst.store.channels.secretOf(pub))!), '8b3387e9c5cdea6ac9e5edbaa115cd72');
      final tag = dst.store.channels.list(radioA).firstWhere((c) => c.kind == ChannelKind.hashtag);
      expect(await dst.store.channels.secretOf(tag), isNotNull);
    });
  });

  group('encrypted export', () {
    test('round trip with a passphrase; the file reveals no content', () async {
      final src = await populated();
      final bytes = await backupOf(src).export(const BackupOptions(includeSecrets: true), passphrase: 'correct horse', kdfIterations: 2000, useIsolate: false);
      final text = utf8.decode(bytes);
      expect(text.contains('coffee'), isFalse);
      expect(text.contains(_secretHex), isFalse);
      expect(text.contains('Ohio Ops'), isFalse);
      expect(jsonDecode(text)['kdf']['iterations'], 2000);
      final dst = Harness();
      final rep = await backupOf(dst).import(bytes, passphrase: 'correct horse', useIsolate: false);
      expect(rep.messages, 4);
      expect(rep.secretsRestored, greaterThanOrEqualTo(1));
    });

    test('wrong passphrase, missing passphrase, tampering and truncation are all refused without touching the store', () async {
      final src = await populated();
      final bytes = await backupOf(src).export(const BackupOptions(), passphrase: 'pw', kdfIterations: 1000, useIsolate: false, file: BackupFile.json);
      final dst = Harness();
      final b = backupOf(dst);
      await expectLater(b.import(bytes, passphrase: 'nope', useIsolate: false), throwsA(isA<BackupWrongPassphrase>()));
      await expectLater(b.import(bytes), throwsA(isA<BackupNeedsPassphrase>()));
      final env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final data = base64.decode(env['data'] as String);
      data[data.length ~/ 2] ^= 1;
      env['data'] = base64.encode(data);
      await expectLater(b.import(Uint8List.fromList(utf8.encode(jsonEncode(env))), passphrase: 'pw', useIsolate: false), throwsA(isA<BackupWrongPassphrase>()));
      env['kdf']['iterations'] = 999999999;
      await expectLater(b.import(Uint8List.fromList(utf8.encode(jsonEncode(env))), passphrase: 'pw', useIsolate: false), throwsA(isA<BackupFormatException>()), reason: 'a hostile iteration count must not hang the app');
      await expectLater(b.import(bytes.sublist(0, 40), passphrase: 'pw', useIsolate: false), throwsA(isA<BackupFormatException>()));
      expect(dst.store.messages.count(), 0);
      expect(dst.store.contacts.count(radioA), 0);
    });

    test('the isolate path works too (low iterations)', () async {
      final src = await populated();
      final bytes = await backupOf(src).export(const BackupOptions(), passphrase: 'pw', kdfIterations: 1000);
      final rep = await backupOf(Harness()).import(bytes, passphrase: 'pw');
      expect(rep.messages, 4);
    });

    test('fresh salt and nonce every time', () async {
      final src = await populated();
      final a = jsonDecode(utf8.decode(await backupOf(src).export(const BackupOptions(), passphrase: 'pw', kdfIterations: 1000, useIsolate: false)));
      final b = jsonDecode(utf8.decode(await backupOf(src).export(const BackupOptions(), passphrase: 'pw', kdfIterations: 1000, useIsolate: false)));
      expect(a['nonce'], isNot(b['nonce']));
      expect(a['kdf']['salt'], isNot(b['kdf']['salt']));
    });
  });

  group('hostile files', () {
    Future<Object?> tryImport(Object content) async {
      final dst = Harness();
      final bytes = content is Uint8List ? content : Uint8List.fromList(utf8.encode(content is String ? content : jsonEncode(content)));
      try {
        final r = await backupOf(dst).import(bytes);
        return r;
      } catch (e) {
        return e;
      }
    }

    test('garbage is a clean BackupFormatException', () async {
      for (final c in [Uint8List(0), Uint8List.fromList([1, 2, 3]), 'not json', '[]', '{}', '{"format":"other","version":1}', '{"format":"meshsonar-chat-backup"}', 'PK\x03\x04junk']) {
        final r = await tryImport(c is String ? Uint8List.fromList(utf8.encode(c)) : c);
        expect(r, isA<BackupFormatException>(), reason: '$c');
      }
    });

    test('newer version refused with a message', () async {
      final r = await tryImport({'format': 'meshsonar-chat-backup', 'version': 2});
      expect(r, isA<BackupTooNew>());
    });

    test('wrong types and nonsense values are skipped and counted, not trusted', () async {
      final r = await tryImport({
        'format': 'meshsonar-chat-backup',
        'version': 1,
        'contacts': [
          {'publicKey': 12, 'radioId': radioA},
          {'publicKey': 'zz' * 32, 'radioId': radioA, 'type': 1, 'name': 'x'},
          {'publicKey': bobKey, 'radioId': radioA, 'type': 99, 'name': 'x'},
          'a string',
          null,
          {'publicKey': bobKey, 'radioId': radioA, 'type': 1, 'name': 'ok', 'lat': 'north', 'favourite': 'yes'},
        ],
        'channels': [
          {'id': 'one', 'radioId': radioA, 'name': 'x', 'kind': 'private'},
          {'id': 1, 'radioId': radioA, 'name': 'x', 'kind': 'weird'},
          {'id': 2, 'radioId': radioA, 'name': 'Good', 'kind': 'private', 'secret': 'nothex'},
        ],
        'messages': [
          {'convKey': 'c:2', 'radioId': radioA, 'text': 'hi', 'tsSender': 1, 'tsLocalMs': 1, 'convKind': 'channel', 'dir': 'in', 'state': 'bogus'},
          {'convKey': 'c:999', 'radioId': radioA, 'text': 'orphan', 'tsSender': 1, 'tsLocalMs': 1, 'convKind': 'channel'},
          {'convKey': 'd:zzzzzzzzzzzz', 'radioId': radioA, 'text': 'x', 'tsSender': 1, 'tsLocalMs': 1, 'convKind': 'dm'},
          {'convKey': 'c:2', 'radioId': radioA, 'text': 'x' * 6000, 'tsSender': 1, 'tsLocalMs': 1, 'convKind': 'channel'},
          {'convKey': 'c:2', 'radioId': radioA, 'text': 'wrongkind', 'tsSender': 1, 'tsLocalMs': 1, 'convKind': 'dm'},
          {'convKey': 'c:2', 'radioId': radioA, 'text': 5, 'tsSender': 1, 'tsLocalMs': 1, 'convKind': 'channel'},
          {'convKey': 'c:2', 'radioId': radioA, 'text': "'); DROP TABLE messages;--", 'tsSender': 2, 'tsLocalMs': 2, 'convKind': 'channel', 'dir': 'in'},
        ],
        'drafts': {'c:2': 'ok', 'junk': 'x', 'd:aaaaaaaaaaaa': 5},
      });
      expect(r, isA<ImportReport>());
      final rep = r as ImportReport;
      expect(rep.contacts, 1);
      expect(rep.channels, 1);
      expect(rep.messages, 2, reason: 'the first (unknown state defaults) and the SQL-looking text');
      expect(rep.skipped, greaterThanOrEqualTo(8));
    });

    test('lists that are far too long are refused before any work', () async {
      final r = await tryImport('{"format":"meshsonar-chat-backup","version":1,"contacts":[${List.filled(100001, '{}').join(',')}]}');
      expect(r, isA<BackupFormatException>());
    });

    test('zip with the wrong entry, or two entries, is refused', () async {
      final a = Archive()..addFile(ArchiveFile('evil.json', 2, utf8.encode('{}')));
      expect(await tryImport(Uint8List.fromList(ZipEncoder().encode(a))), isA<BackupFormatException>());
      final b = Archive()
        ..addFile(ArchiveFile('meshsonar-chat-backup.json', 2, utf8.encode('{}')))
        ..addFile(ArchiveFile('meshsonar-chat-backup.json', 2, utf8.encode('{}')));
      expect(await tryImport(Uint8List.fromList(ZipEncoder().encode(b))), isA<BackupFormatException>());
    });

    test('an import failure halfway leaves no half-imported messages when the structure is bad', () async {
      final dst = Harness();
      try {
        await backupOf(dst).import(Uint8List.fromList(utf8.encode('{"format":"meshsonar-chat-backup","version":1,"contacts":[],"messages":"nope"}')));
      } catch (_) {}
      expect(dst.store.messages.count(), 0);
    });
  });

  test('export of a big store is chunked and complete', () async {
    final h = Harness();
    h.bob();
    h.store.db.transaction(() {
      for (var i = 0; i < 5000; i++) {
        h.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: i, text: 'm$i'));
      }
    });
    final dst = Harness();
    final rep = await backupOf(dst).import(await backupOf(h).export(const BackupOptions()));
    expect(rep.messages, 5000);
  });

  test('messages can be left out', () async {
    final src = await populated();
    final dst = Harness();
    final rep = await backupOf(dst).import(await backupOf(src).export(const BackupOptions(includeMessages: false)));
    expect(rep.messages, 0);
    expect(rep.contacts, 1);
    expect(rep.channels, 3);
  });
}
