import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/fixtures/demo_seed.dart';
import 'package:meshsonar/chat/models.dart';

import 'support.dart';

void main() {
  test('seeds a realistic, deterministic, idempotent set of conversations', () async {
    final h = Harness();
    final demo = await seedDemoChat(h.service, nowMs: h.clock.ms);
    final list = h.service.conversations();
    final byTitle = {for (final c in list) c.title: c};
    expect(byTitle.keys, containsAll(['Public', '#ohio', 'Ohio Ops', 'Maya KE8AAA', 'Sam W8SAM', 'Dev (portable)', 'Priya', 'Ohio Hams Room']));
    expect(list.where((c) => c.isSystem), isEmpty, reason: 'the wardrive channel is not in the chat list');
    expect(list.first.title, 'Maya KE8AAA', reason: 'pinned first');
    expect(byTitle['Public']!.notifyMode, NotifyMode.muted);
    expect(h.service.unreadBadge(), greaterThan(0));
    expect(list.any((c) => c.unread == 0), isTrue);
    final sam = h.store.messages.page(demo.dmKey('Sam W8SAM')).messages;
    expect(sam.first.state == MessageState.failed || sam.any((m) => m.failReason == FailReason.noAck), isTrue);
    expect(h.service.loadDraft(demo.dmKey('Sam W8SAM')), isNotNull);
    final sys = h.service.systemChannels(demo.radioId).single;
    expect(sys.heardFromOthers, 60);
    expect(sys.pingsSent, 25);
    expect(h.service.search('antenna'), isNotEmpty);

    final n = h.store.messages.count();
    final again = Harness();
    await seedDemoChat(again.service, nowMs: again.clock.ms);
    expect(again.store.messages.count(), n, reason: 'deterministic');
    await seedDemoChat(h.service, nowMs: h.clock.ms);
    expect(h.store.messages.count(), n, reason: 'idempotent');
  });
}
