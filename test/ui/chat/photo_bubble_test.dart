// Photo bubbles (iPhone, dark theme, per the test matrix): loaded thumbnail with the remaining text, loading placeholder,
// "Photo, loads when online", "Photo removed", "Tap to load photo" when automatic loading is off; the viewer (Report with a
// reason, Delete only for own uploads); the long-press menu's photo entries; the More > Chat switch; and two goldens.
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/photo_prefs.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';
import 'package:meshsonar/ui/chat/chat_settings_screen.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../support/photo_fakes.dart';
import 'chat_kit.dart';

const removedUrl = 'https://meshsonar.com/p/Rm0ved99';

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
    final ch = await kit.channel(1, 'Ohio');
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

  testWidgets('loaded: a rounded thumbnail of bounded size with the rest of the text; the link itself is not shown', (tester) async {
    await pump(tester, [('Ann', 'summit view $photoUrlA')]);
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
    expect(find.textContaining('summit view'), findsOneWidget);
    expect(find.textContaining('meshsonar.com/p/'), findsNothing);
    final size = tester.getSize(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    expect(size.width, lessThanOrEqualTo(240));
    expect(size.height, lessThanOrEqualTo(300));
    expect(source.fetches, ['$photoUrlA|thumb']);
    expect(find.descendant(of: find.byKey(const Key('photo-loaded')), matching: find.byType(ClipRRect)), findsOneWidget);
  });

  testWidgets('loading placeholder while the thumbnail is on its way', (tester) async {
    source.hold = Completer<void>();
    await pump(tester, [('Ann', photoUrlA)]);
    expect(find.byKey(const Key('photo-loading')), findsOneWidget);
    source.hold!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
  });

  testWidgets('offline / failed: "Photo, loads when online"; a tap tries again', (tester) async {
    source.state = PhotoFetchState.failed;
    await pump(tester, [('Ann', photoUrlA)]);
    expect(find.text('Photo, loads when online'), findsOneWidget);
    source.state = PhotoFetchState.ok;
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
  });

  testWidgets('410: "Photo removed", and a tap does nothing', (tester) async {
    source.state = PhotoFetchState.removed;
    await pump(tester, [('Ann', photoUrlA)]);
    expect(find.text('Photo removed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer')), findsNothing);
  });

  testWidgets('automatic loading off: "Tap to load photo", nothing fetched until the tap', (tester) async {
    await pump(tester, [('Ann', 'look $photoUrlA')], autoLoad: false);
    expect(find.text('Tap to load photo'), findsOneWidget);
    expect(source.fetches, isEmpty);
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
    expect(source.fetches, ['$photoUrlA|thumb']);
  });

  testWidgets('automatic loading off still shows a photo already on the phone', (tester) async {
    source.cachedUrls.add(photoUrlA);
    await pump(tester, [('Ann', photoUrlA)], autoLoad: false);
    expect(find.byKey(const Key('photo-loaded')), findsOneWidget);
    expect(source.fetches, isEmpty);
  });

  testWidgets('tap opens the viewer: pinch zoom, Save, Share, Report with a reason; no Delete for someone else\'s photo', (tester) async {
    await pump(tester, [('Ann', photoUrlA)]);
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(source.fetches, contains('$photoUrlA|full'));
    expect(find.byKey(const Key('viewer-save')), findsOneWidget);
    expect(find.byKey(const Key('viewer-share')), findsOneWidget);
    expect(find.byKey(const Key('viewer-delete')), findsNothing);
    await tester.tap(find.byKey(const Key('viewer-report')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-report-sheet')), findsOneWidget);
    for (final r in PhotoReportReason.values) {
      expect(find.text(r.label), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('photo-report-spam')));
    await tester.pumpAndSettle();
    expect(transport.reports.single, ('k3Xq9TzA', PhotoReportReason.spam, 'drv-key'));
    expect(find.text('Reported. Thank you.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('viewer-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer')), findsNothing);
    await tester.pump(const Duration(seconds: 10)); // let the toast go
  });

  testWidgets('own photo: Delete in the viewer asks, deletes on the server and shows "Photo removed"', (tester) async {
    await pump(tester, [('Ann', photoUrlA)], own: {'k3Xq9TzA'});
    await tester.tap(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('viewer-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-photo')));
    await tester.pumpAndSettle();
    expect(transport.deletes, ['k3Xq9TzA']);
    expect(find.byKey(const Key('viewer-removed')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('long-press menu: View, Save, Share, Report; Delete photo only for own uploads; the photo link is not an Open entry', (tester) async {
    await pump(tester, [('Ann', 'mine $photoUrlA'), ('Bob', 'theirs $photoUrlB')], own: {'k3Xq9TzA'});
    final ms = kit.store.messages;
    final mine = ms.get('m0')!, theirs = ms.get('m1')!;
    bool ownCheck(String u) => u == photoUrlA;
    final a = MessageMenu.entries(mine, photos: true, isOwnPhoto: ownCheck).map((e) => e.id).toList();
    expect(a, containsAllInOrder([MessageMenuId.copy, MessageMenuId.viewPhoto, MessageMenuId.savePhoto, MessageMenuId.sharePhoto, MessageMenuId.reportPhoto]));
    expect(a, contains(MessageMenuId.deletePhoto));
    expect(a, isNot(contains(MessageMenuId.openLink)));
    final b = MessageMenu.entries(theirs, photos: true, isOwnPhoto: ownCheck).map((e) => e.id).toList();
    expect(b, isNot(contains(MessageMenuId.deletePhoto)));
    // Without photo support (previews) the link is an ordinary Open entry.
    expect(MessageMenu.entries(theirs).map((e) => e.id), contains(MessageMenuId.openLink));

    await tester.longPress(find.byKey(const Key('photo-thumb-k3Xq9TzA')));
    await tester.pumpAndSettle();
    expect(find.text('View photo'), findsOneWidget);
    expect(find.text('Delete photo'), findsOneWidget);
    await tester.tap(find.byKey(const Key('act-reportPhoto')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-report-violence')));
    await tester.pumpAndSettle();
    expect(transport.reports.single.$2, PhotoReportReason.violence);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('More > Chat: "Load photos automatically" is on, says it contacts the server, and switches the bubbles', (tester) async {
    setSize(tester);
    final photos = fakePhotos(kit.store, transport: transport, source: source);
    await tester.pumpWidget(darkIphone(ChatSettingsScreen(controller: kit.controller, photos: photos)));
    await tester.pump();
    expect(find.text('Load photos automatically'), findsOneWidget);
    expect(find.textContaining('contacts the MeshSonar server'), findsOneWidget);
    final sw = find.byKey(const Key('chat-photos-autoload'));
    expect(tester.widget<CupertinoSwitch>(sw).value, isTrue);
    await tester.tap(sw);
    await tester.pump();
    expect(photos.autoLoad, isFalse);
    expect(loadPhotosAutoLoad(kit.store), isFalse);
  });

  group('goldens (iPhone, dark)', () {
    testWidgets('photo bubbles: loaded with text, offline, removed, own', (tester) async {
      source.byUrl[photoUrlB] = PhotoFetchState.failed;
      source.byUrl[removedUrl] = PhotoFetchState.removed;
      final r = await pump(tester, [('Ann', 'Summit view from the tower $photoUrlA'), ('Dave', photoUrlB), ('Maya', 'old one $removedUrl')]);
      kit.clockMs += 1000;
      kit.service.send(radioId: radioA, convKey: r.$1.convKey, text: 'nice! $photoUrlA');
      await tester.pump();
      // Decode the thumbnails for real (fake time never finishes an image decode).
      await tester.runAsync(() async {
        for (final e in find.byType(Image).evaluate()) {
          await precacheImage((e.widget as Image).image, e);
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/photo_bubbles-dark.png'));
    });

    testWidgets('photo bubble with automatic loading off', (tester) async {
      await pump(tester, [('Ann', 'look at this $photoUrlA')], autoLoad: false);
      await tester.pump(const Duration(milliseconds: 200));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/photo_tap_to_load-dark.png'));
    });
  });
}
