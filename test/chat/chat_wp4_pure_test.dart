// WP4 pure-Dart logic: bubble grouping, the delivery state table, the byte budget, the info strip content, quick replies,
// paging around an anchor.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/bubble_grouping.dart';
import 'package:meshsonar/chat/delivery_state.dart';
import 'package:meshsonar/chat/message_info.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/quick_replies.dart';
import 'package:meshsonar/chat/send_budget.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/message_sync.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/rx_facts.dart';

const radio = 'aa00000000000000000000000000000000000000000000000000000000000001';
final base = DateTime(2026, 11, 1, 12).millisecondsSinceEpoch;

ChatMessage msg(String id, int plusSec,
        {bool out = false, String sender = 'Ann', MessageState? state, ConvKind kind = ConvKind.channel, int repeats = 0, int attempt = 0, int? ackMs, double? snr, int? pathLen, int? rssi, String? hashes, int? hashSize, Route? route, FailReason? fail}) =>
    ChatMessage(
      id: id,
      radioId: radio,
      convKind: kind,
      convKey: kind == ConvKind.channel ? 'c:1' : 'd:b0b000000000',
      direction: out ? Direction.outgoing : Direction.incoming,
      senderName: out ? 'Me' : sender,
      tsSender: 1,
      tsLocalMs: base + plusSec * 1000,
      text: 'text $id',
      state: state ?? (out ? MessageState.sent : MessageState.received),
      dedupeKey: id,
      repeatsHeard: repeats,
      attempt: attempt,
      ackMs: ackMs,
      snr: snr,
      pathLen: pathLen,
      rssi: rssi,
      pathHashes: hashes,
      hashSize: hashSize,
      route: route,
      failReason: fail,
    );

void main() {
  group('bubble grouping', () {
    test('same sender within 3 minutes is one run; time line goes under the last (newest) bubble', () {
      final list = [msg('c', 120), msg('b', 60), msg('a', 0)]; // newest first
      final s = groupMessages(list, showSenders: true);
      expect(s.map((e) => e.joinsOlder), [true, true, false]);
      expect(s.map((e) => e.joinsNewer), [false, true, true]);
      expect(s[0].lastOfRun, isTrue);
      expect(s[2].firstOfRun, isTrue);
      expect(s.where((e) => e.showSender).map((e) => e.message.id), ['a'], reason: 'sender name only above the first bubble of a run');
    });

    test('a gap over 3 minutes, another sender or the other direction starts a new run', () {
      final gap = groupMessages([msg('b', 200), msg('a', 0)], showSenders: true);
      expect(gap[0].joinsOlder, isFalse);
      final other = groupMessages([msg('b', 10, sender: 'Bob'), msg('a', 0)], showSenders: true);
      expect(other[0].joinsOlder, isFalse);
      final dir = groupMessages([msg('b', 10, out: true), msg('a', 0)], showSenders: true);
      expect(dir[0].joinsOlder, isFalse);
      expect(dir[0].showSender, isFalse, reason: 'own messages never show a sender');
    });

    test('exactly 3 minutes still joins; separator after more than an hour or a new day', () {
      expect(groupMessages([msg('b', 180), msg('a', 0)], showSenders: false)[0].joinsOlder, isTrue);
      final sep = groupMessages([msg('c', 3700 + 10), msg('b', 10), msg('a', 0)], showSenders: false);
      expect(sep.map((e) => e.separatorAbove), [true, false, true], reason: 'oldest always opens a group; 1h gap opens another');
      final nextDay = groupMessages([msg('b', 86400), msg('a', 0)], showSenders: false);
      expect(nextDay[0].separatorAbove, isTrue);
    });

    test('DM never shows sender names', () {
      final s = groupMessages([msg('a', 0, kind: ConvKind.dm)], showSenders: false);
      expect(s.single.showSender, isFalse);
    });
  });

  group('delivery states', () {
    DeliveryUi ui(ChatMessage m, {bool connected = true, int? max, int now = 0}) => deliveryUi(m, radioConnected: connected, maxAttempts: max, nowMs: base + now);

    test('queued / sending are Queued with a clock; offline says it will send on connect', () {
      for (final s in [MessageState.queued, MessageState.sending]) {
        final d = ui(msg('a', 0, out: true, state: s));
        expect(d.stage, DeliveryStage.queued);
        expect(d.glyph, DeliveryGlyph.clock);
        expect(d.word, 'Waiting');
        expect(d.detail, 'Waiting for the radio');
        expect(d.pending, isTrue);
      }
      expect(ui(msg('a', 0, out: true, state: MessageState.queued), connected: false).detail, 'Will send when your radio connects');
    });

    test('DM: sent, slow after 20 s or a retry, final try widens the search, acked is Delivered', () {
      final m = msg('a', 0, out: true, state: MessageState.sent, kind: ConvKind.dm, attempt: 1);
      expect(ui(m, max: 3).word, 'Sent');
      expect(ui(m, max: 3, now: 25000).word, 'Mesh is slow, still trying (try 1 of 3)');
      expect(ui(msg('a', 0, out: true, state: MessageState.retrying, kind: ConvKind.dm, attempt: 2), max: 3).word, 'Mesh is slow, still trying (try 2 of 3)');
      expect(ui(msg('a', 0, out: true, state: MessageState.retrying, kind: ConvKind.dm, attempt: 3), max: 3).word, 'Trying a wider search');
      final ok = ui(msg('a', 0, out: true, state: MessageState.acked, kind: ConvKind.dm, ackMs: 1800), now: 0);
      expect(ok.stage, DeliveryStage.delivered);
      expect(ok.glyph, DeliveryGlyph.checkmarkCircleFill);
      expect(ok.detail, 'Delivered · 1.8 s');
      expect(ui(msg('a', 0, out: true, state: MessageState.acked, kind: ConvKind.dm, ackMs: 1800)).alwaysVisible, isFalse);
    });

    test('channels never reach Delivered: Sent, then Heard at most', () {
      final sent = ui(msg('a', 0, out: true, state: MessageState.sent));
      expect(sent.stage, DeliveryStage.sent);
      expect(sent.detail, contains('no delivery receipts'));
      final heard = ui(msg('a', 0, out: true, state: MessageState.heard, repeats: 2));
      expect(heard.stage, DeliveryStage.heard);
      expect(heard.glyph, DeliveryGlyph.antenna);
      expect(heard.word, 'Heard by 2 repeaters');
      expect(ui(msg('a', 0, out: true, state: MessageState.heard, repeats: 1)).word, 'Heard by 1 repeater');
      // even a bogus acked channel row is capped
      expect(ui(msg('a', 0, out: true, state: MessageState.acked, repeats: 1)).stage, DeliveryStage.heard);
      expect(ui(msg('a', 0, out: true, state: MessageState.acked)).stage, DeliveryStage.sent);
    });

    test('failed: red glyph, word, channel wording differs, always visible', () {
      final dm = ui(msg('a', 0, out: true, state: MessageState.failed, kind: ConvKind.dm, fail: FailReason.noAck));
      expect(dm.stage, DeliveryStage.failed);
      expect(dm.glyph, DeliveryGlyph.exclamationCircleFill);
      expect(dm.word, 'Not delivered');
      expect(dm.alwaysVisible, isTrue);
      expect(ui(msg('a', 0, out: true, state: MessageState.failed)).detail, startsWith('No repeater heard it'));
    });
  });

  group('byte budget', () {
    test('counts UTF-8 bytes: accents 2, emoji 4', () {
      expect(ByteBudget.of('abc', 100).used, 3);
      expect(ByteBudget.of('é' * 10, 100).used, 20);
      expect(ByteBudget.of('😀' * 10, 100).used, 40);
      expect(ByteBudget.of('  hi  ', 100).used, 2, reason: 'send trims whitespace');
    });

    test('levels: quiet, ring from 60%, number at <= 20 left, orange at <= 10, red at 0', () {
      expect(ByteBudget(50, 100).level, BudgetLevel.quiet);
      expect(ByteBudget(60, 100).level, BudgetLevel.ring);
      expect(ByteBudget(80, 100).level, BudgetLevel.number);
      expect(ByteBudget(80, 100).showNumber, isTrue);
      expect(ByteBudget(90, 100).level, BudgetLevel.warning);
      expect(ByteBudget(100, 100).level, BudgetLevel.full);
      expect(ByteBudget(101, 100).over, isTrue);
    });

    test('announcements only when a threshold is crossed', () {
      expect(ByteBudget(80, 100).announcementFor(BudgetLevel.ring), '20 bytes left');
      expect(ByteBudget(90, 100).announcementFor(BudgetLevel.number), '10 bytes left');
      expect(ByteBudget(100, 100).announcementFor(BudgetLevel.warning), 'No bytes left');
      expect(ByteBudget(81, 100).announcementFor(BudgetLevel.number), isNull);
      expect(ByteBudget(70, 100).announcementFor(BudgetLevel.quiet), isNull);
    });

    test('trimToBytes cuts on a character boundary', () {
      expect(trimToBytes('hello', 10), 'hello');
      expect(trimToBytes('ééé', 5), 'éé');
      expect(trimToBytes('a😀b', 4), 'a', reason: 'the emoji needs 4 bytes: it does not fit after "a"');
      expect(trimToBytes('😀😀', 4), '😀');
      expect(trimToBytes('a\u{1F468}‍\u{1F469}', 8), 'a\u{1F468}', reason: 'a dangling joiner is dropped');
      expect(ByteBudget.of(trimToBytes('é' * 200, 156), 156).used, lessThanOrEqualTo(156));
    });
  });

  group('info strip content', () {
    Contact rep(String name, String keyStart) => Contact(radioId: radio, publicKey: keyStart.padRight(64, '0'), type: ContactType.repeater, name: name);

    test('incoming flood with known hashes names the repeaters, with SNR, RSSI and a signal word', () {
      final m = msg('a', 0, snr: 6.5, rssi: -92, pathLen: 2, hashes: 'a1b2', hashSize: 1, kind: ConvKind.dm);
      final i = messageInfo(m, repeaters: [rep('Ridge', 'a1'), rep('Hill', 'b2')], peer: 'Maya');
      expect(i.kind, TravelKind.viaRepeaters);
      expect(i.routeWord, 'Via 2 repeaters');
      expect(i.chips, ['Maya', 'Ridge', 'Hill', 'You']);
      expect(i.signalText, 'SNR 6.5 dB · RSSI -92 dBm');
      expect(i.signalWord, 'Strong');
      expect(i.signalBars, 3);
    });

    test('unknown or ambiguous hash shows ?hex; hash count mismatch names none', () {
      final m = msg('a', 0, snr: -7, pathLen: 2, hashes: 'a1a1', hashSize: 1, kind: ConvKind.dm);
      final i = messageInfo(m, repeaters: [rep('Ridge', 'a1'), rep('Dup', 'a1')], peer: 'Maya');
      expect(i.hops, ['?a1', '?a1']);
      expect(i.signalWord, 'Weak');
      expect(i.signalBars, 0);
      final none = messageInfo(msg('b', 0, pathLen: 3, kind: ConvKind.dm), repeaters: const [], peer: 'Maya');
      expect(none.chips, ['Maya', '3 hops', 'You']);
      expect(none.hops, isEmpty);
      expect(none.signalText, isNull, reason: 'no SNR and no RSSI known: no signal line');
    });

    test('direct (no path) and long routes are capped', () {
      expect(messageInfo(msg('a', 0, snr: 1, kind: ConvKind.dm), repeaters: const [], peer: 'Maya').routeWord, 'Direct');
      final long = messageInfo(msg('a', 0, pathLen: 5, hashes: 'a1b2c3d4e5', hashSize: 1, kind: ConvKind.dm), repeaters: const [], peer: 'Maya');
      expect(long.chips.length, 4);
      expect(long.chips[2], '+4');
    });

    test('own message: flood says Searching, a saved route names the repeaters, a channel has no route', () {
      expect(messageInfo(msg('a', 0, out: true, kind: ConvKind.dm, route: Route.flood), repeaters: const [], peer: 'Maya').routeWord, 'Searching');
      expect(messageInfo(msg('a', 0, out: true), repeaters: const []).routeWord, 'Sent to everyone nearby');
      final c = Contact(radioId: radio, publicKey: 'b0b0'.padRight(64, '0'), type: ContactType.companion, name: 'Maya', outPathLen: 1, outPath: Uint8List.fromList([0xa1]));
      final i = messageInfo(msg('a', 0, out: true, kind: ConvKind.dm, route: Route.direct), repeaters: [rep('Ridge', 'a1')], peer: 'Maya', contact: c);
      expect(i.chips, ['You', 'Ridge', 'Maya']);
    });

    test('route subtitle words', () {
      expect(dmRouteText(null), 'No route yet');
      final c = Contact(radioId: radio, publicKey: 'b0'.padRight(64, '0'), type: ContactType.companion, name: 'M');
      expect(dmRouteText(c), 'No route yet');
      expect(dmRouteText(c.copyWith(forceFlood: true)), 'Searching');
      expect(dmRouteText(c.copyWith(outPathLen: 0, outPath: Uint8List(0))), 'Direct');
      expect(dmRouteText(c.copyWith(outPathLen: 1, outPath: Uint8List.fromList([1]))), 'Via 1 repeater');
      expect(roomSubtitle(joined: false), 'Room · Not joined');
    });
  });

  group('quick replies', () {
    test('defaults, save, reset to defaults stores nothing', () {
      final store = ChatStore.inMemory();
      addTearDown(store.close);
      expect(loadQuickReplies(store), defaultQuickReplies);
      saveQuickReplies(store, ['Yes', ' ', 'No']);
      expect(loadQuickReplies(store), ['Yes', 'No']);
      saveQuickReplies(store, defaultQuickReplies);
      expect(store.db.setting(quickRepliesKey), isNull);
      expect(defaultQuickReplies.length, 6);
    });
  });

  group('paging around an anchor', () {
    test('window around the anchor, newest first, with older cursor and newer flag', () {
      final store = ChatStore.inMemory();
      addTearDown(store.close);
      for (var i = 0; i < 100; i++) {
        store.messages.insert(msg('m$i', i));
      }
      final r = store.messages.pageAround('c:1', 'm50', before: 10, after: 10)!;
      final ids = r.page.messages.map((m) => m.id).toList();
      expect(ids.first, 'm60');
      expect(ids.contains('m50'), isTrue);
      expect(ids.last, 'm40');
      expect(ids.length, 21);
      expect(r.hasNewer, isTrue);
      expect(r.page.next, isNotNull);
      final older = store.messages.page('c:1', before: r.page.next, limit: 5).messages;
      expect(older.first.id, 'm39');
      final top = store.messages.pageAround('c:1', 'm98', before: 5, after: 10)!;
      expect(top.hasNewer, isFalse);
      expect(top.page.messages.first.id, 'm99');
      final bottom = store.messages.pageAround('c:1', 'm1', before: 5, after: 2)!;
      expect(bottom.page.next, isNull, reason: 'm0 is inside the window: nothing older');
      expect(store.messages.pageAround('c:1', 'nope'), isNull);
      expect(store.messages.pageAround('c:9', 'm1'), isNull, reason: 'the message must belong to the conversation');
    });

    test('radio facts round trip through the messages table', () {
      final store = ChatStore.inMemory();
      addTearDown(store.close);
      store.messages.insert(msg('x', 0, snr: 3, rssi: -101, pathLen: 2, hashes: 'a1b2', hashSize: 1));
      final m = store.messages.get('x')!;
      expect(m.rssi, -101);
      expect(m.pathHashes, 'a1b2');
      expect(m.hopHashes, ['a1', 'b2']);
      expect(m.hashSize, 1);
    });
  });

  group('rx facts (RSSI and hop hashes from the rx log)', () {
    // header: route flood(1) | payload GRP_TXT(5) << 2 ; path_len 2 hops, 1-byte hashes; payload.
    Uint8List pkt({int type = 5, int route = 1, List<int> path = const [0xa1, 0xb2], int size = 1}) =>
        Uint8List.fromList([(type << 2) | route, if (route == 0 || route == 3) ...[1, 2, 3, 4], ((size - 1) << 6) | (path.length ~/ size), ...path, 9, 9, 9]);

    test('parses path, hash size and hop count', () {
      final f = parseRxPacket(pkt(), snrDb: 4, rssiDbm: -90)!;
      expect(f.pathHashes, 'a1b2');
      expect(f.hashSize, 1);
      expect(f.hops, 2);
      expect(f.payloadType, 5);
      final two = parseRxPacket(pkt(size: 2, path: [1, 2, 3, 4]), snrDb: 0, rssiDbm: 0)!;
      expect(two.hashSize, 2);
      expect(two.hops, 2);
      expect(two.pathHashes, '01020304');
      expect(parseRxPacket(pkt(route: 0), snrDb: 0, rssiDbm: 0)!.hops, 2, reason: 'transport codes are skipped');
      expect(parseRxPacket(Uint8List.fromList([5 << 2 | 1, 5]), snrDb: 0, rssiDbm: 0), isNull, reason: 'path longer than the packet');
    });

    test('correlates by SNR, hop count and time; one match is used once; non-text packets are ignored', () {
      final c = RxCorrelator();
      final t = DateTime.utc(2026, 11, 1);
      c.record(t, pkt(), snrDb: 4, rssiDbm: -90);
      c.record(t, pkt(type: 4), snrDb: 4, rssiDbm: -50); // ADVERT: ignored
      expect(c.length, 1);
      expect(c.take(at: t.add(const Duration(milliseconds: 400)), snrDb: 7, hops: 2), isNull, reason: 'different SNR');
      expect(c.take(at: t.add(const Duration(milliseconds: 400)), snrDb: 4, hops: 3), isNull, reason: 'different hop count');
      expect(c.take(at: t.add(const Duration(seconds: 10)), snrDb: 4, hops: 2), isNull, reason: 'too old');
      final hit = c.take(at: t.add(const Duration(milliseconds: 400)), snrDb: 4, hops: 2)!;
      expect(hit.rssiDbm, -90);
      expect(c.take(at: t.add(const Duration(milliseconds: 500)), snrDb: 4, hops: 2), isNull, reason: 'consumed');
    });

    test('MessageSync fills RSSI and hashes on a matching message and hash size from path_len otherwise', () async {
      final queue = <Uint8List>[encodeChannelMsg(1, 'Ann: hi', timestamp: 5, pathLen: 2, snrDb: 4), encodeContactText(List<int>.generate(32, (i) => i + 1), 'dm', txtType: txtTypePlain, timestamp: 6, pathLen: 0x42, snrDb: -1)];
      final src = _Src(queue);
      final now = DateTime.utc(2026, 11, 1);
      final corr = RxCorrelator()..record(now, pkt(), snrDb: 4, rssiDbm: -90);
      final sync = MessageSync(src, clock: () => now.add(const Duration(milliseconds: 300)));
      sync.rxFacts = (at, snr, hops) => corr.take(at: at, snrDb: snr, hops: hops);
      addTearDown(sync.dispose);
      final got = <dynamic>[];
      sync.messages.listen(got.add);
      await sync.drain();
      expect(got, hasLength(2));
      expect(got[0].rssiDbm, -90);
      expect(got[0].pathHashesHex, 'a1b2');
      expect(got[0].hashSize, 1);
      expect(got[1].rssiDbm, isNull);
      expect(got[1].hashSize, 2, reason: 'path_len 0x42: top bits 01 = 2-byte hashes');
    });
  });
}

class _Src implements MessageSource {
  final List<Uint8List> q;
  _Src(this.q);
  @override
  bool get isConnected => true;
  @override
  Future<Frame> syncNextMessage() async => decodeFrame(q.isEmpty ? encodeNoMoreMessages() : q.removeAt(0));
}
