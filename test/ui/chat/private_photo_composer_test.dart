// The composer's photo flow for private (encrypted) conversations: DMs and private channels send an encrypted photo and insert
// the private link (55 bytes, key in the fragment); Public and hashtag channels keep the plain link; without photo-config
// e2e a private conversation has no photo button at all (never a plain fallback); every server error shows its sentence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/private_photo.dart';
import 'package:meshsonar/platform/photo_picker.dart';
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
    picker = FakePhotoPicker()..next = PreparedPhoto(cleanJpeg, 2048, 1536);
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  String fieldText(WidgetTester t) => t.widget<EditableText>(find.descendant(of: find.byKey(const Key('composer-field')), matching: find.byType(EditableText))).controller.text;

  Future<PhotoController> pump(WidgetTester tester, String convKey) async {
    setSize(tester);
    final photos = fakePhotos(kit.store, transport: transport, picker: picker);
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: convKey, photos: photos)));
    await tester.pump();
    await tester.pump();
    return photos;
  }

  String dm() {
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

  final privateLink = RegExp(r'https://meshsonar\.com/e/k3Xq9TzA#[A-Za-z0-9_-]{22}');

  testWidgets('DM: the sheet says it is encrypted; the photo is uploaded encrypted and the private link goes in', (tester) async {
    await pump(tester, dm());
    await tester.enterText(find.byKey(const Key('composer-field')), 'summit view');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-photo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('encrypted on this phone'), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
    expect(transport.uploads, isEmpty, reason: 'never the plain endpoint');
    expect(transport.privateBodies.length, 1);
    expect(picker.thumbnails, 1);
    final text = fieldText(tester);
    expect(text, startsWith('summit view '));
    final link = parsePrivatePhotoLink(text.substring('summit view '.length))!;
    expect(link.id, 'k3Xq9TzA');
    expect(utf8.encode(text.substring('summit view '.length)).length, 55);
    // What went up opens with the key from the link, and holds the picker's JPEGs.
    final body = Uint8List.fromList(transport.privateBodies.single);
    final n = ByteData.sublistView(body).getUint32(0);
    expect(await PrivatePhoto.decrypt(body.sublist(4, 4 + n), link.key, PrivatePhotoRole.thumb), cleanJpeg);
    expect(await PrivatePhoto.decrypt(body.sublist(4 + n), link.key, PrivatePhotoRole.full), cleanJpeg);
    expect(transport.privateSizes.single, (2048, 1536));
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
  });

  testWidgets('DM budget: 104 bytes of text fit beside the 55-byte link, 105 do not (cut 1 byte, then it goes in by itself)', (tester) async {
    await pump(tester, dm());
    expect(kit.controller.service.maxTextBytes(ConvKey.dm(bobKey)), 160);
    await tester.enterText(find.byKey(const Key('composer-field')), 'a' * 105);
    await tester.pump();
    await sendPhoto(tester);
    expect(fieldText(tester), 'a' * 105, reason: 'nothing trimmed, nothing inserted');
    expect(find.textContaining('Its link needs 56 bytes'), findsOneWidget);
    expect(find.textContaining('cut 1 byte from your message'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer-field')), 'a' * 104);
    await tester.pump();
    expect(fieldText(tester), startsWith('${'a' * 104} https://meshsonar.com/e/k3Xq9TzA#'));
    expect(utf8.encode(fieldText(tester)).length, 160);
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
  });

  testWidgets('private link round trip through the message parser', (tester) async {
    await pump(tester, dm());
    await sendPhoto(tester);
    expect(privateLink.hasMatch(fieldText(tester)), isTrue);
    expect(parsePrivatePhotoLink(fieldText(tester)), isNotNull);
  });

  group('routing', () {
    testWidgets('DM without e2e on the server: no photo button, never a plain fallback', (tester) async {
      transport.config = const PhotoConfig(enabled: true);
      await pump(tester, dm());
      expect(find.byKey(const Key('composer-photo')), findsNothing);
      expect(transport.uploads, isEmpty);
    });

    testWidgets('private channel without e2e: no photo button either', (tester) async {
      transport.config = const PhotoConfig(enabled: true);
      final ch = await kit.channel(2, 'Crew', kind: ChannelKind.private);
      await pump(tester, ch.convKey);
      expect(find.byKey(const Key('composer-photo')), findsNothing);
    });

    testWidgets('Public channel without e2e: the plain photo button is still there and uploads plain', (tester) async {
      transport.config = const PhotoConfig(enabled: true);
      final ch = await kit.channel(1, 'Public', kind: ChannelKind.public);
      await pump(tester, ch.convKey);
      picker.next = null;
      await sendPhoto(tester);
      expect(picker.picks, hasLength(1));
      picker.next = PreparedPhoto(tinyPng, 2, 2);
      await sendPhoto(tester);
      expect(transport.uploads, [tinyPng.length]);
      expect(transport.privateBodies, isEmpty);
      expect(fieldText(tester), photoUrlA);
      expect(picker.thumbnails, 0, reason: 'no thumbnail work for a plain photo');
    });

    testWidgets('hashtag channel: plain link', (tester) async {
      final ch = await kit.channel(2, '#ohio', kind: ChannelKind.hashtag);
      await pump(tester, ch.convKey);
      picker.next = PreparedPhoto(tinyPng, 2, 2);
      await sendPhoto(tester);
      expect(fieldText(tester), photoUrlA);
      expect(transport.privateBodies, isEmpty);
    });

    testWidgets('private channel (random secret): private link', (tester) async {
      final ch = await kit.channel(3, 'Crew', kind: ChannelKind.private);
      await pump(tester, ch.convKey);
      await sendPhoto(tester);
      expect(transport.uploads, isEmpty);
      expect(transport.privateBodies, hasLength(1));
      expect(privateLink.hasMatch(fieldText(tester)), isTrue);
    });

    testWidgets('a private channel budget leaves room for the 55-byte link', (tester) async {
      final ch = await kit.channel(3, 'Crew', kind: ChannelKind.private);
      await pump(tester, ch.convKey);
      final max = kit.controller.service.maxTextBytes(ch.convKey);
      await tester.enterText(find.byKey(const Key('composer-field')), 'b' * (max - 56));
      await tester.pump();
      await sendPhoto(tester);
      expect(utf8.encode(fieldText(tester)).length, max);
    });
  });

  group('errors (private upload)', () {
    final errors = <PhotoError, (String, bool)>{
      const PhotoError(PhotoErrorKind.noKey, status: 401): ('driver key', true),
      const PhotoError(PhotoErrorKind.notApproved, status: 403): ('not approved', true),
      const PhotoError(PhotoErrorKind.tooLarge, status: 413): ('too large', false),
      const PhotoError(PhotoErrorKind.rateLimited, status: 429, retryAfterS: 600): ('Try again in 10 minutes', true),
      const PhotoError(PhotoErrorKind.disabled, status: 503): ('switched off', true),
      const PhotoError(PhotoErrorKind.network): ('Could not reach', true),
      const PhotoError(PhotoErrorKind.stalled): ('too slow', true),
    };
    for (final e in errors.entries) {
      testWidgets('${e.key.status ?? e.key.kind.name} shows "${e.value.$1}"; nothing is inserted; no key in the text', (tester) async {
        await pump(tester, dm());
        transport.uploadError = e.key;
        await sendPhoto(tester);
        expect(find.textContaining(e.value.$1), findsOneWidget);
        expect(fieldText(tester), '');
        expect(find.byKey(const Key('composer-photo-retry')), e.value.$2 ? findsOneWidget : findsNothing);
        expect(find.byKey(const Key('composer-photo-remove')), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const Key('composer-photo-status'))).data, isNot(contains('#')));
        if (e.value.$2 && e.key.kind != PhotoErrorKind.disabled) {
          transport.uploadError = null;
          await tester.tap(find.byKey(const Key('composer-photo-retry')));
          await tester.pumpAndSettle();
          expect(privateLink.hasMatch(fieldText(tester)), isTrue);
          expect(transport.privateBodies.length, 2);
          expect(picker.picks.length, 1, reason: 'retry does not open the picker again');
          expect(picker.thumbnails, 1, reason: 'retry reuses the thumbnail');
          // A retry is a fresh encryption: another key, other ciphertext.
          expect(transport.privateBodies[0], isNot(transport.privateBodies[1]));
        }
      });
    }
  });

  testWidgets('a photo that still carries GPS is refused before upload, without Retry', (tester) async {
    picker.next = PreparedPhoto(File('test/fixtures/photos/gps_fixture.jpg').readAsBytesSync(), 10, 10);
    await pump(tester, dm());
    await sendPhoto(tester);
    expect(find.textContaining('details (like location)'), findsOneWidget);
    expect(find.byKey(const Key('composer-photo-retry')), findsNothing);
    expect(transport.privateBodies, isEmpty);
    expect(fieldText(tester), '');
  });

  testWidgets('a thumbnail that cannot be made says why and uploads nothing', (tester) async {
    picker.thumbError = const PhotoPrepareException('Could not make a preview of that photo.');
    await pump(tester, dm());
    await tester.tap(find.byKey(const Key('composer-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not make a preview'), findsOneWidget);
    expect(transport.privateBodies, isEmpty);
    expect(transport.uploads, isEmpty);
  });

  testWidgets('Cancel stops a private upload without inserting anything', (tester) async {
    await pump(tester, dm());
    transport.holdUpload = Completer();
    await sendPhoto(tester);
    expect(find.byKey(const Key('composer-photo-progress')), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-photo-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-photo-strip')), findsNothing);
    expect(fieldText(tester), '');
  });
}
