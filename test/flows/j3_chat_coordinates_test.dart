// J3 (plan 4.5 item 5): a chat message whose text holds coordinates gets "Open in Planner" and "Open on map". The parser is
// conservative (decimal lat, lon with three or more decimals, or a geo: URI; ranges checked; (0, 0) and hidden positions
// ignored); the chips send PlanRequest.point to the Plan tab and a MainMapFocus request with a target to the Drive map.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/chat/bubble_grouping.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/chat/message_bubble.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/map/layers/registry.dart' show kPlanLayerId;
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import '../ui/chat/chat_kit.dart' show ChatKit, host, setSize;
import 'flow_kit.dart';

MessageCoordinate? c(String t) => messageCoordinate(t);

void main() {
  group('parser', () {
    test('decimal pairs, with and without spaces, signs, a trailing full stop, inside a sentence', () {
      expect(c('Meet at 40.1234, -82.5678 at noon'), const MessageCoordinate(40.1234, -82.5678));
      expect(c('40.12345,-82.56789'), const MessageCoordinate(40.12345, -82.56789));
      expect(c('at (40.126; -82.931).'), const MessageCoordinate(40.126, -82.931));
      expect(c('-33.8688, 151.2093.'), const MessageCoordinate(-33.8688, 151.2093));
      expect(c('pin @40.0123,-83.0456'), const MessageCoordinate(40.0123, -83.0456));
    });
    test('geo: URIs, with a zoom or uncertainty after the pair', () {
      expect(c('geo:40.1234,-82.5678'), const MessageCoordinate(40.1234, -82.5678));
      expect(c('here geo:40.1,-82.5?z=15 ok'), const MessageCoordinate(40.1, -82.5));
      expect(c('GEO:40.1234,-82.5678;u=35'), const MessageCoordinate(40.1234, -82.5678));
    });
    test('the first place in the text wins', () {
      expect(c('geo:41.5000,-81.5000 or 40.1234, -82.5678'), const MessageCoordinate(41.5, -81.5));
      expect(c('40.1234, -82.5678 or geo:41.5000,-81.5000'), const MessageCoordinate(40.1234, -82.5678));
    });
    test('out of range, (0, 0) and near it, and unset positions are ignored', () {
      expect(c('91.0000, 10.0000'), isNull);
      expect(c('10.0000, 181.0000'), isNull);
      expect(c('geo:95,10'), isNull);
      expect(c('0.0000, 0.0000'), isNull);
      expect(c('geo:0,0'), isNull);
      expect(c('geo:0.0001,-0.0002'), isNull);
    });
    test('not coordinates: short decimals, versions, addresses, times, prices, plain numbers', () {
      expect(c('3.5, 4.2'), isNull);
      expect(c('rev 1.2.345, 6.789'), isNull);
      expect(c('ip 192.168.100.200'), isNull);
      expect(c('SNR 5.25, RSSI -97.5'), isNull);
      expect(c('12:30, 45'), isNull);
      expect(c('40.1234 -82.5678'), isNull, reason: 'no separator: too ambiguous');
      expect(c('40.1234,-82.56789012345'), isNull, reason: 'a longer number is not a coordinate');
      expect(c(''), isNull);
    });
    test('a hidden position (the node-name mark) is never turned into a button', () {
      expect(c('Hilltop \u{1F6AB} 40.1234, -82.5678'), isNull);
    });
  });

  group('chips', () {
    late ChatKit kit;
    setUp(() {
      kit = ChatKit();
      MessageMenu.useContextMenu = false;
    });
    tearDown(() => kit.dispose());

    Future<ChatMessage> message(String text) async {
      final ch = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
      kit.incoming(ch, 'Sam', text);
      return kit.service.page(ch.convKey).messages.first;
    }

    Widget bubble(ChatMessage m) => MessageBubble(
        key: ValueKey(m.id),
        slot: BubbleSlot(message: m, joinsOlder: false, joinsNewer: false, separatorAbove: false, showSender: false));

    testWidgets('a message with coordinates shows both chips; one without shows none; hidden or (0, 0) shows none', (tester) async {
      setSize(tester);
      final withCoord = await message('Dead spot at 40.1234, -82.5678 on the ridge');
      await tester.pumpWidget(host(bubble(withCoord)));
      expect(find.byKey(Key('coord-planner-${withCoord.id}')), findsOneWidget);
      expect(find.byKey(Key('coord-map-${withCoord.id}')), findsOneWidget);
      expect(find.text('Open in Planner'), findsOneWidget);
      expect(find.text('Open on map'), findsOneWidget);
      // VoiceOver: the bubble's custom actions carry both (the visible chips sit inside the excluded tree).
      final handle = tester.ensureSemantics();
      final data = tester.getSemantics(find.byKey(Key('bubble-${withCoord.id}'))).getSemanticsData();
      final labels = [for (final id in data.customSemanticsActionIds ?? const <int>[]) CustomSemanticsAction.getAction(id)?.label];
      expect(labels, containsAll(['Open in Planner', 'Open on map']));
      handle.dispose();

      for (final t in ['See you at noon', 'Hilltop \u{1F6AB} 40.1234, -82.5678', 'home 0.0000, 0.0000']) {
        final m = await message(t);
        await tester.pumpWidget(host(bubble(m)));
        expect(find.byKey(Key('coord-planner-${m.id}')), findsNothing, reason: t);
      }
    });

    for (final scale in [2.0, 3.0]) {
      testWidgets('chips fit at ${scale}x text (a conversation scrolls: no horizontal overflow)', (tester) async {
        setSize(tester, scale: scale);
        final m = await message('Dead spot at 40.1234, -82.5678 on the ridge');
        await tester.pumpWidget(host(SingleChildScrollView(child: bubble(m))));
        expect(tester.takeException(), isNull);
        expect(find.byKey(Key('coord-map-${m.id}')), findsOneWidget);
      });
    }
  });

  group('the real app', () {
    late ChatKit kit;
    setUp(() {
      kit = ChatKit();
      MessageMenu.useContextMenu = false;
    });
    tearDown(() => kit.dispose());

    Future<ChatMessage> message(String text) async {
      final ch = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
      kit.incoming(ch, 'Sam', text);
      return kit.service.page(ch.convKey).messages.first;
    }

    Widget bubble(ChatMessage m) => MessageBubble(
        slot: BubbleSlot(message: m, joinsOlder: false, joinsNewer: false, separatorAbove: false, showSender: false));

    testWidgets('Open in Planner: a pin from the message lands in the planner as a planned site', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final shell = shellOf(tester);
      await tapShellTab(tester, 'Chat');
      final m = await message('Good site: 40.1234, -82.5678');
      await pushOnRoot(tester, bubble(m));
      await tapKey(tester, 'coord-planner-${m.id}');
      await settle(tester);
      expect(shell.tab, AppTab.plan);
      final n = st.controller!.nodes.single;
      expect(n.name, 'From chat');
      expect(n.lat, 40.1234);
      expect(n.lon, -82.5678);
      expect(n.status.name, 'planned');
      await finish(tester);
    });

    testWidgets('Open on map: the Drive tab opens with the map looking there and a target on the plan layer', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final shell = shellOf(tester);
      await tapShellTab(tester, 'Chat');
      final m = await message('geo:40.1234,-82.5678?z=16');
      await pushOnRoot(tester, bubble(m));
      MainMapFocus.notifier.value = null;
      MainMapFocus.overlay.clear();
      await tapKey(tester, 'coord-map-${m.id}');
      expect(shell.tab, AppTab.drive);
      // The Drive map takes the request when it is built (the overlay then holds the target), else it waits in the notifier.
      final pending = MainMapFocus.notifier.value;
      final targets = MainMapFocus.overlay.targets.isNotEmpty ? MainMapFocus.overlay.targets : (pending?.targets ?? const <MapFocusTarget>[]);
      expect(targets.map((t) => t.at), [const LatLng(40.1234, -82.5678)]);
      expect(targets.single.label, 'From chat');
      expect(MainMapFocus.overlay.requestedLayers.contains(kPlanLayerId) || (pending?.showLayers.contains(kPlanLayerId) ?? false), isTrue);
      MainMapFocus.overlay.clear();
      MainMapFocus.notifier.value = null;
      await finish(tester);
    });

    testWidgets('with no shell (an isolated screen) the Planner chip says so instead of doing nothing', (tester) async {
      setSize(tester);
      final m = await message('Site 40.1234, -82.5678');
      await tester.pumpWidget(host(Builder(builder: (context) => Scaffold(body: bubble(m)))));
      await tester.tap(find.byKey(Key('coord-planner-${m.id}')));
      await tester.pump();
      expect(find.text('The planner is not available here.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
