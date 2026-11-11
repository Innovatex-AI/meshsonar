// The composer's photo flow: the button follows photo-config and the driver key; the uploaded link goes at the end of the
// text and counts in the byte meter; a link that does not fit is held back with the exact number of bytes to cut (nothing is
// trimmed); every contract error shows its sentence, with Retry where retrying can help; Cancel stops an upload.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';

import '../../support/photo_fakes.dart';
import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  late FakePhotoTransport transport;
  late FakePhotoPicker picker;
  setUp(() {
    kit = ChatKit();
    transport = FakePhotoTransport();
    picker = FakePhotoPicker();
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  String fieldText(WidgetTester t) => t.widget<EditableText>(find.descendant(of: find.byKey(const Key('composer-field')), matching: find.byType(EditableText))).controller.text;

  Future<PhotoController> pump(WidgetTester tester, String convKey, {String? key = 'drv-key', bool approved = true}) async {
    setSize(tester);
    final photos = fakePhotos(kit.store, transport: transport, picker: picker, key: key, approved: approved);
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: convKey, photos: photos)));
    await tester.pump();
    await tester.pump();
    return photos;
  }

  Future<String> dm() async {
    kit.bob();
    return ConvKey.dm(bobKey);
  }

  Future<void> sendPhoto(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-photo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-source-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
  }

  testWidgets('no button while photo-config says off or the server cannot be reached', (tester) async {
    transport.config = PhotoConfig.disabled;
    await pump(tester, await dm());
    expect(find.byKey(const Key('composer-photo')), findsNothing);
    transport
      ..config = const PhotoConfig(enabled: true)
      ..configError = const PhotoError(PhotoErrorKind.network);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, ConvKey.dm(bobKey));
    expect(find.byKey(const Key('composer-photo')), findsNothing);
  });

  testWidgets('without an approved driver key the button explains instead of picking', (tester) async {
    await pump(tester, await dm(), approved: false);
    await tester.tap(find.byKey(const Key('composer-photo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-needs-key')), findsOneWidget);
    expect(find.textContaining('driver key'), findsWidgets);
    expect(picker.picks, isEmpty);
  });

  testWidgets('DM: the link goes at the end after a space, and the meter counts it', (tester) async {
    await pump(tester, await dm());
    await tester.enterText(find.byKey(const Key('composer-field')), 'summit view');
    await tester.pump();
    await sendPhoto(tester);
    expect(transport.uploads, [tinyPng.length]);
    expect(fieldText(tester), 'summit view $photoUrlA');
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
    // 160 - 11 - 1 - 32 = 116 left: the ring is quiet; with a longer text the number shows the link's cost.
    final long = 'x' * 110;
    await tester.enterText(find.byKey(const Key('composer-field')), long);
    await tester.pump();
    await sendPhoto(tester);
    expect(fieldText(tester), '$long $photoUrlA');
    expect(utf8.encode(fieldText(tester)).length, 143);
    expect(find.byKey(const Key('composer-left')), findsOneWidget);
    expect(find.text('17'), findsOneWidget);
    expect(kit.controller.service.maxTextBytes(ConvKey.dm(bobKey)), 160);
  });

  testWidgets('an empty composer gets just the link', (tester) async {
    await pump(tester, await dm());
    await sendPhoto(tester);
    expect(fieldText(tester), photoUrlA);
  });

  testWidgets('DM: one byte too many is not trimmed; the person is told to cut 1 byte, then it goes in by itself', (tester) async {
    await pump(tester, await dm());
    final text = 'a' * 128; // 128 + 1 + 32 = 161 > 160
    await tester.enterText(find.byKey(const Key('composer-field')), text);
    await tester.pump();
    await sendPhoto(tester);
    expect(fieldText(tester), text, reason: 'nothing trimmed, nothing inserted');
    expect(find.textContaining('cut 1 byte from your message'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer-field')), 'a' * 127);
    await tester.pump();
    expect(fieldText(tester), '${'a' * 127} $photoUrlA');
    expect(utf8.encode(fieldText(tester)).length, 160);
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
  });

  testWidgets('channel: the budget is 160 - name - 2, and the bytes to cut count multi-byte characters', (tester) async {
    final ch = await kit.channel(1, 'Ohio');
    await pump(tester, ch.convKey);
    final max = kit.controller.service.maxTextBytes(ch.convKey);
    expect(max, 160 - 2 - 2, reason: 'self name "Me"');
    final fits = 'b' * (max - 33);
    await tester.enterText(find.byKey(const Key('composer-field')), fits);
    await tester.pump();
    await sendPhoto(tester);
    expect(utf8.encode(fieldText(tester)).length, max);
    // Now 5 emoji (20 bytes) over: cut 21 bytes (the 1-byte space is already there in the count).
    await tester.enterText(find.byKey(const Key('composer-field')), '${'c' * (max - 33 - 20)}${'😀' * 10}');
    await tester.pump();
    await sendPhoto(tester);
    final over = utf8.encode('${fieldText(tester)} $photoUrlA').length - max;
    expect(over, 20);
    expect(find.textContaining('cut 20 bytes from your message'), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-photo-remove')));
    await tester.pump();
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
  });

  final errors = <PhotoError, (String, bool)>{
    const PhotoError(PhotoErrorKind.noKey, status: 401): ('driver key', true),
    const PhotoError(PhotoErrorKind.notApproved, status: 403): ('not approved', true),
    const PhotoError(PhotoErrorKind.tooLarge, status: 413): ('too large', false),
    const PhotoError(PhotoErrorKind.notImage, status: 415): ('not a photo', false),
    const PhotoError(PhotoErrorKind.rateLimited, status: 429, retryAfterS: 600): ('Try again in 10 minutes', true),
    const PhotoError(PhotoErrorKind.disabled, status: 503): ('switched off', true),
    const PhotoError(PhotoErrorKind.network): ('Could not reach', true),
    const PhotoError(PhotoErrorKind.stalled): ('Upload stalled — your connection is too slow right now. Try again or use Wi-Fi.', true),
  };
  for (final e in errors.entries) {
    testWidgets('upload error ${e.key.status ?? e.key.kind.name} shows "${e.value.$1}"', (tester) async {
      await pump(tester, await dm());
      transport.uploadError = e.key;
      await sendPhoto(tester);
      expect(find.textContaining(e.value.$1), findsOneWidget);
      expect(fieldText(tester), '');
      expect(find.byKey(const Key('composer-photo-retry')), e.value.$2 ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('composer-photo-remove')), findsOneWidget);
      if (e.value.$2) {
        transport.uploadError = null;
        await tester.tap(find.byKey(const Key('composer-photo-retry')));
        await tester.pumpAndSettle();
        expect(fieldText(tester), photoUrlA);
        expect(transport.uploads.length, 2);
        // Retry resends the bytes already prepared; it does not open the picker again.
        expect(identical(transport.uploadedBytes[1], transport.uploadedBytes[0]), isTrue);
        expect(picker.picks.length, 1);
      }
    });
  }

  testWidgets('progress shows while uploading, and Cancel stops it without inserting anything', (tester) async {
    await pump(tester, await dm());
    transport.holdUpload = Completer<void>();
    await sendPhoto(tester);
    expect(find.byKey(const Key('composer-photo-progress')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('composer-photo-status'))).data, 'Uploading photo ${(tinyPng.length ~/ 2 / tinyPng.length * 100).round()}%');
    await tester.tap(find.byKey(const Key('composer-photo-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
    expect(fieldText(tester), '');
  });

  testWidgets('once the whole body is out the strip says Processing… (not a stuck 100%) until the answer', (tester) async {
    await pump(tester, await dm());
    transport.holdAnswer = Completer<void>();
    await sendPhoto(tester);
    expect(tester.widget<Text>(find.byKey(const Key('composer-photo-status'))).data, 'Processing…');
    expect(find.byKey(const Key('composer-photo-cancel')), findsOneWidget);
    transport.holdAnswer!.complete();
    await tester.pumpAndSettle();
    expect(fieldText(tester), photoUrlA);
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
  });

  testWidgets('backing out of the picker leaves no strip; a picker failure says why', (tester) async {
    await pump(tester, await dm());
    picker.next = null;
    await sendPhoto(tester);
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
    expect(transport.uploads, isEmpty);
  });
}
