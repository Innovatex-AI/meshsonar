// CR3 (chat + radio round): every heard copy of a channel message (repeats of ours, extra paths of theirs), the route a sent
// DM actually used, and the radio-side listener that decrypts group texts from the rx log.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_copy_listener.dart';
import 'package:meshsonar/chat/db/migrations.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart' show RxPacket;
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

InboundRepeatHeard copy(int ts, String text, String path, {int slot = 1, double? snr, int? rssi, int heardMs = 0}) => InboundRepeatHeard(
    radioId: radioA, channelSlot: slot, timestamp: ts, text: text, pathHashes: path, hops: path.length ~/ 2, snr: snr, rssi: rssi, heardMs: heardMs);

Uint8List groupPacket(List<int> secret, int ts, String sender, String text, List<int> hops) => MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.grpTxt),
      pathLenByte: hops.length,
      path: [for (final h in hops) Uint8List.fromList([h])],
      payload: buildGroupTextPayload(secret, ts, sender, text),
    ).toBytes();

void main() {
  group('migration v4', () {
    test('adds message_repeats (deleted with its message) and the sent route columns; re-running is harmless', () {
      final db = sqlite3.openInMemory();
      expect(migrateDatabase(db, chatMigrations), chatMigrations.last.version);
      final cols = db.select('PRAGMA table_info(messages)').map((r) => r['name']).toSet();
      expect(cols, containsAll(['sent_path', 'sent_hash_size']));
      expect(db.select("SELECT name FROM sqlite_master WHERE name = 'message_repeats'"), isNotEmpty);
      // Idempotent: a database that already has v4 parts migrates cleanly.
      db.execute('PRAGMA user_version = 3');
      expect(migrateDatabase(db, chatMigrations), chatMigrations.last.version);
      db.close();
    });

    test('deleting a message deletes its repeats', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello');
      await h.service.pump();
      h.service.handleInbound(copy(m.tsSender, 'Me: hello', 'a1'));
      expect(h.store.messages.repeatsFor(m.id), hasLength(1));
      h.store.db.raw.execute('DELETE FROM messages WHERE id = ?', [m.id]);
      expect(h.store.messages.repeatsFor(m.id), isEmpty);
    });
  });

  group('copies of channel messages', () {
    test('a sent message records which repeater relayed it, with signal and time', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello');
      await h.service.pump();
      h.service.handleInbound(copy(m.tsSender, 'Me: hello', 'a1', snr: 6.5, rssi: -92, heardMs: 1760000001000));
      h.service.handleInbound(copy(m.tsSender, 'Me: hello', 'b2c3', snr: -2.0, rssi: -110, heardMs: 1760000002000));
      final reps = h.store.messages.repeatsFor(m.id);
      expect(reps.map((r) => r.firstHop), ['a1', 'b2']);
      expect(reps.last.lastHop, 'c3');
      expect(reps.last.hops, 2);
      expect(reps.first.snr, 6.5);
      expect(reps.first.rssi, -92);
      expect(h.store.messages.get(m.id)!.repeatsHeard, 2);
      expect(h.store.messages.get(m.id)!.state, MessageState.heard);
    });

    test('a received message: a copy logged before the message is handed over is held, then attached', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      // The radio logs the packet (0x88) just before it queues the message: the copy comes first.
      h.service.handleInbound(copy(500, 'Alice: hi there', 'd4e5'));
      expect(h.store.messages.count(), 0);
      h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: 500, text: 'Alice: hi there', snr: 4, pathLen: 2));
      final m = h.store.messages.page(ch.convKey).messages.single;
      expect(m.senderName, 'Alice');
      expect(h.store.messages.repeatsFor(m.id).map((r) => r.pathHashes), ['d4e5']);
      // A later copy by another path is a second arrival.
      h.service.handleInbound(copy(500, 'Alice: hi there', 'f6'));
      expect(h.store.messages.get(m.id)!.repeatsHeard, 2);
      expect(h.store.messages.get(m.id)!.state, MessageState.received, reason: 'a received message keeps its state');
    });

    test('a held copy expires after a minute', () async {
      final h = Harness();
      await h.channel(1, 'Ohio', ChannelKind.private);
      h.service.handleInbound(copy(700, 'Alice: late', 'a1'));
      h.clock.advance(61000);
      h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: 700, text: 'Alice: late', snr: 4, pathLen: 1));
      final m = h.store.messages.page(h.store.channels.bySlot(radioA, 1)!.convKey).messages.single;
      expect(h.store.messages.repeatsFor(m.id), isEmpty);
    });

    test('a copy of a different text, timestamp or channel attaches to nothing', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      await h.channel(2, 'Other', ChannelKind.private);
      final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello');
      await h.service.pump();
      h.service.handleInbound(copy(m.tsSender, 'Me: hello!', 'a1'));
      h.service.handleInbound(copy(m.tsSender + 1, 'Me: hello', 'a1'));
      h.service.handleInbound(copy(m.tsSender, 'Me: hello', 'a1', slot: 2));
      expect(h.store.messages.repeatsFor(m.id), isEmpty);
    });
  });

  group('route a sent DM used', () {
    test('sent direct: the route the radio held is kept with the message, and stays when the contact route changes', () async {
      final h = Harness();
      h.bob(path: true);
      final m = h.service.send(radioId: radioA, convKey: h.bobConv, text: 'yo');
      await h.service.pump();
      final got = h.store.messages.get(m.id)!;
      expect(got.route, Route.direct);
      expect(got.sentHops, ['01', '02']);
      h.store.contacts.setPath(radioA, bobKey, Uint8List.fromList([9]), 1);
      expect(h.store.messages.get(m.id)!.sentHops, ['01', '02']);
    });

    test('sent by flood: no route', () async {
      final h = Harness();
      h.bob();
      final m = h.service.send(radioId: radioA, convKey: h.bobConv, text: 'yo');
      await h.service.pump();
      final got = h.store.messages.get(m.id)!;
      expect(got.route, Route.flood);
      expect(got.sentPath, isNull);
    });
  });

  group('ChannelCopyListener', () {
    Future<(Harness, Channel, Uint8List, List<InboundRepeatHeard>, ChannelCopyListener)> rig() async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      await h.channel(3, 'wardriving', ChannelKind.system);
      final secret = (await h.store.channels.secretOf(ch))!;
      final got = <InboundRepeatHeard>[];
      final l = ChannelCopyListener(
          radioId: () => radioA, channels: (id) => h.store.channels.list(id), secretOf: h.store.channels.secretOf, emit: got.add);
      return (h, ch, secret, got, l);
    }

    test('decrypts a group text on one of our channels and reports its path, signal and time', () async {
      final (_, _, secret, got, l) = await rig();
      final at = DateTime.fromMillisecondsSinceEpoch(1760000005000);
      await l.onPacket(RxPacket(at: at, raw: groupPacket(secret, 1234, 'Alice', 'hi', [0xa1, 0xb2]), snrDb: 5.25, rssiDbm: -97));
      expect(got, hasLength(1));
      final e = got.single;
      expect((e.channelSlot, e.timestamp, e.text), (1, 1234, 'Alice: hi'));
      expect((e.pathHashes, e.hops, e.hashSize), ('a1b2', 2, 1));
      expect((e.snr, e.rssi, e.heardMs), (5.25, -97, 1760000005000));
    });

    test('ignores other channels, the wardrive channel, non-text packets and garbage', () async {
      final (h, _, _, got, l) = await rig();
      final other = Uint8List.fromList(List.filled(16, 77));
      await l.onPacket(RxPacket(at: DateTime.now(), raw: groupPacket(other, 1, 'X', 'y', [1])));
      final sys = (await h.store.channels.secretOf(h.store.channels.bySlot(radioA, 3)!))!;
      await l.onPacket(RxPacket(at: DateTime.now(), raw: groupPacket(sys, 1, 'X', 'ping', [1])));
      await l.onPacket(RxPacket(at: DateTime.now(), raw: Uint8List.fromList([1, 2, 3])));
      expect(got, isEmpty);
    });

    test('end to end: a repeat heard on the air marks our sent message heard by that repeater', () async {
      final (h, ch, secret, _, _) = await rig();
      final l = ChannelCopyListener(
          radioId: () => radioA, channels: (id) => h.store.channels.list(id), secretOf: h.store.channels.secretOf, emit: h.service.handleInbound);
      final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello');
      await h.service.pump();
      await l.onPacket(RxPacket(at: DateTime.now(), raw: groupPacket(secret, m.tsSender, 'Me', 'hello', [0xc4]), snrDb: 3, rssiDbm: -101));
      expect(h.store.messages.repeatsFor(m.id).single.firstHop, 'c4');
      expect(h.store.messages.get(m.id)!.state, MessageState.heard);
    });
  });
}
