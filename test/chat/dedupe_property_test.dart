import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';

import 'support.dart';

/// Property: however the same set of frames is duplicated, shuffled and replayed, the stored result is exactly the set of
/// distinct (conversation, timestamp, text) triples, and the denormalised conversation rows agree with the messages.
void main() {
  test('dedupe + unread invariants under random duplication, interleaving and replay', () async {
    for (var seed = 0; seed < 25; seed++) {
      final rnd = Random(seed);
      final h = Harness();
      h.bob();
      await h.channel(1, 'A', ChannelKind.private);
      await h.channel(2, 'B', ChannelKind.hashtag);
      final distinct = <String>{};
      final frames = <InboundEvent>[];
      for (var i = 0; i < 60 + rnd.nextInt(60); i++) {
        final ts = 1000 + rnd.nextInt(15); // few timestamps: forces collisions
        final text = 'msg${rnd.nextInt(6)}';
        switch (rnd.nextInt(3)) {
          case 0:
            frames.add(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: ts, text: 'N: $text'));
            distinct.add('c1|$ts|N: $text');
          case 1:
            frames.add(InboundChannelText(radioId: radioA, channelSlot: 2, timestamp: ts, text: 'N: $text'));
            distinct.add('c2|$ts|N: $text');
          default:
            frames.add(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: ts, text: text));
            distinct.add('dm|$ts|$text');
        }
      }
      // duplicate every frame 1-3 times, shuffle, replay the whole batch again
      final stream = <InboundEvent>[for (final f in frames) ...List.filled(1 + rnd.nextInt(3), f)]..shuffle(rnd);
      for (var pass = 0; pass < 2; pass++) {
        stream.forEach(h.service.handleInbound);
      }
      expect(h.store.messages.count(), distinct.length, reason: 'seed $seed');
      final unreadBefore = {for (final c in h.store.messages.conversations()) c.key: c.unread};
      h.store.messages.rebuildAllConversations();
      final unreadAfter = {for (final c in h.store.messages.conversations()) c.key: c.unread};
      expect(unreadBefore, unreadAfter, reason: 'denormalised unread must equal a recount (seed $seed)');
      expect(unreadAfter.values.fold<int>(0, (a, b) => a + b), distinct.length);
    }
  });

  test('dedupe keys: stable, conversation-scoped, collision-free on a large sample', () {
    final seen = <String>{};
    for (var c = 0; c < 20; c++) {
      for (var t = 0; t < 500; t++) {
        for (var x = 0; x < 5; x++) {
          expect(seen.add(dedupeKeyFor('c:$c', 1700000000 + t, 'text $x')), isTrue);
        }
      }
    }
    expect(dedupeKeyFor('c:1', 5, 'a'), dedupeKeyFor('c:1', 5, 'a'));
    expect(dedupeKeyFor('c:1', 5, 'a'), isNot(dedupeKeyFor('c:2', 5, 'a')));
    expect(dedupeKeyFor('c:1', 5, 'ab'), isNot(dedupeKeyFor('c:1', 55, 'b')), reason: 'field boundaries are unambiguous');
    expect(dedupeKeyFor('c:1', 5, 'a').length, 32);
  });
}
