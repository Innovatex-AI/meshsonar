// Round 3, the MeshTrack side of Chat: C-U2 (friends' position updates in a channel that is not a group are one line and an
// offer, never a bubble each, never unread), C-U7 (a group's thread opens its group in one tap) and D4 ("Share my position"
// in a direct message, following the privacy zones and Exact / Approximate).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/meshtrack/meshtrack_service.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;

import '../chat/chat_kit.dart';
import 'mt_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() {
    kit = ChatKit();
    appTipStore = MemoryTipStore();
  });
  tearDown(() {
    dismissAppToast();
    kit.dispose();
  });

  group('C-U2: position updates in a channel that is not a group', () {
    test('they are taken out of chat and counted per friend; the same update heard twice counts once', () async {
      final rig = MtRig();
      expect(rig.svc.onChannelText(MtInboundText(channelId: 3, text: 'Jo: MT1 @86GV429W+H34 s40 c46', receivedAt: rig.clock, senderTs: DateTime(2026, 11, 27, 9))), isTrue,
          reason: 'consumed: never a chat message, so never unread and never a notification');
      rig.svc.onChannelText(MtInboundText(channelId: 3, text: 'Jo: MT1 @86GV429W+H34 s40 c46', receivedAt: rig.clock, senderTs: DateTime(2026, 11, 27, 9)));
      rig.svc.onChannelText(MtInboundText(channelId: 3, text: 'Jo: MT1 @86GV429W+H35 s41 c46', receivedAt: rig.clock, senderTs: DateTime(2026, 11, 27, 9, 1)));
      rig.svc.onChannelText(MtInboundText(channelId: 3, text: 'Sam: MT1 @86GV429W+H36 s0', receivedAt: rig.clock, senderTs: DateTime(2026, 11, 27, 9, 2)));
      expect(rig.svc.onChannelText(MtInboundText(channelId: 3, text: 'Jo: see you there', receivedAt: rig.clock)), isFalse, reason: 'ordinary chat stays chat');
      final s = rig.svc.strayShares(3);
      expect({for (final x in s) x.name: x.updates}, {'Jo': 2, 'Sam': 1});
      expect(strayPositionsLine(s), anyOf('Sam and Jo shared their positions · 3 updates', 'Jo and Sam shared their positions · 3 updates'));
      expect(strayPositionsLine([s.firstWhere((x) => x.name == 'Jo')]), 'Jo shared their position · 2 updates');
      // The channel becomes a group: what was heard goes on the map and the line goes away.
      rig.svc.addGroup(3, 'Club');
      expect(rig.svc.strayShares(3), isEmpty);
      expect(rig.svc.state.group(3)!.friends.map((f) => f.name), containsAll(['Jo', 'Sam']));
      await rig.svc.dispose();
    });

    testWidgets('the thread shows ONE line for them and offers "Use for MeshTrack" once', (tester) async {
      phone(tester);
      final rig = MtRig();
      final ch = await kit.channel(3, 'Club');
      rig.ops.eligible = [ch];
      for (var i = 0; i < 6; i++) {
        rig.svc.onChannelText(MtInboundText(channelId: ch.id!, text: 'Jo: MT1 @86GV429W+H3${i + 2} s40 c46', receivedAt: rig.clock, senderTs: DateTime(2026, 11, 27, 9, i)));
      }
      await tester.pumpWidget(rig.host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      expect(find.text('Jo shared their position · 6 updates'), findsOneWidget);
      expect(find.byKey(const Key('stray-offer')), findsOneWidget);
      expect(kit.controller.unreadMessages, 0, reason: 'never unread');
      await tester.tap(find.byKey(const Key('stray-offer-use')));
      await tester.pumpAndSettle();
      expect(rig.ops.calls, contains('use:${ch.id}'));
      expect(find.byKey(const Key('stray-offer')), findsNothing);
      await rig.done(tester);
    });
  });

  testWidgets('C-U7: a MeshTrack group\'s thread has a people button that opens the group', (tester) async {
    phone(tester);
    final rig = MtRig();
    final ch = await kit.channel(4, 'Family');
    rig.svc.addGroup(ch.id!, 'Family');
    final other = await kit.channel(5, 'Ohio');
    await tester.pumpWidget(rig.host(ConversationScreen(controller: kit.controller, convKey: other.convKey)));
    await tester.pump();
    expect(find.byKey(const Key('conv-mt-group')), findsNothing, reason: 'not a group');
    await tester.pumpWidget(rig.host(ConversationScreen(key: UniqueKey(), controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.byKey(const Key('conv-mt-group')), findsOneWidget);
    await tester.tap(find.byKey(const Key('conv-mt-group')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Family'), findsWidgets);
    expect(find.byKey(const Key('conv-mt-group')), findsOneWidget);
    await rig.done(tester);
  });

  group('D4: Share my position in a direct message', () {
    test('Exact gives the fix; Approximate the middle of the 8-digit cell; nothing inside a privacy zone or without a fix', () async {
      final rig = MtRig();
      expect(rig.svc.positionMessageText().result, MtResult.waitingForGps);
      rig.fix();
      final exact = rig.svc.positionMessageText();
      expect(exact.result, MtResult.ok);
      expect(exact.text, 'My position: ${rig.here!.lat.toStringAsFixed(5)}, ${rig.here!.lon.toStringAsFixed(5)}');
      rig.svc.setPositionMode(MtPositionMode.approximate);
      final approx = rig.svc.positionMessageText();
      expect(approx.text, startsWith('My position (approximate): '));
      expect(approx.text!.contains(rig.here!.lat.toStringAsFixed(5)), isFalse, reason: 'never the fix itself');
      rig.zones = PrivacyZones([PrivacyZone(lat: rig.here!.lat, lon: rig.here!.lon, radiusM: 300)]);
      expect(rig.svc.positionMessageText().result, MtResult.privacyZone);
      expect(rig.svc.positionMessageText().text, isNull);
      // A phone fix newer than the service's own is used.
      rig.zones = const PrivacyZones([]);
      rig.svc.setPositionMode(MtPositionMode.exact);
      final phoneFix = MtFix(lat: 40.2, lon: -83.0, accuracyM: 5, at: rig.clock.add(const Duration(seconds: 1)));
      expect(rig.svc.positionMessageText(fix: phoneFix).text, 'My position: 40.20000, -83.00000');
      await rig.svc.dispose();
    });

    testWidgets('the composer button confirms who gets it and how fine, then sends one ordinary message', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.fix();
      kit.bob();
      await tester.pumpWidget(rig.host(ConversationScreen(controller: kit.controller, convKey: ConvKey.dm(bobKey))));
      await tester.pump();
      expect(find.byKey(const Key('composer-position')), findsOneWidget);
      await tester.tap(find.byKey(const Key('composer-position')));
      await tester.pumpAndSettle();
      expect(find.text('Share my position with Bob?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('share-position-confirm')));
      await tester.pumpAndSettle();
      final sent = kit.store.messages.page(ConvKey.dm(bobKey)).messages.single;
      expect(sent.text, startsWith('My position: '));
      await rig.done(tester);
    });

    testWidgets('inside a privacy zone nothing is sent and the reason is said; a channel has no such button', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.fix();
      rig.zones = PrivacyZones([PrivacyZone(lat: rig.here!.lat, lon: rig.here!.lon, radiusM: 300)]);
      kit.bob();
      await tester.pumpWidget(rig.host(ConversationScreen(controller: kit.controller, convKey: ConvKey.dm(bobKey))));
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-position')));
      await tester.pump();
      expect(find.textContaining('privacy zone'), findsOneWidget);
      expect(kit.store.messages.page(ConvKey.dm(bobKey)).messages, isEmpty);
      final ch = await kit.channel(1, 'Ohio');
      await tester.pumpWidget(rig.host(ConversationScreen(key: UniqueKey(), controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      expect(find.byKey(const Key('composer-position')), findsNothing);
      await rig.done(tester);
    });
  });
}
