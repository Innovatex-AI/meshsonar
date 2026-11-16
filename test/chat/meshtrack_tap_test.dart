// MT-4 seams (meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md sections 6 and 9): inbound ChannelTextTap before
// the store insert, and the silent (no bubble) channel send through the arbiter as TxPriority.track.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/backup.dart';
import 'package:meshsonar/chat/channel_text_tap.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/events.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/session_adapter.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/session_manager.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

import 'support.dart';

const mtBody = 'MT1 @87G8Q2X5+7F2 s34 c270';

InboundChannelText chText(int slot, int ts, String text, {double? snr = 6.5, int? pathLen = 2, int? rssi = -97}) =>
    InboundChannelText(radioId: radioA, channelSlot: slot, timestamp: ts, text: text, snr: snr, pathLen: pathLen, rssi: rssi);

/// The generic tap MeshTrack will register: consumes bodies that start with "MT1 " (stand-in for parseMeshTrack != null).
ChannelTextTap mtTap(List<ChannelTextEvent> seen) => ChannelTextTap.of((e) {
      seen.add(e);
      return e.body.startsWith('MT1 ') ? TapVerdict.consume : TapVerdict.pass;
    });

/// A fixed sender clock about now (the harness clock is 1760000000000 ms).
int get nowTs => 1760000000;

Future<void> until(bool Function() test, {int ms = 4000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $ms ms');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('inbound tap', () {
    test('a consumed text is not stored, not announced, not unread, not searchable, not in the backup', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Family', ChannelKind.private);
      final events = <ChatEvent>[];
      h.service.events.listen(events.add);
      final seen = <ChannelTextEvent>[];
      h.service.addChannelTextTap(mtTap(seen));

      h.service.handleInbound(chText(1, nowTs, 'Sam: $mtBody'));
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(h.store.messages.count(), 0);
      expect(h.service.page(ch.convKey).messages, isEmpty);
      expect(events.where((e) => e.kind == ChatEventKind.messageAdded), isEmpty, reason: 'no event = no notification, no bubble');
      expect(h.service.unreadBadge(), 0);
      expect(h.store.messages.unreadCount(ch.convKey), 0);
      expect(h.service.search('MT1'), isEmpty);
      expect(h.service.search('87G8Q2X5'), isEmpty);
      final map = await ChatBackup(h.store, nowMs: h.clock.call, appVersion: '9.9.9', newId: () => 'x').exportMap(const BackupOptions());
      expect(jsonEncode(map), isNot(contains('87G8Q2X5')));
      final json = utf8.decode(await ChatBackup(h.store, nowMs: h.clock.call, appVersion: '9.9.9', newId: () => 'x')
          .export(const BackupOptions(), file: BackupFile.json, useIsolate: false));
      expect(json, isNot(contains('87G8Q2X5')));
    });

    test('ordinary text on the same channel stays normal chat (notified, unread, searchable, backed up)', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Family', ChannelKind.private);
      final events = <ChatEvent>[];
      h.service.events.listen(events.add);
      h.service.addChannelTextTap(mtTap([]));

      h.service.handleInbound(chText(1, nowTs, 'Sam: $mtBody'));
      h.service.handleInbound(chText(1, nowTs + 1, 'Sam: running 10 min late'));
      h.service.handleInbound(chText(1, nowTs + 2, 'Sam: MT1hi is not a position'));
      await Future<void>.delayed(Duration.zero);

      expect(h.service.page(ch.convKey).messages.map((m) => m.text), unorderedEquals(['running 10 min late', 'MT1hi is not a position']));
      final added = events.where((e) => e.kind == ChatEventKind.messageAdded).toList();
      expect(added, hasLength(2));
      expect(added.every((e) => e.notify), isTrue);
      expect(h.service.unreadBadge(), 2);
      expect(h.service.search('late'), hasLength(1));
      final map = await ChatBackup(h.store, nowMs: h.clock.call, appVersion: '9.9.9', newId: () => 'x').exportMap(const BackupOptions());
      expect(jsonEncode(map), contains('running 10 min late'));
      expect(jsonEncode(map), isNot(contains('87G8Q2X5')));
    });

    test('the tap gets every field: channel, kind, sender, body, sender ts, snr, path, rssi, receive time, backlog', () async {
      final h = Harness();
      final ch = await h.channel(3, 'Club', ChannelKind.private);
      final seen = <ChannelTextEvent>[];
      h.service.addChannelTextTap(mtTap(seen));

      h.service.handleInbound(chText(3, nowTs - 5, 'KE4BFI: $mtBody', snr: -3.25, pathLen: 4, rssi: -110));
      final e = seen.single;
      expect(e.radioId, radioA);
      expect(e.channelId, ch.id);
      expect(e.channelSlot, 3);
      expect(e.channelKind, ChannelKind.private);
      expect(e.convKey, ch.convKey);
      expect(e.senderName, 'KE4BFI');
      expect(e.body, mtBody);
      expect(e.senderTs, nowTs - 5);
      expect(e.snr, -3.25);
      expect(e.pathLen, 4);
      expect(e.rssi, -110);
      expect(e.receivedMs, h.clock.ms);
      expect(e.backlog, isFalse, reason: 'live: sender clock within a minute of now');

      // Waited in the radio's offline queue: sender time well behind the receive time.
      h.service.handleInbound(chText(3, nowTs - 3600, 'KE4BFI: $mtBody', pathLen: null, snr: null, rssi: null));
      expect(seen.last.backlog, isTrue);
      expect(seen.last.pathLen, isNull);
      expect(seen.last.snr, isNull);
      expect(seen.last.rssi, isNull);

      // No "name: " prefix: sender null, body is the whole text.
      h.service.handleInbound(chText(3, nowTs, mtBody));
      expect(seen.last.senderName, isNull);
      expect(seen.last.body, mtBody);
    });

    test('a throwing tap counts as pass, is logged without the text, and later taps are still asked', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Family', ChannelKind.private);
      final log = <String>[];
      h.service.diagLog = log.add;
      var laterAsked = 0;
      h.service.addChannelTextTap(ChannelTextTap.of((_) => throw StateError('boom')));
      h.service.addChannelTextTap(ChannelTextTap.of((_) {
        laterAsked++;
        return TapVerdict.pass;
      }));

      h.service.handleInbound(chText(1, nowTs, 'Sam: secret plans at 87G8Q2X5'));
      expect(laterAsked, 1);
      expect(h.service.page(ch.convKey).messages.single.text, 'secret plans at 87G8Q2X5');
      expect(log, hasLength(1));
      expect(log.single, contains('StateError'));
      expect(log.single, isNot(contains('secret')));
      expect(log.single, isNot(contains('87G8Q2X5')));
      expect(log.single, isNot(contains('Sam')));
    });

    test('taps run in registration order; the first consume stops the chain; remove works; no double registration', () async {
      final h = Harness();
      await h.channel(1, 'Family', ChannelKind.private);
      final order = <String>[];
      ChannelTextTap tap(String n, TapVerdict v) => ChannelTextTap.of((_) {
            order.add(n);
            return v;
          });
      final a = tap('a', TapVerdict.pass), b = tap('b', TapVerdict.consume), c = tap('c', TapVerdict.consume);
      h.service.addChannelTextTap(a);
      h.service.addChannelTextTap(b);
      h.service.addChannelTextTap(c);
      h.service.addChannelTextTap(a); // ignored

      h.service.handleInbound(chText(1, nowTs, 'Sam: one'));
      expect(order, ['a', 'b']);
      expect(h.store.messages.count(), 0);

      order.clear();
      expect(h.service.removeChannelTextTap(b), isTrue);
      expect(h.service.removeChannelTextTap(b), isFalse);
      h.service.handleInbound(chText(1, nowTs + 1, 'Sam: two'));
      expect(order, ['a', 'c']);

      order.clear();
      h.service.removeChannelTextTap(c);
      h.service.handleInbound(chText(1, nowTs + 2, 'Sam: three'));
      expect(order, ['a']);
      expect(h.store.messages.count(), 1);
    });

    test('a tap may remove itself while being called', () async {
      final h = Harness();
      await h.channel(1, 'Family', ChannelKind.private);
      late ChannelTextTap self;
      var calls = 0;
      self = ChannelTextTap.of((_) {
        calls++;
        h.service.removeChannelTextTap(self);
        return TapVerdict.consume;
      });
      h.service.addChannelTextTap(self);
      h.service.handleInbound(chText(1, nowTs, 'Sam: a'));
      h.service.handleInbound(chText(1, nowTs + 1, 'Sam: b'));
      expect(calls, 1);
      expect(h.store.messages.count(), 1);
    });

    test('no tap, or only passing taps: exactly the rows and events of today', () async {
      Future<(List<Map<String, Object?>>, List<String>)> run(void Function(ChatService s) setup) async {
        final h = Harness();
        await h.channel(1, 'Family', ChannelKind.private);
        await h.channel(2, '#wardriving', ChannelKind.system);
        setup(h.service);
        final ev = <String>[];
        h.service.events.listen((e) => ev.add('${e.kind.name}:${e.convKey}:${e.messageId}:${e.notify}'));
        for (final f in [
          chText(1, nowTs, 'Sam: $mtBody'),
          chText(1, nowTs + 1, 'Sam: hello'),
          chText(1, nowTs + 1, 'Sam: hello'), // replay
          chText(2, nowTs + 2, 'X: MS:abc1234567'),
          chText(7, nowTs + 3, 'Unknown: from a slot we never saw'),
        ]) {
          h.service.handleInbound(f);
        }
        await Future<void>.delayed(Duration.zero);
        final rows = h.store.db.raw.select('SELECT * FROM messages ORDER BY seq').map((r) => Map<String, Object?>.of(r)).toList();
        return (rows, ev);
      }

      final base = await run((_) {});
      final passing = await run((s) => s.addChannelTextTap(ChannelTextTap.of((_) => TapVerdict.pass)));
      expect(base.$1, hasLength(4));
      expect(passing.$1, base.$1);
      expect(passing.$2, base.$2);
    });

    test('system (wardrive) channel traffic reaches taps with its kind; passing keeps the system stats as today', () async {
      final h = Harness();
      final sys = await h.channel(2, '#wardriving', ChannelKind.system);
      final seen = <ChannelTextEvent>[];
      h.service.addChannelTextTap(mtTap(seen));
      h.service.handleInbound(chText(2, nowTs, 'X: MS:abc1234567'));
      expect(seen.single.channelKind, ChannelKind.system);
      expect(h.store.systemStats.get(sys.id!).heardOthers, 1);
    });
  });

  group('silent send (no chat bubble), through the arbiter as track', () {
    late Harness h;
    late Channel ch;
    late DateTime now;
    late TxArbiter arb;

    setUp(() async {
      h = Harness();
      ch = await h.channel(1, 'Family', ChannelKind.private);
      now = DateTime.utc(2026, 11, 16, 12);
      arb = TxArbiter(clock: () => now, airParams: () => const RadioAirParams(8, 62.5, 5), senderNameBytes: () => 2);
      h.service.trackGate = arb;
    });

    test('sent: the radio gets the text, chat stores nothing and announces nothing, the ledger has a track row', () async {
      final events = <ChatEvent>[];
      h.service.events.listen(events.add);
      final r = await h.service.sendChannelTextSilently(radioId: radioA, channelId: ch.id!, text: mtBody);
      await Future<void>.delayed(Duration.zero);
      expect(r.status, SilentSendStatus.sent);
      expect(r.sent, isTrue);
      expect(r.bytes, mtBody.length);
      expect(r.timestamp, h.clock.ms ~/ 1000);
      expect(h.sink.channels.single.slot, 1);
      expect(h.sink.channels.single.text, mtBody);
      expect(h.store.messages.count(), 0);
      expect(h.store.db.raw.select('SELECT COUNT(*) AS n FROM outbox').first['n'], 0);
      expect(events, isEmpty);
      final s = arb.snapshot();
      expect(s.trackSent, 1);
      expect(s.userSends, 0);
      expect(s.trackMsInWindow, closeTo(arb.estimateTrackMs(mtBody.length), 1e-6));
    });

    test('skipped by the budget: nothing goes to the radio, nothing is queued, the caller is told why', () async {
      for (var i = 0; i < 40; i++) {
        arb.trackSent(500);
      }
      now = now.add(const Duration(seconds: 5));
      final r = await h.service.sendChannelTextSilently(radioId: radioA, channelId: ch.id!, text: mtBody);
      expect(r.status, SilentSendStatus.skipped);
      expect(r.skipReason, 'budget');
      expect(r.airtimeLimited, isTrue);
      expect(r.detail, 'Sharing slower: airtime limit');
      expect(h.sink.channels, isEmpty);
      await h.service.pump();
      expect(h.sink.channels, isEmpty, reason: 'never queued for later');
    });

    test('skipped by the gap after a user message', () async {
      arb.admitUserSend(100);
      final r = await h.service.sendChannelTextSilently(radioId: radioA, channelId: ch.id!, text: mtBody);
      expect(r.status, SilentSendStatus.skipped);
      expect(r.skipReason, 'gap');
      expect(r.airtimeLimited, isFalse);
    });

    test('failures never throw and never store: no arbiter, no radio, unknown or system channel, too long, radio error', () async {
      final sys = await h.channel(2, '#wardriving', ChannelKind.system);
      final log = <String>[];
      h.service.diagLog = log.add;
      Future<SilentSendResult> send(int id, String text) => h.service.sendChannelTextSilently(radioId: radioA, channelId: id, text: text);

      expect((await send(9999, mtBody)).status, SilentSendStatus.failed);
      expect((await send(sys.id!, mtBody)).status, SilentSendStatus.failed);
      expect((await h.service.sendChannelTextSilently(radioId: 'other', channelId: ch.id!, text: mtBody)).status, SilentSendStatus.failed);
      expect((await send(ch.id!, '   ')).status, SilentSendStatus.failed);
      final long = await send(ch.id!, 'x' * 200);
      expect(long.status, SilentSendStatus.failed);
      expect(log.single, contains('200 bytes'));
      expect(log.single, isNot(contains('xxx')));

      h.sink.connected = false;
      expect((await send(ch.id!, mtBody)).detail, 'radio not connected');
      h.sink.connected = true;

      h.service.trackGate = null;
      expect((await send(ch.id!, mtBody)).detail, 'no transmit arbiter', reason: 'fails closed without the airtime rules');
      h.service.trackGate = arb;

      h.sink.failNext = const RadioBusy();
      final busy = await send(ch.id!, mtBody);
      expect(busy.status, SilentSendStatus.failed);
      expect(arb.snapshot().trackSent, 0, reason: 'a send that failed before the radio took it is not on the ledger');

      expect(h.sink.channels, isEmpty);
      expect(h.store.messages.count(), 0);
    });

    test('a channel without a radio slot fails', () async {
      final noSlot = await h.store.channels.save(Channel(radioId: radioA, name: 'Later', kind: ChannelKind.private));
      final r = await h.service.sendChannelTextSilently(radioId: radioA, channelId: noSlot.id!, text: mtBody);
      expect(r.status, SilentSendStatus.failed);
      expect(r.detail, 'channel not on the radio');
    });
  });

  group('end to end over the simulated radio', () {
    test('an MT message from the radio\'s queue is consumed, chat next to it is kept; a silent send is a track send', () async {
      final scanner = SimulatedRadioScanner(seed: 5, timeScale: 50);
      final mgr = RadioSessionManager(
          linkFactory: (t) => MeshCoreCompanionLink(t, timeout: const Duration(seconds: 2), messagePollInterval: const Duration(milliseconds: 80)));
      final LinkRadioSession session = await mgr.connect(scanner, SimulatedRadioScanner.device);
      final radio = scanner.lastTransport!;
      final store = ChatStore.inMemory();
      final adapter = RadioSessionChatAdapter(session);
      final chat = ChatService(store: store, source: null, sink: adapter, selfName: () => 'Me');
      chat.trackGate = session.arbiter;
      final seen = <ChannelTextEvent>[];
      chat.addChannelTextTap(mtTap(seen));
      adapter.bind(chat);
      final radioId = session.selfPublicKey!;
      final pub = await store.channels.save(Channel(radioId: radioId, slot: 0, name: 'Public', kind: ChannelKind.public));
      try {
        expect(radio.injectChannelMessage(0, 'Sam', mtBody), isTrue);
        expect(radio.injectChannelMessage(0, 'Sam', 'see you there'), isTrue);
        await until(() => seen.length >= 2);
        await until(() => store.messages.count() >= 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(chat.page(pub.convKey).messages.map((m) => m.text), ['see you there']);
        expect(seen.firstWhere((e) => e.body == mtBody).senderName, 'Sam');

        final before = session.arbiter.snapshot();
        final r = await chat.sendChannelTextSilently(radioId: radioId, channelId: pub.id!, text: mtBody);
        expect(r.status, SilentSendStatus.sent, reason: r.detail);
        await until(() => radio.sentChannel.any((s) => s.text == mtBody));
        final after = session.arbiter.snapshot();
        expect(after.trackSent, before.trackSent + 1);
        expect(after.userSends, before.userSends, reason: 'the session\'s user-send record became a track record');
        expect(store.messages.count(), 1, reason: 'no bubble for our own position');
        // Pings now wait the 2 s gap, as after a user message.
        final ping = await session.arbiter.requestPing();
        expect(ping.go, isFalse);
      } finally {
        await chat.dispose();
        await mgr.dispose();
      }
    });
  });
}
