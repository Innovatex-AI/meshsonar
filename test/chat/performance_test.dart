import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/message_repository.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/store.dart';

import 'support.dart';

const _words = ['coverage', 'repeater', 'hilltop', 'antenna', 'weather', 'lunch', 'copy', 'solid', 'weak', 'ping', 'route', 'mesh', 'downtown', 'north', 'tower'];

void main() {
  test('100,000 messages: paging, list, unread, search stay fast and memory stays flat', () {
    final s = ChatStore.inMemory();
    final rnd = Random(5);
    final sw = Stopwatch()..start();
    const convs = 20;
    s.db.transaction(() {
      for (var i = 0; i < 100000; i++) {
        final conv = i < 50000 ? 'c:1' : 'c:${2 + rnd.nextInt(convs - 1)}';
        final text = '${_words[rnd.nextInt(_words.length)]} ${_words[rnd.nextInt(_words.length)]} ${_words[rnd.nextInt(_words.length)]} #$i';
        s.messages.insert(ChatMessage(
          id: 'm$i',
          radioId: radioA,
          convKind: ConvKind.channel,
          convKey: conv,
          direction: Direction.incoming,
          senderName: 'N${i % 40}',
          tsSender: 1700000000 + i,
          tsLocalMs: 1700000000000 + i * 1000 + rnd.nextInt(900),
          text: text,
          state: MessageState.received,
          dedupeKey: 'k$i',
          read: i % 10 != 0,
        ));
      }
    });
    final insertMs = sw.elapsedMilliseconds;
    expect(s.messages.count(), 100000);

    int timeMs(void Function() f) {
      final t = Stopwatch()..start();
      f();
      return t.elapsedMilliseconds;
    }

    // First page, deep page by cursor, conversation list, badge, rare and common searches.
    final first = s.messages.page('c:1', limit: 50);
    final mid = s.messages.page('c:1', before: MessageCursor(first.messages.last.tsLocalMs - 25000 * 1000, 1 << 40), limit: 50);
    expect(mid.messages.length, 50);
    final times = {
      'first page': timeMs(() => s.messages.page('c:1', limit: 50)),
      'deep page': timeMs(() => s.messages.page('c:1', before: mid.next, limit: 50)),
      'conversation list': timeMs(() => s.messages.conversations()),
      'badge': timeMs(() => s.messages.unreadConversationCount(nowMs: 0)),
      'rare search': timeMs(() => expect(s.messages.search('#77777'), isNotEmpty)),
      'common search (limit 50)': timeMs(() => expect(s.messages.search('hilltop', limit: 50).length, 50)),
      'two-term search': timeMs(() => s.messages.search('hilltop antenna', limit: 50)),
      'short-term search': timeMs(() => s.messages.search('zz', limit: 50)),
      'mark read (50k conv)': timeMs(() => s.messages.markConversationRead('c:1')),
    };
    // Generous ceilings: they exist to catch an accidental table scan or O(n) paging, not to benchmark the machine.
    for (final e in times.entries) {
      final limit = e.key == 'short-term search' || e.key == 'mark read (50k conv)' ? 1500 : 250;
      expect(e.value, lessThan(limit), reason: '${e.key} took ${e.value} ms; all: $times');
    }
    expect(s.messages.unreadCount('c:1'), 0);

    // Walk the whole big conversation page by page: memory must not grow with it.
    final rssBefore = ProcessInfo.currentRss;
    var cur = first.next;
    var n = first.messages.length;
    while (cur != null) {
      final p = s.messages.page('c:1', before: cur, limit: 200);
      n += p.messages.length;
      cur = p.next;
    }
    expect(n, 50000);
    final grewMb = (ProcessInfo.currentRss - rssBefore) / (1 << 20);
    expect(grewMb, lessThan(80), reason: 'paging 50k messages must not retain them (grew $grewMb MB)');
    // ignore: avoid_print
    print('perf: insert 100k in ${insertMs}ms; $times; walk grew ${grewMb.toStringAsFixed(1)} MB');
    expect(insertMs, lessThan(30000));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('memory bound: a burst of 20,000 inbound frames leaves nothing queued in memory', () {
    final h = Harness();
    final rssBefore = ProcessInfo.currentRss;
    h.store.db.transaction(() {
      for (var i = 0; i < 20000; i++) {
        h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: i, text: 'N: burst $i'));
      }
    });
    expect(h.store.messages.count(), 20000);
    expect(h.store.outbox.count(), 0);
    expect((ProcessInfo.currentRss - rssBefore) / (1 << 20), lessThan(120));
  });
}
