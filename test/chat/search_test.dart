import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';

import 'support.dart';

void main() {
  late Harness h;
  late Channel ch;
  var ts = 100;
  Future<void> post(String text) async => h.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: ts++, text: text));

  setUp(() async {
    h = Harness();
    ts = 100;
    ch = await h.channel(1, 'Ohio', ChannelKind.private);
  });

  List<String> find(String q, {String? conv}) => h.service.search(q, convKey: conv).map((m) => m.text).toList();

  test('substring, case-insensitive, AND of terms', () async {
    await post('Ann: Meeting at the Hilltop repeater tonight');
    await post('Bo: lunch?');
    expect(find('hilltop'), ['Meeting at the Hilltop repeater tonight']);
    expect(find('HILL'), ['Meeting at the Hilltop repeater tonight']);
    expect(find('repeater tonight'), hasLength(1));
    expect(find('repeater lunch'), isEmpty);
  });

  test('sender name is searchable', () async {
    await post('Ann: hello');
    expect(find('Ann'), ['hello']);
  });

  test('unicode: diacritics fold, CJK substring, emoji, Cyrillic case', () async {
    await post('Z: Café señor naïve');
    await post('Z: 今日は晴れです、アンテナ調整');
    await post('Z: Привет, МИР');
    await post('Z: coverage 📡 map');
    expect(find('cafe'), hasLength(1));
    expect(find('SENOR'), hasLength(1));
    expect(find('naive'), hasLength(1));
    expect(find('晴れです'), hasLength(1));
    expect(find('アンテナ'), hasLength(1));
    expect(find('привет'), hasLength(1));
    expect(find('мир'), hasLength(1), reason: 'short term falls back to LIKE');
    expect(find('📡 map'), hasLength(1));
  });

  test('short terms (1-2 chars) work through the LIKE fallback and mix with long terms', () async {
    await post('A: ok go');
    await post('A: ok stop');
    expect(find('go'), ['ok go']);
    expect(find('ok st'), ['ok stop']);
    expect(find('o'), hasLength(2));
  });

  test('hostile queries never throw', () async {
    await post('A: plain text here');
    for (final q in ['"', '""', '"abc', 'abc"', '*', 'a*', 'NEAR(a b)', 'a OR b', 'a AND', ')', '(', 'text -here', '%', '_', r'\', "'; DROP TABLE messages;--", '\u0000', 'x' * 5000, 'a b c d e f g h i j k l', '   ', '']) {
      expect(() => find(q), returnsNormally, reason: q);
    }
    expect(find("'; DROP TABLE messages;--"), isEmpty);
    expect(h.store.messages.count(), 1);
    expect(find('%'), isEmpty, reason: 'wildcards are literal');
    expect(find('_'), isEmpty);
    expect(find('text here'), hasLength(1));
  });

  test('scoped to a conversation, paged, newest first', () async {
    h.bob();
    for (var i = 0; i < 30; i++) {
      h.clock.advance(1000);
      await post('X: needle $i');
    }
    h.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: 5, text: 'needle dm'));
    expect(h.service.search('needle', convKey: ch.convKey, limit: 10).length, 10);
    expect(h.service.search('needle', convKey: h.bobConv), hasLength(1));
    final all = h.service.search('needle', limit: 100);
    expect(all.length, 31);
    final page2 = h.service.search('needle', limit: 10, offset: 10);
    expect(page2.map((m) => m.id), all.skip(10).take(10).map((m) => m.id));
  });

  test('deleted messages disappear from search', () async {
    await post('A: findable thing');
    expect(find('findable'), hasLength(1));
    h.service.deleteHistory(ch.convKey);
    expect(find('findable'), isEmpty);
  });
}
