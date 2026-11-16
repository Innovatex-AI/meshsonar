// Drive chip states and the Group sheet (plan 5.4, 5.5, 7, 8, 9): rows in metric and imperial, intro once, Undo on stop /
// leave / clear meet, the disabled 4th Share switch, Asked for 60 s, row tap centres the map, iPhone 17 Pro dark, iPad
// side panel, 2x text, VoiceOver labels and 44/48 pt targets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/drive/drive_controls.dart' show MeshTrackChip;
import 'package:meshsonar/ui/meshtrack/group_sheet.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';

import 'mt_kit.dart';

String chipLabel(WidgetTester t) => t.widget<Text>(find.byKey(const Key('meshtrack-chip-label'))).data!;

Future<void> openSheet(WidgetTester tester, MtRig rig, {int? channelId}) async {
  await tester.pumpWidget(rig.host(Opener((c) => showGroupSheet(c, channelId: channelId))));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

/// Scrolls the sheet's list until [f] is built and on screen.
Future<void> reveal(WidgetTester tester, Finder f, {double delta = 120}) async {
  final list = find.descendant(of: find.byWidgetPredicate((w) => w is ListView && (w.key == const Key('mt-groups') || w.key == const Key('mt-people'))), matching: find.byType(Scrollable)).first;
  if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, delta, scrollable: list);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Future<void> tapSwitch(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await reveal(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('Drive chip', () {
    testWidgets('MeshTrack when off; Sharing: names with the accent dot; paused: privacy zone; Waiting for GPS', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..addGroup(2, 'Saturday drive club')
        ..setRadioConnected(true)
        ..driveStarted();
      await tester.pumpWidget(rig.host(const Scaffold(body: Center(child: MeshTrackChip()))));
      expect(chipLabel(tester), 'MeshTrack');
      expect(find.byKey(const Key('meshtrack-chip-dot')), findsNothing);

      rig.svc.setShare(1, true);
      await tester.pump();
      expect(chipLabel(tester), 'Waiting for GPS', reason: 'no fix yet');

      rig.fix();
      await tester.pump();
      expect(chipLabel(tester), 'Sharing: Family');
      expect(find.byKey(const Key('meshtrack-chip-dot')), findsOneWidget);

      rig.svc.setShare(2, true);
      await tester.pump();
      expect(chipLabel(tester), 'Sharing: Family +1');

      rig.zones = PrivacyZones([PrivacyZone(lat: rig.here!.lat, lon: rig.here!.lon, radiusM: 300)]);
      rig.fix();
      await tester.pump();
      expect(chipLabel(tester), 'Sharing paused: privacy zone');

      final sem = tester.ensureSemantics();
      expect(tester.getSemantics(find.byKey(const Key('meshtrack-chip-hit'))), matchesSemantics(
        label: 'Sharing paused: privacy zone. Groups: Family, Saturday drive club. Opens your groups',
        isButton: true,
        hasTapAction: true,
      ));
      expect(tester.getSize(find.byKey(const Key('meshtrack-chip-hit'))).height, greaterThanOrEqualTo(48));
      sem.dispose();

      await tester.tap(find.byKey(const Key('meshtrack-chip-hit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-groups')), findsOneWidget, reason: 'tap opens the Group sheet');
      await rig.done(tester);
    });

    testWidgets('toasts: "Sam asked where you are" with Send my position, and Stopped sharing: radio disconnected + Share again', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.introSeen = true;
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      await tester.pumpWidget(rig.host(const Scaffold(body: Center(child: MeshTrackChip()))));
      rig.svc.onChannelText(MtInboundText(channelId: 1, text: 'Sam: MT1 ?', receivedAt: DateTime.now()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Sam asked where you are'), findsOneWidget);
      rig.fix();
      await tester.tap(find.text('Send my position'));
      await tester.pump();
      expect(find.text('Your position is on its way.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));

      rig.svc.setShare(1, true, duration: MtShareDuration.untilStopped);
      rig.svc.setRadioConnected(false);
      await tester.pump(const Duration(minutes: 5, seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Stopped sharing: radio disconnected'), findsOneWidget);
      rig.svc.setRadioConnected(true);
      await tester.tap(find.text('Share again'));
      await tester.pump();
      expect(rig.svc.state.group(1)!.config.share, isTrue);
      expect(rig.svc.state.group(1)!.config.duration, MtShareDuration.untilStopped);
      await rig.done(tester);
    });
  });

  group('intro before any share (Send my position, the asked toast, Share on every drive)', () {
    testWidgets('"asked where you are" toast: Send my position shows the intro first; Not now sends nothing', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      rig.fix();
      await tester.pumpWidget(rig.host(const Scaffold(body: Center(child: MeshTrackChip()))));
      rig.svc.onChannelText(MtInboundText(channelId: 1, text: 'Sam: MT1 ?', receivedAt: DateTime.now()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Send my position'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-intro')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-intro-not-now')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(rig.sent, isEmpty, reason: 'nothing goes out before the intro is accepted');
      expect(rig.ops.introSeen, isFalse);
      await rig.done(tester);
    });

    testWidgets('Send my position on the people page shows the intro first; Got it sends', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      rig.fix();
      await openSheet(tester, rig, channelId: 1);
      await tester.tap(find.byKey(const Key('mt-send-position')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-intro')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-intro-not-now')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(rig.sent, isEmpty);
      await tester.tap(find.byKey(const Key('mt-send-position')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mt-intro-ok')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(rig.ops.introSeen, isTrue);
      expect(rig.sent.single.$2, startsWith('MT1 @'));
      await rig.done(tester);
    });

    testWidgets('Share on every drive shows the intro first; Not now leaves it off', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc.addGroup(1, 'Family');
      await openSheet(tester, rig);
      await tester.tap(find.byKey(const Key('mt-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share on every drive'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-intro')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-intro-not-now')));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1)!.config.shareEveryDrive, isFalse);
      await rig.done(tester);
    });
  });

  group('Meet here from the people page', () {
    testWidgets('Approximate: the pin goes at 8 digits; the phone fix accuracy widens the zone buffer', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.accuracy = 5;
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true)
        ..setPositionMode(MtPositionMode.approximate);
      await openSheet(tester, rig, channelId: 1);
      await tester.tap(find.byKey(const Key('mt-meet-here')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      final code = rig.sent.single.$2.split(' ')[1].substring(1);
      expect(code.length, 9, reason: '8 digits + "+" in Approximate');
      await tester.pump(const Duration(seconds: 6));
      // 60 m outside the 200 m buffer: fine with a 5 m fix, refused with an 80 m fix.
      final h = rig.here!;
      rig.zones = PrivacyZones([PrivacyZone(lat: h.lat, lon: h.lon - 560 / (111320 * 0.7650), radiusM: 300)]);
      rig.accuracy = 80;
      await tester.tap(find.byKey(const Key('mt-meet-here')));
      await tester.pumpAndSettle();
      expect(find.textContaining('privacy zone'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
      expect(rig.sent, hasLength(1));
      await rig.done(tester);
    });
  });

  group('Group sheet: groups', () {
    testWidgets('no group yet: New group / Join / Use a private channel', (tester) async {
      phone(tester);
      final rig = MtRig();
      await openSheet(tester, rig);
      expect(find.byKey(const Key('mt-empty')), findsOneWidget);
      expect(find.byKey(const Key('mt-empty-new')), findsOneWidget);
      expect(find.byKey(const Key('mt-empty-join')), findsOneWidget);
      expect(find.byKey(const Key('mt-empty-existing')), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('Share on: intro once, then This drive / 1 hour / Until I stop inline; off: Stopped sharing + Undo', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..addGroup(2, 'Club')
        ..setRadioConnected(true)
        ..driveStarted();
      rig.fix();
      await openSheet(tester, rig);
      expect(find.text('No one heard in the last 30 min'), findsNWidgets(2));

      await tapSwitch(tester, 'mt-share-1');
      expect(find.byKey(const Key('mt-intro')), findsOneWidget);
      expect(find.textContaining('MeshSonar\'s servers never get it'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-intro-not-now')));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1)!.config.share, isFalse, reason: 'closing the intro keeps Share off');
      expect(rig.ops.introSeen, isFalse);

      await tapSwitch(tester, 'mt-share-1');
      await tester.tap(find.byKey(const Key('mt-intro-ok')));
      await tester.pumpAndSettle();
      expect(rig.ops.introSeen, isTrue);
      expect(rig.svc.state.group(1)!.config.share, isTrue);
      expect(rig.svc.state.group(1)!.config.duration, MtShareDuration.thisDrive, reason: 'This drive is the default');
      expect(find.byKey(const Key('mt-duration-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('mt-dur-oneHour')));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1)!.config.duration, MtShareDuration.oneHour);

      await tapSwitch(tester, 'mt-share-2');
      expect(find.byKey(const Key('mt-intro')), findsNothing, reason: 'the intro shows once');
      expect(rig.svc.state.group(2)!.config.share, isTrue);
      await reveal(tester, find.byKey(const Key('mt-status')), delta: -120);
      expect(find.text('Sharing with 2 groups: updates about every 2 min at highway speed.'), findsOneWidget);

      await tapSwitch(tester, 'mt-share-2');
      expect(rig.svc.state.group(2)!.config.share, isFalse);
      expect(find.text('Stopped sharing with Club'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(2)!.config.share, isTrue, reason: 'Undo shares again');
      await rig.done(tester);
    });

    testWidgets('a 4th Share switch is disabled with "Up to 3 groups"', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.introSeen = true;
      for (var i = 1; i <= 4; i++) {
        rig.svc.addGroup(i, 'G$i');
      }
      for (var i = 1; i <= 3; i++) {
        rig.svc.setShare(i, true);
      }
      await openSheet(tester, rig);
      await reveal(tester, find.byKey(const Key('mt-share-4')));
      expect(find.text('Up to 3 groups'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-share-4')));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(4)!.config.share, isFalse);
      await rig.done(tester);
    });

    testWidgets('group menu: Leave with Undo, Share on every drive, Start fresh shows the Invite screen with Undo', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.introSeen = true;
      rig.svc.addGroup(1, 'Family');
      await openSheet(tester, rig);
      await tester.tap(find.byKey(const Key('mt-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share on every drive'));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1)!.config.shareEveryDrive, isTrue);
      await tester.pump(const Duration(seconds: 3)); // the toast goes before the next menu opens under it
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mt-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1), isNull);
      expect(find.textContaining('Left Family'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1), isNotNull);
      expect(rig.ops.calls, contains('undoStop:1'));

      await tester.tap(find.byKey(const Key('mt-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start fresh'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-invite-qr')), findsOneWidget);
      expect(find.textContaining('This is a new group link'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(rig.ops.calls, contains('undoFresh:10'));
      await rig.done(tester);
    });

    testWidgets('a group not on the radio says so, with Make room, and its Share switch is off', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc.addGroup(1, 'Family');
      rig.ops.offRadio.add(1);
      await openSheet(tester, rig);
      expect(find.text('Not on this radio: it has no room for another channel'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-make-room-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-make-room-screen')), findsOneWidget);
      await rig.done(tester);
    });
  });

  group('Group sheet: people', () {
    for (final (name, units, dist, speed) in [('metric', Units.metric, 'km NE', '54 km/h'), ('imperial', Units.imperial, 'mi NE', '34 mph')]) {
      testWidgets('rows ($name): last heard, distance + compass point, route + SNR, speed; tap centres the map', (tester) async {
        phone(tester);
        final rig = MtRig()..units = units;
        rig.svc
          ..addGroup(1, 'Family')
          ..setRadioConnected(true);
        rig.hear(1, 'Sam', speed: 54, pathLen: 0);
        rig.hear(1, 'Ann', dLat: -0.01, dLon: -0.02, pathLen: 2, snr: -3);
        await openSheet(tester, rig, channelId: 1);
        expect(find.byKey(const Key('mt-people-title')), findsOneWidget);
        expect(find.textContaining(dist), findsOneWidget);
        expect(find.textContaining('direct · SNR 6.5 dB · $speed'), findsOneWidget);
        expect(find.textContaining('via 2 repeaters · SNR -3.0 dB'), findsOneWidget);
        await tester.tap(find.byKey(const Key('mt-friend-tap-Sam')));
        await tester.pump();
        expect(rig.centred, hasLength(1));
        await reveal(tester, find.byKey(const Key('mt-roster-footer')));
        expect(find.byKey(const Key('mt-roster-footer')), findsOneWidget);
        await rig.done(tester);
      });
    }

    testWidgets('Where are you? turns to Asked for 60 s; Message without chat explains', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      rig.hear(1, 'Sam');
      await openSheet(tester, rig, channelId: 1);
      await tester.tap(find.byKey(const Key('mt-ask-Sam')));
      await tester.pump();
      expect(find.text('Asked'), findsOneWidget);
      rig.clock = rig.clock.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      await tester.pump();
      expect(find.text('Where are you?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-message-Sam')));
      await tester.pump();
      expect(find.textContaining('Connect your radio once first'), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('Send my position, Meet here and Clear with Undo; empty state invites', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.introSeen = true;
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      await openSheet(tester, rig, channelId: 1);
      expect(find.text('No one has shared yet. Invite friends with the group link.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('mt-send-position')));
      await tester.pump();
      expect(find.textContaining('Waiting for GPS'), findsOneWidget, reason: 'no fix');
      rig.fix();
      await tester.tap(find.byKey(const Key('mt-send-position')));
      await tester.pump();
      expect(find.text('Your position is on its way to Family.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('mt-meet-here')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-meet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-meet-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-meet')), findsNothing);
      expect(find.text('Meet-up point cleared.'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-meet')), findsOneWidget, reason: 'Undo puts the meet-up point back');

      await tester.tap(find.byKey(const Key('mt-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-groups')), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('in a privacy zone the button says so and is disabled', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.introSeen = true;
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true)
        ..driveStarted()
        ..setShare(1, true);
      rig.zones = PrivacyZones([PrivacyZone(lat: rig.here!.lat, lon: rig.here!.lon, radiusM: 300)]);
      rig.fix();
      await openSheet(tester, rig, channelId: 1);
      expect(find.text('In a privacy zone'), findsOneWidget);
      await rig.done(tester);
    });
  });

  group('layout', () {
    testWidgets('iPhone 17 Pro dark: semantics labels and tap targets on the people page', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      rig.hear(1, 'Sam', speed: 54);
      final sem = tester.ensureSemantics();
      await openSheet(tester, rig, channelId: 1);
      expect(find.bySemanticsLabel(RegExp(r'^Sam, last heard just now, 4\.\d km NE')), findsOneWidget);
      expect(find.bySemanticsLabel('Message Sam'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Where are you\\? Ask Sam')), findsOneWidget);
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      sem.dispose();
      await rig.done(tester);
    }, variant: ios);

    testWidgets('iPad width: the Group sheet is a side panel', (tester) async {
      ipad(tester);
      final rig = MtRig();
      rig.svc.addGroup(1, 'Family');
      await openSheet(tester, rig);
      expect(find.byKey(const Key('mt-side-panel')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('mt-side-panel'))).width, 420);
      expect(tester.takeException(), isNull);
      await rig.done(tester);
    }, variant: ios);

    testWidgets('2x text: groups and people pages lay out without overflow', (tester) async {
      phone(tester, w: 375, h: 812, scale: 2.0);
      final rig = MtRig();
      rig.ops.introSeen = true;
      rig.svc
        ..addGroup(1, 'Saturday drive club crew')
        ..addGroup(2, 'Family')
        ..setRadioConnected(true)
        ..setShare(1, true);
      rig.hear(1, 'Samantha Longname', speed: 80, pathLen: 3);
      await openSheet(tester, rig);
      expect(tester.takeException(), isNull);
      await reveal(tester, find.byKey(const Key('mt-open-1')));
      await tester.tap(find.byKey(const Key('mt-open-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('mt-friend-Samantha Longname')), findsOneWidget);
      await rig.done(tester);
    }, variant: ios);
  });
}
