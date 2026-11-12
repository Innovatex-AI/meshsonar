// Plain or private photo per conversation (docs/planning/photo-e2e-private-2026-11-12.md): a DM, a room and a private
// channel get an encrypted photo; Public and hashtag channels (readable by anyone who knows the name) get the plain link.
// When unsure (system channel, unknown channel), private.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/photo_kind.dart';

import '../ui/chat/chat_kit.dart';

void main() {
  Channel ch(ChannelKind k) => Channel(id: 7, radioId: 'r', slot: 1, name: 'x', kind: k);

  test('pure rule, every kind', () {
    expect(photoKindFor(ConvKey.dm('0123456789abcdef'), null), PhotoKind.private);
    expect(photoKindFor(ConvKey.room('0123456789abcdef'), null), PhotoKind.private);
    expect(photoKindFor(ConvKey.channel(7), ch(ChannelKind.public)), PhotoKind.plain);
    expect(photoKindFor(ConvKey.channel(7), ch(ChannelKind.hashtag)), PhotoKind.plain);
    expect(photoKindFor(ConvKey.channel(7), ch(ChannelKind.private)), PhotoKind.private);
    expect(photoKindFor(ConvKey.channel(7), ch(ChannelKind.system)), PhotoKind.private);
    expect(photoKindFor(ConvKey.channel(7), null), PhotoKind.private, reason: 'unknown channel: safe default');
    expect(photoKindFor('garbage', null), PhotoKind.private);
  });

  test('ChatService.photoKind reads the saved channel row', () async {
    final kit = ChatKit();
    addTearDown(kit.dispose);
    kit.bob();
    final pub = await kit.channel(1, 'Public', kind: ChannelKind.public);
    final tag = await kit.channel(2, '#ohio', kind: ChannelKind.hashtag);
    final priv = await kit.channel(3, 'Crew', kind: ChannelKind.private);
    expect(kit.service.photoKind(ConvKey.dm(bobKey)), PhotoKind.private);
    expect(kit.service.photoKind(pub.convKey), PhotoKind.plain);
    expect(kit.service.photoKind(tag.convKey), PhotoKind.plain);
    expect(kit.service.photoKind(priv.convKey), PhotoKind.private);
    expect(kit.service.photoKind(ConvKey.channel(9999)), PhotoKind.private);
  });
}
