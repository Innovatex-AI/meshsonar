// MeshTrack in the chat screens and Settings (plan 1.4, 5.3, 5.8, 7): the Chats row badge, channel detail "Use for
// MeshTrack" / "MeshTrack group" / "Show position messages", the Message helper (DM for an exact contact name, else the
// group channel with @[name] typed), Make room, and Settings > MeshTrack rows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/bubble_grouping.dart';
import 'package:meshsonar/chat/conversation_row.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/chat/channel_detail_screen.dart';
import 'package:meshsonar/ui/chat/conversation_tile.dart';
import 'package:meshsonar/ui/chat/message_bubble.dart';
import 'package:meshsonar/ui/meshtrack/group_setup.dart' show MakeRoomScreen;
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';
import 'package:meshsonar/ui/meshtrack/mt_message.dart';
import 'package:meshsonar/ui/settings/meshtrack_section.dart';

import '../chat/chat_kit.dart';
import 'mt_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
  tearDown(() => kit.dispose());

  testWidgets('Chats row: a MeshTrack group channel has the badge and says so to VoiceOver; other channels do not', (tester) async {
    phone(tester);
    final rig = MtRig();
    rig.svc.addGroup(5, 'Family');
    ConversationRow row(int id, String title) =>
        ConversationRow(key: ConvKey.channel(id), convKind: ConvKind.channel, kind: RowKind.privateChannel, title: title, avatarSeed: '$id', channelId: id);
    final sem = tester.ensureSemantics();
    await tester.pumpWidget(rig.host(Scaffold(
      body: Column(children: [
        ConversationTile(key: const Key('t5'), row: row(5, 'Family'), stamp: '12:00', onTap: () {}),
        ConversationTile(key: const Key('t6'), row: row(6, 'Club'), stamp: '12:00', onTap: () {}),
      ]),
    )));
    expect(find.descendant(of: find.byKey(const Key('t5')), matching: find.byKey(const Key('meshtrack-badge'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('t6')), matching: find.byKey(const Key('meshtrack-badge'))), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^Family, MeshTrack group')), findsOneWidget);
    sem.dispose();
    await rig.done(tester);
  });

  testWidgets('a MeshTrack message kept as chat reads as words in its bubble, not "MT1 @..." (sim tour)', (tester) async {
    setSize(tester);
    final ch = await kit.channel(2, 'Saturday crew');
    kit.incoming(ch, 'Jo N8JO', 'MT1 @86GV429W+H34 s40 c46');
    final m = kit.service.page(ch.convKey).messages.first;
    await tester.pumpWidget(host(MessageBubble(
        key: ValueKey(m.id), slot: BubbleSlot(message: m, joinsOlder: false, joinsNewer: false, separatorAbove: false, showSender: true))));
    expect(find.text('Shared their position (MeshTrack)'), findsOneWidget);
    expect(find.textContaining('MT1'), findsNothing);
  });

  testWidgets('channel detail: Use for MeshTrack on an eligible private channel, then MeshTrack group + Show position messages; off has Undo', (tester) async {
    phone(tester);
    final rig = MtRig();
    final ch = await kit.channel(2, 'Club');
    rig.ops.eligible = [ch];
    await tester.pumpWidget(rig.host(ChannelDetailScreen(controller: kit.controller, channelId: ch.id!)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('mt-use-switch')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('mt-group-row')), findsNothing);
    await tester.tap(find.byKey(const Key('mt-use-switch')));
    await tester.pumpAndSettle();
    expect(rig.ops.calls, ['use:${ch.id}']);
    expect(find.byKey(const Key('mt-group-row')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mt-show-positions')));
    await tester.pumpAndSettle();
    expect(rig.ops.showPositions, {ch.id});

    await tester.tap(find.byKey(const Key('mt-use-switch')));
    await tester.pumpAndSettle();
    expect(rig.svc.state.group(ch.id!), isNull);
    expect(find.text('Club is no longer a MeshTrack group.'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(rig.svc.state.group(ch.id!), isNotNull);
    await rig.done(tester);
  });

  testWidgets('channel detail: an open channel gets no MeshTrack rows', (tester) async {
    phone(tester);
    final rig = MtRig();
    final ch = await kit.channel(3, '#club', kind: ChannelKind.hashtag);
    await tester.pumpWidget(rig.host(ChannelDetailScreen(controller: kit.controller, channelId: ch.id!)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mt-use-switch')), findsNothing);
    await rig.done(tester);
  });

  test('Message: a contact with exactly that name gets a DM, anyone else the group channel with @[name] typed', () async {
    final ch = await kit.channel(1, 'Family');
    kit.bob(name: 'Sam');
    expect(mtMessageTarget(kit.controller, ch.id!, 'Sam'), isA<MtMessageDirect>());
    final t = mtMessageTarget(kit.controller, ch.id!, 'sam');
    expect(t, isA<MtMessageChannel>(), reason: 'exact name only');
    expect((t as MtMessageChannel).prefill, '@[sam] ');
  });

  testWidgets('Message opens the channel conversation with the mention already in the composer', (tester) async {
    phone(tester);
    final rig = MtRig()..chat = kit.controller;
    final ch = await kit.channel(1, 'Family');
    await tester.pumpWidget(rig.host(Opener((c) => openMtMessage(c, kit.controller, ch.id!, 'Ann'))));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(kit.service.loadDraft(ch.convKey), '@[Ann] ');
    expect(find.textContaining('@[Ann]'), findsWidgets);
    await rig.done(tester);
  });

  testWidgets('Make room lists the radio\'s channels (not Public); a tap opens the channel page with Delete', (tester) async {
    phone(tester);
    final rig = MtRig()..chat = kit.controller;
    await kit.channel(0, 'Public', kind: ChannelKind.public);
    final club = await kit.channel(2, 'Club');
    await tester.pumpWidget(rig.host(const MakeRoomScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Public'), findsNothing);
    await tester.tap(find.byKey(Key('mt-room-${club.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channel-detail')), findsOneWidget);
    await rig.done(tester);
  });

  testWidgets('Settings > MeshTrack: Groups, Position friends see (Exact / Approximate with sizes), Update rate, Answer', (tester) async {
    phone(tester);
    final rig = MtRig()..units = Units.imperial;
    rig.svc.addGroup(1, 'Family');
    await tester.pumpWidget(rig.host(Scaffold(body: Builder(builder: (c) => ListView(children: meshTrackSectionRows(c))))));
    expect(find.text('1 group'), findsOneWidget);
    expect(find.text('Exact (about 10 ft)'), findsOneWidget);
    expect(find.text('Approximate (about 0.2 mi)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('meshtrack-position-approximate')));
    await tester.pumpAndSettle();
    expect(rig.ops.mode, MtPositionMode.approximate);
    expect(rig.svc.state.positionMode, MtPositionMode.approximate);
    await tester.tap(find.byKey(const Key('meshtrack-rate-lowTraffic')));
    await tester.pumpAndSettle();
    expect(rig.ops.rateValue, MtRate.lowTraffic);
    await tester.ensureVisible(find.byKey(const Key('meshtrack-answer')));
    await tester.tap(find.byKey(const Key('meshtrack-answer')));
    await tester.pumpAndSettle();
    expect(rig.ops.answer, isFalse);
    await tester.ensureVisible(find.byKey(const Key('meshtrack-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('meshtrack-groups')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mt-groups')), findsOneWidget, reason: 'Groups opens the Group sheet');
    await rig.done(tester);
  });

  test('Settings entries: the four ids of the plan, never called precision', () {
    expect([for (final e in meshTrackSettingsEntries) e.id], ['meshtrack-groups', 'meshtrack-position', 'meshtrack-rate', 'meshtrack-answer']);
    for (final e in meshTrackSettingsEntries) {
      expect('${e.title} ${e.summary}'.toLowerCase(), isNot(contains('precision')));
    }
  });
}
