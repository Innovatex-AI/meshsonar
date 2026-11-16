// MeshTrack setup flows (plan 5.2, 5.3, 7 "Setup"): New group prefilled "<name>'s crew" -> Invite (QR, Share link, Done);
// radio full -> Make room; name rules; Join by scanning or pasting, with the joined banner; Use an existing private
// channel (eligible only, empty state); 2x text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/chat/channel_flows.dart' show ChatUiHooks;
import 'package:meshsonar/ui/chat/qr_widgets.dart' show defaultQrScan;
import 'package:meshsonar/ui/meshtrack/group_setup.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';

import 'mt_kit.dart';

const link = 'meshcore://channel/add?name=Saturday%20crew&secret=00112233445566778899aabbccddeeff';

Future<void> open(WidgetTester tester, MtRig rig, Future<void> Function(BuildContext) f) async {
  await tester.pumpWidget(rig.host(Opener(f)));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    MtSetupSeams.reset();
    ChatUiHooks.scanQr = defaultQrScan;
  });

  testWidgets('New group: prefilled "Andy\'s crew", Create goes to Invite with a big QR, Share link and Done', (tester) async {
    phone(tester);
    final rig = MtRig();
    String? shared;
    MtSetupSeams.shareText = (t) async => shared = t;
    await open(tester, rig, openNewGroup);
    final field = tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('mt-group-name')), matching: find.byType(EditableText)));
    expect(field.controller.text, "Andy's crew");
    await tester.tap(find.byKey(const Key('mt-create')));
    await tester.pumpAndSettle();
    expect(rig.ops.calls, ["create:Andy's crew"]);
    expect(find.byKey(const Key('mt-invite-qr')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('qr-view'))).width, greaterThanOrEqualTo(300), reason: 'a large QR code');
    expect(find.text("Andy's crew"), findsOneWidget);
    await tester.tap(find.byKey(const Key('mt-share-link')));
    await tester.pump();
    expect(shared, startsWith('meshcore://channel/add'));
    await tester.tap(find.byKey(const Key('mt-invite-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mt-invite')), findsNothing);
    expect(rig.svc.state.groups.single.name, "Andy's crew");
    await rig.done(tester);
  });

  testWidgets('New group: empty or # names are refused inline; a full radio offers Make room', (tester) async {
    phone(tester);
    final rig = MtRig();
    await open(tester, rig, openNewGroup);
    await tester.enterText(find.byKey(const Key('mt-group-name')), '#club');
    await tester.tap(find.byKey(const Key('mt-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mt-name-error')), findsOneWidget);
    expect(rig.ops.calls, isEmpty);
    await tester.enterText(find.byKey(const Key('mt-group-name')), '   ');
    await tester.tap(find.byKey(const Key('mt-create')));
    await tester.pumpAndSettle();
    expect(find.text('Give the channel a name.'), findsOneWidget);

    rig.ops.nextResult = const MtGroupOpResult(MtGroupOpStatus.radioFull);
    await tester.enterText(find.byKey(const Key('mt-group-name')), 'Family');
    await tester.tap(find.byKey(const Key('mt-create')));
    await tester.pumpAndSettle();
    expect(find.text('Not on this radio: it has no room for another channel'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mt-make-room')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mt-make-room-screen')), findsOneWidget);
    expect(find.text('Radio not connected'), findsOneWidget, reason: 'no chat in this rig: says what to do');
    await rig.done(tester);
  });

  testWidgets('Join by QR: scans, joins and says "Joined Saturday crew. They show on your map when they share."', (tester) async {
    phone(tester);
    final rig = MtRig();
    ChatUiHooks.scanQr = (_) async => link;
    await open(tester, rig, openJoinGroup);
    await tester.tap(find.byKey(const Key('mt-scan')));
    await tester.pumpAndSettle();
    expect(rig.ops.calls, ['join:$link']);
    expect(find.text('Joined Saturday crew. They show on your map when they share.'), findsOneWidget);
    expect(find.byKey(const Key('mt-join')), findsNothing);
    final g = rig.svc.state.groups.single;
    expect(g.config.see, isTrue, reason: 'See on');
    expect(g.config.share, isFalse, reason: 'Share stays off');
    await rig.done(tester);
  });

  testWidgets('Join by pasted link; nothing pasted and a bad link explain themselves', (tester) async {
    phone(tester);
    final rig = MtRig();
    MtSetupSeams.paste = () async => '  $link ';
    await open(tester, rig, openJoinGroup);
    await tester.tap(find.byKey(const Key('mt-join-go')));
    await tester.pumpAndSettle();
    expect(find.textContaining('paste its link first'), findsOneWidget);
    rig.ops.nextResult = const MtGroupOpResult(MtGroupOpStatus.notEligible);
    await tester.enterText(find.byKey(const Key('mt-join-link')), 'meshcore://channel/add?name=%23club&secret=00');
    await tester.tap(find.byKey(const Key('mt-join-go')));
    await tester.pumpAndSettle();
    expect(find.textContaining('A group needs a private channel'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mt-paste')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mt-join-go')));
    await tester.pumpAndSettle();
    expect(rig.ops.calls.last, 'join:$link');
    expect(find.textContaining('Joined Saturday crew'), findsOneWidget);
    await rig.done(tester);
  });

  testWidgets('Use an existing private channel: eligible channels only, and the empty state', (tester) async {
    phone(tester);
    final rig = MtRig();
    await open(tester, rig, openUseExisting);
    expect(find.text('No private channels to use'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    rig.ops.eligible = const [Channel(id: 7, radioId: 'r', slot: 3, name: 'Club', kind: ChannelKind.private)];
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mt-use-7')));
    await tester.pumpAndSettle();
    expect(rig.ops.calls, ['use:7']);
    expect(find.text('Club is now a MeshTrack group.'), findsOneWidget);
    expect(rig.svc.state.group(7), isNotNull);
    await rig.done(tester);
  });

  testWidgets('2x text: New group, Invite and Join lay out without overflow', (tester) async {
    phone(tester, w: 375, h: 812, scale: 2.0);
    final rig = MtRig();
    await open(tester, rig, openNewGroup);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('mt-create')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('mt-invite-done')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('mt-invite')), matching: find.byType(Scrollable)).first);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('mt-invite-done')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await rig.done(tester);
  }, variant: ios);
}
