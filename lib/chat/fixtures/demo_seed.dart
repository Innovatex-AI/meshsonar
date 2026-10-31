// Realistic demo conversations for UI work and screenshots (agents 1C and later). Deterministic for a given seed and clock,
// idempotent (seeding twice adds nothing), and goes through the same ChatService paths as real traffic. Not wired into any
// release screen: it is only referenced from tests and dev tooling, so release builds tree-shake it out.
import 'dart:math';
import 'dart:typed_data';

import '../channel_secret.dart';
import '../chat_service.dart';
import '../models.dart';
import '../radio_bridge.dart';

class DemoChat {
  final String radioId;
  final Map<String, Contact> contacts;
  final Map<String, Channel> channels;
  const DemoChat(this.radioId, this.contacts, this.channels);

  Channel get publicChannel => channels['Public']!;
  Channel get ops => channels['Ohio Ops']!;
  Channel get hashtag => channels['#ohio']!;
  Channel get system => channels['#wardriving']!;
  String dmKey(String contactName) => ConvKey.dm(contacts[contactName]!.prefix);
}

String _key(int n) => (n.toRadixString(16).padLeft(2, '0') * 32).substring(0, 64);

/// Fills [store] through [service] with about 10 days of mixed traffic. [nowMs] is "now" for the seeded timeline.
Future<DemoChat> seedDemoChat(ChatService service, {required int nowMs, int seed = 1, String radioId = 'de00000000000000000000000000000000000000000000000000000000000001'}) async {
  final store = service.store;
  final rnd = Random(seed);
  final idRnd = Random(seed + 1); // separate stream: skipping an already-seeded send must not shift the content stream
  final contacts = <String, Contact>{};
  void addContact(String name, ContactType t, int n, {double? lat, double? lon, bool fav = false, int pathLen = -1}) {
    final c = Contact(
      radioId: radioId,
      publicKey: _key(n),
      type: t,
      name: name,
      lat: lat,
      lon: lon,
      favourite: fav,
      lastAdvertTs: nowMs ~/ 1000 - rnd.nextInt(3 * 86400),
      outPath: pathLen > 0 ? Uint8List.fromList(List.generate(pathLen, (i) => 0x10 + n + i)) : null,
      outPathLen: pathLen,
    );
    store.contacts.upsert(c);
    contacts[name] = c;
  }

  addContact('Maya KE8AAA', ContactType.companion, 0xa1, lat: 39.76, lon: -84.19, fav: true, pathLen: 2);
  addContact('Dev (portable)', ContactType.companion, 0xa2, fav: true);
  addContact('Sam W8SAM', ContactType.companion, 0xa3, lat: 39.10, lon: -84.51, pathLen: 1);
  addContact('Priya', ContactType.companion, 0xa4);
  addContact('Hilltop Repeater', ContactType.repeater, 0xb1, lat: 39.84, lon: -84.08);
  addContact('Downtown Repeater', ContactType.repeater, 0xb2, lat: 39.76, lon: -84.19);
  addContact('Ohio Hams Room', ContactType.room, 0xc1);
  addContact('Weather Station', ContactType.sensor, 0xd1, lat: 39.5, lon: -84.3);

  Future<Channel> channel(int slot, String name, ChannelKind kind, Uint8List secret) =>
      store.channels.save(Channel(radioId: radioId, slot: slot, name: name, kind: kind, sortOrder: slot), secret: secret);
  final channels = <String, Channel>{
    'Public': await channel(0, 'Public', ChannelKind.public, publicChannelSecret16),
    '#ohio': await channel(1, '#ohio', ChannelKind.hashtag, hashtagSecret16('#ohio')),
    'Ohio Ops': await channel(2, 'Ohio Ops', ChannelKind.private, Uint8List.fromList(List.generate(16, (i) => 0x40 + i))),
    '#wardriving': await channel(3, '#wardriving', ChannelKind.system, hashtagSecret16('#wardriving')),
  };

  final saveNow = service.nowMs;
  var clock = nowMs - 10 * 86400000;
  final svc = ChatService(
      store: store, sink: _SeedSink(), nowMs: () => clock, selfName: service.selfName, newId: () => 'demo-${store.messages.count()}-${idRnd.nextInt(1 << 30)}', autoTimer: false);
  int ts() => clock ~/ 1000;
  void at(int hoursAgo, [int minute = 0]) => clock = nowMs - hoursAgo * 3600000 + minute * 60000;

  void chan(int slot, String who, String text, {double snr = 4.0, int hops = 1}) =>
      svc.handleInbound(InboundChannelText(radioId: radioId, channelSlot: slot, timestamp: ts(), text: '$who: $text', snr: snr + rnd.nextDouble() * 3, pathLen: hops));
  void dm(String from, String text) =>
      svc.handleInbound(InboundDirectText(radioId: radioId, senderPrefix: contacts[from]!.prefix, timestamp: ts(), text: text, snr: 3 + rnd.nextDouble() * 6, pathLen: 1));
  void mine(String conv, String text, MessageState state, {FailReason? fail, int? ackMs, int repeats = 0, Route? route}) {
    if (store.messages.existsDedupe(radioId, dedupeKeyFor(conv, ts(), text))) return; // seeded already
    final m = svc.send(radioId: radioId, convKey: conv, text: text);
    store.messages.update(m.id,
        state: state, failReason: fail, ackMs: ackMs, repeatsHeard: repeats, route: route ?? (conv.startsWith('c:') ? Route.flood : Route.direct), attempt: 1);
    store.outbox.remove(m.id);
  }

  // ---- Public: busy, anonymous, lots of people
  at(200);
  for (final (who, t) in [
    ('Tom', 'Anyone on from Springfield?'),
    ('KC8ZZZ', 'Good morning mesh'),
    ('Lena', 'Just flashed the new firmware, all good here'),
    ('Tom', 'Copy Lena, will do the same tonight'),
    ('Ravi', 'Hilltop is coming in solid at 8 dB from my window'),
  ]) {
    clock += (3 + rnd.nextInt(40)) * 60000;
    chan(0, who, t, hops: rnd.nextInt(4));
  }
  at(30);
  chan(0, 'Lena', 'Net tonight 8pm, 146.52 simplex for the ham folks and mesh for everyone else', hops: 2);
  at(29);
  chan(0, 'Ravi', 'Reminder: keep adverts to once an hour, the mesh is busy enough');
  mine(channels['Public']!.convKey, 'Thanks Ravi, copy that', MessageState.heard, repeats: 3);

  // ---- #ohio hashtag
  at(120);
  chan(1, 'Maya', 'Testing from the 4th floor, anyone hear me?');
  at(119);
  chan(1, 'Sam', 'Loud and clear, 2 hops');
  mine(channels['#ohio']!.convKey, 'Heard you both, 3 hops from the east side', MessageState.heard, repeats: 2);

  // ---- Private ops channel: includes a mention, emoji, a long message, a failed send
  at(60);
  chan(2, 'Maya', 'Drive route for Saturday is posted. 🚗 Start at the hilltop, finish downtown.');
  at(59);
  chan(2, 'Dev', 'Can someone take the north loop? I have a flat tire and need to fix it first, then I can pick up the loop after lunch if nobody else wants it. Also bring a charger.');
  at(58);
  mine(channels['Ohio Ops']!.convKey, 'I can take the north loop', MessageState.heard, repeats: 4);
  at(2);
  chan(2, 'Maya', '@[Me] can you confirm the antenna swap on the downtown node?');
  at(1);
  mine(channels['Ohio Ops']!.convKey, 'On it, will confirm tonight', MessageState.sent);

  // ---- DMs
  at(48);
  dm('Maya KE8AAA', 'Hey, did the claim go through for the new repeater?');
  at(47);
  mine(ConvKey.dm(contacts['Maya KE8AAA']!.prefix), 'Yes, it shows as mine now', MessageState.acked, ackMs: 3400);
  at(46);
  dm('Maya KE8AAA', 'Perfect. Can you bring the spare mast on Saturday?');
  at(5);
  dm('Sam W8SAM', 'You still have that SMA pigtail?');
  mine(ConvKey.dm(contacts['Sam W8SAM']!.prefix), 'Yes. Meet at the usual place?', MessageState.failed, fail: FailReason.noAck);
  at(0, -20);
  dm('Dev (portable)', 'Back online, battery swapped');
  dm('Dev (portable)', 'Sending the log in a bit');
  at(0, -2);
  dm('Priya', 'Thanks for the help setting it up!');

  // ---- Room server
  at(36);
  svc.handleInbound(InboundDirectText(
      radioId: radioId, senderPrefix: contacts['Ohio Hams Room']!.prefix, timestamp: ts(), text: 'Welcome to the Ohio Hams room. Be kind.', txtType: 2, signerPrefix: _key(0xa1).substring(0, 8)));

  // ---- Wardrive system channel: noisy, never chat
  at(24);
  for (var i = 0; i < 60; i++) {
    clock += 15000 + rnd.nextInt(60000);
    chan(3, 'MeshMapper', 'MS:${rnd.nextInt(1 << 30).toRadixString(36).padLeft(6, 'a')}', hops: 1 + rnd.nextInt(3));
  }
  for (var i = 0; i < 25; i++) {
    svc.recordOwnPing(radioId, 3);
  }

  // ---- settings and state
  final conv = ConvKey.channel(channels['Public']!.id!);
  svc.setNotifyMode(radioId, conv, NotifyMode.muted);
  svc.setPinned(radioId, ConvKey.dm(contacts['Maya KE8AAA']!.prefix), true);
  svc.saveDraft(ConvKey.dm(contacts['Sam W8SAM']!.prefix), 'Actually I can drop it at your place');
  // Mark everything older than ~6 hours read so the list shows a believable mix of read and unread.
  for (final c in svc.conversations()) {
    final recent = (c.lastTsMs ?? 0) > nowMs - 6 * 3600000;
    if (!recent) svc.markRead(c.key);
  }
  clock = saveNow();
  return DemoChat(radioId, contacts, channels);
}

/// Seeded sends are never transmitted: their state is set by hand.
class _SeedSink implements OutboundMessageSink {
  @override
  bool get canSend => false;
  @override
  Future<SendReceipt> sendDirect({required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood}) =>
      throw const RadioNotConnected();
  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp}) => throw const RadioNotConnected();
}
