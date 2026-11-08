// No text anywhere in the app may get Flutter's debug fallback style (red monospace, yellow double underline). Andy saw it on
// TestFlight 0.28.1+47 in the long-press message card, Full details, Path on map, and flashing on text while a page slid in
// or out. MaterialApp's own default text style is that fallback; only a Material/Scaffold replaced it, and a lot of text is
// drawn with neither above it: the context menu (a PopupRoute), CupertinoPageScaffold pages, the nav-bar title/back-label
// hero that flies between pages, overlay entries, Cupertino popups. The fix is app-wide: `meshSonarAppBuilder` (app.dart)
// puts the Material body style under MaterialApp and above the Navigator and its Overlay.
//
// Every check walks every RenderParagraph on every pumped frame (mid-animation included), not just the settled screen.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_info_card.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/contacts/message_details.dart';

import 'chat/chat_kit.dart';
import 'fakes.dart';

/// True for Flutter's debug fallback text style (MaterialApp's `_errorTextStyle`): yellow double underline.
bool _isFallback(TextStyle? s) =>
    s != null &&
    s.decoration == TextDecoration.underline &&
    s.decorationStyle == TextDecorationStyle.double &&
    s.decorationColor == const Color(0xFFFFFF00);

bool _spanHasFallback(InlineSpan span) {
  var bad = false;
  span.visitChildren((s) {
    if (_isFallback(s.style)) bad = true;
    return !bad;
  });
  return bad;
}

/// Every text on screen (overlay, popups and hero flights included) drawn in the fallback style, for this frame.
List<String> _fallbackTexts(WidgetTester tester) => [
      for (final p in tester.allRenderObjects.whereType<RenderParagraph>())
        if (_spanHasFallback(p.text)) p.text.toPlainText(),
    ];

/// Pumps [frames] frames [step] apart and collects every fallback text seen on any of them (the transition frames are
/// where the flash was).
Future<Set<String>> _watch(WidgetTester tester, {int frames = 20, Duration step = const Duration(milliseconds: 25)}) async {
  final seen = <String>{..._fallbackTexts(tester)};
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
    seen.addAll(_fallbackTexts(tester));
  }
  await tester.pumpAndSettle();
  seen.addAll(_fallbackTexts(tester));
  return seen;
}

/// A Cupertino page with a nav bar, as the conversation and path-map screens are built (no Scaffold, no Material).
class _CupertinoPage extends StatelessWidget {
  final String title;
  const _CupertinoPage(this.title);
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(middle: Text(title), trailing: const Text('Edit')),
        child: SafeArea(child: Center(child: Text('$title body'))),
      );
}

void main() {
  group('the real app (MeshSonarApp) on iOS', () {
    late Harness h;
    late NavigatorState nav;

    Future<void> app(WidgetTester tester) async {
      h = Harness();
      await h.state.init();
      await tester.pumpWidget(MeshSonarApp(state: h.state));
      await tester.pump();
      nav = Navigator.of(tester.element(find.byType(Scaffold).first), rootNavigator: true);
    }

    testWidgets('Cupertino pages pushed and popped: no fallback text on any frame, nav-bar hero flights included', (tester) async {
      await app(tester);
      nav.push(CupertinoPageRoute<void>(builder: (_) => const _CupertinoPage('First')));
      expect(await _watch(tester), isEmpty, reason: 'push of a CupertinoPageScaffold page');
      nav.push(CupertinoPageRoute<void>(builder: (_) => const _CupertinoPage('Second')));
      expect(await _watch(tester), isEmpty, reason: 'nav bar to nav bar: the title and back label fly as heroes');
      nav.pop();
      expect(await _watch(tester), isEmpty, reason: 'pop back: the heroes fly back');
      nav.pop();
      expect(await _watch(tester), isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('bare routes, overlay entries and Cupertino popups: no fallback text', (tester) async {
      await app(tester);
      nav.push(PageRouteBuilder<void>(pageBuilder: (_, _, _) => const Center(child: Text('bare page'))));
      expect(await _watch(tester), isEmpty, reason: 'a route with no Scaffold/Material');
      nav.pop();
      await tester.pumpAndSettle();

      final entry = OverlayEntry(builder: (_) => const Positioned(top: 100, left: 20, child: Text('overlay text')));
      nav.overlay!.insert(entry);
      expect(await _watch(tester, frames: 2), isEmpty, reason: 'an OverlayEntry');
      entry.remove();
      await tester.pump();

      showCupertinoModalPopup<void>(context: nav.context, builder: (_) => const Center(child: Text('popup text')));
      expect(await _watch(tester), isEmpty, reason: 'showCupertinoModalPopup content');
      nav.pop();
      await tester.pumpAndSettle();

      showGeneralDialog<void>(context: nav.context, pageBuilder: (_, _, _) => const Center(child: Text('general dialog')));
      expect(await _watch(tester), isEmpty, reason: 'showGeneralDialog content');
      nav.pop();
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('the app root draws text in the Material body style, not the fallback', (tester) async {
      await app(tester);
      final style = DefaultTextStyle.of(nav.overlay!.context).style;
      expect(_isFallback(style), isFalse);
      expect(style.fontSize, Theme.of(nav.context).textTheme.bodyMedium!.fontSize);
    });
  });

  group('chat: long-press card, Full details, Path on map', () {
    late ChatKit kit;
    setUp(() {
      kit = ChatKit();
      MessageMenu.useContextMenu = true;
      MessagePathMapScreen.mapBuilder = (context, placed, connect) => Text('MAP ${placed.length}', key: const Key('fake-map'));
    });
    tearDown(() {
      kit.dispose();
      MessagePathMapScreen.mapBuilder = null;
    });

    // The app's MaterialApp wiring (theme + meshSonarAppBuilder), on iOS.
    Widget iosApp(Widget home) => MaterialApp(
          theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
          builder: meshSonarAppBuilder,
          home: home,
        );

    testWidgets('every frame of: open the context menu, Path on map (push and back), Full details (open and close)', (tester) async {
      setSize(tester);
      kit.store.contacts.upsert(Contact(radioId: radioA, publicKey: 'a1'.padRight(64, '0'), type: ContactType.repeater, name: 'Ridge', lat: 40, lon: -83));
      final ch = await kit.channel(1, 'Ohio');
      kit.sink.connected = true;
      final sent = kit.service.send(radioId: radioA, convKey: ch.convKey, text: 'on my way');
      await kit.service.pump();
      final ts = kit.store.messages.get(sent.id)!.tsSender;
      kit.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: ts, text: 'Me: on my way', pathHashes: 'a1', hops: 1, snr: 6.5, rssi: -92));
      final m = kit.store.messages.get(sent.id)!;

      // The Chats-list -> thread push itself (a MaterialPageRoute to a CupertinoPageScaffold screen).
      await tester.pumpWidget(iosApp(const Scaffold(body: SizedBox())));
      Navigator.of(tester.element(find.byType(Scaffold))).push(MaterialPageRoute<void>(builder: (_) => ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      expect(await _watch(tester), isEmpty, reason: 'opening the conversation');

      // Hold the bubble: the menu lifts it into a PopupRoute and adds the info card.
      final g = await tester.startGesture(tester.getCenter(find.byKey(Key('bubble-${m.id}'))));
      final opening = <String>{};
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        opening.addAll(_fallbackTexts(tester));
      }
      await g.up();
      opening.addAll(await _watch(tester));
      expect(find.byKey(const Key('message-info-card')), findsOneWidget);
      expect(opening, isEmpty, reason: 'the lifted bubble, the info card and the menu actions');

      // Path on map: closes the menu, then pushes the map page (CupertinoPageRoute).
      await tester.tap(find.byKey(Key('menu-pathMap-${m.id}')));
      expect(await _watch(tester, frames: 30), isEmpty, reason: 'menu closing and the path map sliding in');
      expect(find.byKey(const Key('path-map-screen')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const Key('path-map-screen')))).pop();
      expect(await _watch(tester), isEmpty, reason: 'path map sliding out');

      // Full details: the sheet.
      final g2 = await tester.startGesture(tester.getCenter(find.byKey(Key('bubble-${m.id}'))));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await g2.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('menu-details-${m.id}')));
      expect(await _watch(tester, frames: 30), isEmpty, reason: 'Full details sheet opening');
      expect(find.byType(MessageDetails), findsOneWidget);
      Navigator.of(tester.element(find.byType(MessageDetails))).pop();
      expect(await _watch(tester), isEmpty, reason: 'Full details sheet closing');
    });
  });
}
