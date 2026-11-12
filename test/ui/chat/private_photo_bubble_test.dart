// Private photo bubbles and viewer (iPhone, dark): decrypted thumbnail in the bubble through the source, "Photo expired" for
// 404/410, quiet placeholder when it cannot be opened, automatic loading off, the viewer (title, Share link, Save), Report with
// the "Let moderators see this photo" choice (key sent only on yes), Delete for the owner, the menu wording, and a link with a
// broken key that stays an ordinary link.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/photo_prefs.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';
import 'package:meshsonar/core/private_photo.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../support/photo_fakes.dart';
import 'chat_kit.dart';

Widget darkIphone(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: meshSonarTheme(Brightness.dark).copyWith(platform: TargetPlatform.iOS),
      home: child,
    );

void main() {
  late ChatKit kit;
  late FakePhotoTransport transport;
  late FakePhotoSource source;
  setUp(() {
    kit = ChatKit();
    transport = FakePhotoTransport();
    source = FakePhotoSource();
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  Future<(Channel, PhotoController)> pump(WidgetTester tester, List<(String, String)> msgs, {bool autoLoad = true, Set<String> own = const {}}) async {
    tester.view.physicalSize = const Size(393, 852) * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final ch = await kit.channel(1, 'Crew', kind: ChannelKind.private);
    for (final (who, text) in msgs) {
      kit.clockMs += 1000;
      kit.incoming(ch, who, text);
    }
    if (!autoLoad) savePhotosAutoLoad(kit.store, false);
    for (final id in own) {
      addOwnPhotoId(kit.store, id);
    }
    final photos = fakePhotos(kit.store, transport: transport, source: source);
    await tester.pumpWidget(darkIphone(ConversationScreen(controller: kit.controller, convKey: ch.convKey, photos: photos)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return (ch, photos);
  }

  testWidgets('loaded: a thumbnail with the rest of the text; neither the link nor the key is shown; the source gets the whole link', (tester) async {
    await pump(tester, [('Ann', 'summit view $privateUrlA')]);
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
    expect(find.textContaining('summit view'), findsOneWidget);
    expect(find.textContaining('meshsonar.com/e/'), findsNothing);
    expect(find.textContaining(privateKeyA), findsNothing);
    expect(find.byKey(const Key('photo-thumb-k3Xq9TzA')), findsOneWidget);
    expect(source.fetches, ['$privateUrlA|thumb']);
    expect(find.bySemanticsLabel(RegExp('Photo')), findsWidgets);
  });

  testWidgets('404/410 (the server deletes private photos after 30 days): "Photo expired", a tap does nothing', (tester) async {
    source.state = PhotoFetchState.removed;
    await pump(tester, [('Ann', privateUrlA)]);
    expect(find.text('Photo expired'), findsOneWidget);
    expect(find.byKey(const Key('photo-expired')), findsOneWidget);
    expect(find.text('Photo removed'), findsNothing);
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer')), findsNothing);
  });

  testWidgets('offline or a key that does not open it: the quiet "loads when online" placeholder, and a tap retries', (tester) async {
    source.state = PhotoFetchState.failed;
    await pump(tester, [('Ann', privateUrlA)]);
    expect(find.text('Photo, loads when online'), findsOneWidget);
    source.state = PhotoFetchState.ok;
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
  });

  testWidgets('"Load photos automatically" off: nothing is fetched until the tap', (tester) async {
    await pump(tester, [('Ann', privateUrlA)], autoLoad: false);
    expect(find.text('Tap to load photo'), findsOneWidget);
    expect(source.fetches, isEmpty);
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
  });

  testWidgets('a link with a broken key is an ordinary link, not a photo', (tester) async {
    await pump(tester, [('Ann', 'https://meshsonar.com/e/k3Xq9TzA#short')]);
    expect(find.byKey(const Key('photo-loaded')), findsNothing);
    expect(find.byKey(const Key('photo-loading')), findsNothing);
    expect(source.fetches, isEmpty);
    expect(find.textContaining('meshsonar.com/e/k3Xq9TzA#short'), findsOneWidget);
  });

  testWidgets('viewer: "Private photo", fetches the full copy, zoom, Save and Share link; no Delete for someone else\'s photo', (tester) async {
    await pump(tester, [('Ann', privateUrlA)]);
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
    expect(find.text('Private photo'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(source.fetches, contains('$privateUrlA|full'));
    expect(find.byKey(const Key('viewer-save')), findsOneWidget);
    expect(find.text('Share link'), findsOneWidget);
    expect(find.byKey(const Key('viewer-delete')), findsNothing);
  });

  group('report', () {
    Future<void> openReport(WidgetTester tester) async {
      await pump(tester, [('Ann', privateUrlA)]);
      await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('viewer-report')));
      await tester.pumpAndSettle();
      expect(find.textContaining('encrypted'), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-report-sexual')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-report-key-sheet')), findsOneWidget);
      expect(find.text('Let moderators see this photo?'), findsOneWidget);
    }

    testWidgets('"let moderators see it" sends the key with the report', (tester) async {
      await openReport(tester);
      await tester.tap(find.byKey(const Key('photo-report-share-key')));
      await tester.pumpAndSettle();
      expect(transport.reports.single.$1, 'k3Xq9TzA');
      expect(transport.reports.single.$2, PhotoReportReason.sexual);
      expect(transport.reportKeys.single, privateKeyA);
      expect(find.text('Reported. Thank you.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('"without showing the photo" reports without a key', (tester) async {
      await openReport(tester);
      await tester.tap(find.byKey(const Key('photo-report-no-key')));
      await tester.pumpAndSettle();
      expect(transport.reports, hasLength(1));
      expect(transport.reportKeys.single, isNull);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('dismissing the second sheet reports nothing', (tester) async {
      await openReport(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(transport.reports, isEmpty);
    });

    testWidgets('a plain photo report never asks about a key', (tester) async {
      await pump(tester, [('Ann', photoUrlA)]);
      await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('viewer-report')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-report-spam')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-report-key-sheet')), findsNothing);
      expect(transport.reportKeys.single, isNull);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('own private photo: Delete asks, deletes on the server and the viewer says "Photo expired"', (tester) async {
    await pump(tester, [('Me', privateUrlA)], own: {'k3Xq9TzA'});
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('viewer-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-photo')));
    await tester.pumpAndSettle();
    expect(transport.deletes, ['k3Xq9TzA']);
    expect(source.forgotten, [privateUrlA]);
    expect(find.byKey(const Key('viewer-expired')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('long-press menu: View, Save, "Share private link", Report; Delete only for own; the link is not an Open entry', (tester) async {
    await pump(tester, [('Ann', privateUrlA)]);
    final m = kit.store.messages.get('m0')!;
    final entries = MessageMenu.entries(m, photos: true, isOwnPhoto: (u) => false);
    expect(entries.map((e) => e.id), containsAll([MessageMenuId.viewPhoto, MessageMenuId.savePhoto, MessageMenuId.sharePhoto, MessageMenuId.reportPhoto]));
    expect(entries.where((e) => e.id == MessageMenuId.sharePhoto).single.label, 'Share private link');
    expect(entries.any((e) => e.id == MessageMenuId.openLink), isFalse);
    expect(entries.any((e) => e.id == MessageMenuId.deletePhoto), isFalse);
    final own = MessageMenu.entries(m, photos: true, isOwnPhoto: (u) => true);
    expect(own.any((e) => e.id == MessageMenuId.deletePhoto), isTrue);
    // The menu itself, from a long press on the thumbnail.
    await tester.longPress(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    expect(find.text('Share private link'), findsOneWidget);
    expect(find.text('Share photo'), findsNothing);
  });

  test('notification text hides the private link (and its key)', () {
    expect(hidePrivatePhotoLinks('look $privateUrlA now'), 'look [Private photo] now');
    expect(hidePrivatePhotoLinks('plain $photoUrlA'), 'plain $photoUrlA');
  });
}
