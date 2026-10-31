import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/inbound.dart';

void main() {
  test('InboundMessage keys: conversation, hops and content', () {
    final m = InboundMessage(
      kind: InboundKind.channel,
      channelIndex: 3,
      senderName: 'Ann',
      text: 'hi',
      fullText: 'Ann: hi',
      txtType: 0,
      senderTimestamp: 1700000000,
      receivedAt: DateTime.utc(2026, 11, 1),
      pathLen: 0xFF,
      raw: Uint8List(0),
    );
    expect(m.conversationKey, 'ch:3');
    expect(m.wasDirect, isTrue);
    expect(m.hops, isNull);
    expect(m.contentKey, 'ch:3|1700000000|Ann: hi');
  });

  test('SendResult constructors', () {
    expect(const SendResult.accepted(5, expectedAck: 9).isAccepted, isTrue);
    expect(const SendResult.failed(SendFailure.tooLong).isFailed, isTrue);
    expect(const SendResult.queued(5).status, SendStatus.queued);
  });

  test('FloodScope key must be 16 bytes and compares by value', () {
    expect(() => FloodScope.key(Uint8List(3)), throwsArgumentError);
    expect(FloodScope.key(Uint8List(16)) == FloodScope.key(Uint8List(16)), isTrue);
    expect(FloodScope.unscoped == FloodScope.radioDefault, isFalse);
  });
}
