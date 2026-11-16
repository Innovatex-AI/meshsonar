// MeshTrack in the Drive panel (build 69): the Medium row in every state (no group, no radio, one group with its Share
// switch, sharing with the accent dot, paused, waiting for GPS, friends nearby, several groups), the "New" tag, the Dock
// button (sharing dot), the toasts host, and the real Drive panel at iPhone SE and iPhone 17 Pro widths, 1x and 2x text,
// Ready / driving / Drive saved, with and without a radio: no overflow, every target 48 pt.
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/panel/panel_dock.dart' show DockHero;
import 'package:meshsonar/ui/drive/panel/panel_meshtrack.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';

import '../fakes.dart';
import '../meshtrack/mt_kit.dart';

String line(WidgetTester t) => t.widget<Text>(find.byKey(const Key('mt-panel-subtitle'))).data!;

Widget rowHost(MtRig rig) => rig.host(const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: Column(children: [MeshTrackPanelRow(), MeshTrackDockButton()]))));

void main() {
  group('Medium row', () {
    testWidgets('no group: "Share your position with friends", chevron, tap opens the Group sheet with New group / Join', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc.setRadioConnected(true);
      await tester.pumpWidget(rowHost(rig));
      expect(find.text('MeshTrack'), findsWidgets);
      expect(line(tester), 'Share your position with friends');
      expect(find.byKey(const Key('mt-panel-share')), findsNothing, reason: 'no group: no switch');
      expect(find.byKey(const Key('mt-panel-dot')), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      final sem = tester.ensureSemantics();
      expect(tester.getSemantics(find.byKey(const Key('mt-panel-row'))),
          matchesSemantics(label: 'MeshTrack. Share your position with friends. Opens your groups', isButton: true, hasTapAction: true));
      sem.dispose();
      expect(tester.getSize(find.byKey(const Key('mt-panel-row'))).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('mt-panel-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-empty-new')), findsOneWidget);
      expect(find.byKey(const Key('mt-empty-join')), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('no radio: "Connect your radio to share"; the switch is off and disabled; a tap still opens the sheet', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc.addGroup(1, 'Family');
      await tester.pumpWidget(rowHost(rig));
      expect(line(tester), 'Connect your radio to share');
      final sw = tester.widget<CupertinoSwitch>(find.byKey(const Key('mt-panel-share')));
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNull, reason: 'nothing to send with no radio');
      await tester.tap(find.byKey(const Key('mt-panel-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-groups')), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('one group: Share switch shows the intro once, shares with the group\'s duration, stop has Undo', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true)
        ..driveStarted();
      await tester.pumpWidget(rowHost(rig));
      expect(line(tester), 'Not sharing with Family');
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing, reason: 'the switch takes the trailing place');
      final sem = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Share my position with Family'), findsOneWidget);
      sem.dispose();

      await tester.tap(find.byKey(const Key('mt-panel-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-intro')), findsOneWidget, reason: 'the first share shows the intro');
      await tester.tap(find.byKey(const Key('mt-intro-ok')));
      await tester.pumpAndSettle();
      expect(rig.svc.state.group(1)!.config.share, isTrue);
      expect(line(tester), 'Waiting for GPS');
      expect(find.byKey(const Key('mt-panel-dot')), findsOneWidget);

      rig.fix();
      await tester.pump();
      expect(line(tester), 'Sharing: Family');
      expect(find.byKey(const Key('mt-dock-dot')), findsOneWidget, reason: 'the Dock button says it is sending');

      await tester.tap(find.byKey(const Key('mt-panel-share')));
      await tester.pump();
      expect(rig.svc.state.group(1)!.config.share, isFalse);
      expect(find.text('Stopped sharing with Family'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(rig.svc.state.group(1)!.config.share, isTrue);

      // A chosen duration is kept: 1 hour, stop, share again from the panel -> 1 hour again, no second intro.
      rig.svc.setShare(1, true, duration: MtShareDuration.oneHour);
      rig.svc.setShare(1, false);
      await tester.pump(const Duration(seconds: 6));
      await tester.tap(find.byKey(const Key('mt-panel-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-intro')), findsNothing);
      expect(rig.svc.state.group(1)!.config.duration, MtShareDuration.oneHour);
      await rig.done(tester);
    });

    testWidgets('one group not on this radio: the switch is disabled', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc
        ..addGroup(1, 'Family')
        ..setRadioConnected(true);
      rig.ops.offRadio.add(1);
      await tester.pumpWidget(rowHost(rig));
      expect(tester.widget<CupertinoSwitch>(find.byKey(const Key('mt-panel-share'))).onChanged, isNull);
      await rig.done(tester);
    });

    testWidgets('several groups: names, +N, paused in a privacy zone (warning dot), friends nearby, chevron opens the sheet', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.introSeen = true;
      rig.svc
        ..addGroup(1, 'Family')
        ..addGroup(2, 'Saturday drive club')
        ..setRadioConnected(true)
        ..driveStarted();
      await tester.pumpWidget(rowHost(rig));
      expect(line(tester), '2 groups, not sharing');
      expect(find.byKey(const Key('mt-panel-share')), findsNothing);

      rig.hear(1, 'Sam');
      rig.hear(2, 'Jo', dLat: -0.02);
      await tester.pump();
      expect(line(tester), '2 friends nearby');

      rig.fix();
      rig.svc
        ..setShare(1, true)
        ..setShare(2, true);
      await tester.pump();
      expect(line(tester), 'Sharing: Family +1');
      final sem = tester.ensureSemantics();
      expect(tester.getSemantics(find.byKey(const Key('mt-panel-row'))).label,
          'MeshTrack. Sharing: Family +1. Groups: Family, Saturday drive club. Opens your groups');
      sem.dispose();

      rig.zones = PrivacyZones([PrivacyZone(lat: rig.here!.lat, lon: rig.here!.lon, radiusM: 300)]);
      rig.fix();
      await tester.pump();
      expect(line(tester), 'Sharing paused: privacy zone');
      expect(find.byKey(const Key('mt-panel-dot')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mt-panel-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-groups')), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('"New" tag: shown while armed, gone after the row is opened once', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.ops.newTag = true;
      rig.svc.setRadioConnected(true);
      await tester.pumpWidget(rowHost(rig));
      expect(find.byKey(const Key('mt-panel-new')), findsOneWidget);
      final sem = tester.ensureSemantics();
      expect(tester.getSemantics(find.byKey(const Key('mt-panel-row'))).label, startsWith('MeshTrack, new. '));
      sem.dispose();
      await tester.tap(find.byKey(const Key('mt-panel-row')));
      await tester.pumpAndSettle();
      expect(rig.ops.calls, contains('panelSeen'));
      Navigator.of(tester.element(find.byKey(const Key('mt-groups')))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-panel-new')), findsNothing);
      await rig.done(tester);
    });
  });

  group('Dock button', () {
    testWidgets('not sharing: people icon over MeshTrack, no dot; tap opens the sheet; 56 x 52', (tester) async {
      phone(tester);
      final rig = MtRig();
      rig.svc.setRadioConnected(true);
      await tester.pumpWidget(rowHost(rig));
      expect(find.byKey(const Key('mt-dock-dot')), findsNothing);
      expect(tester.getSize(find.byKey(const Key('mt-dock-hit'))), const Size(56, 52));
      await tester.tap(find.byKey(const Key('mt-dock-hit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-empty')), findsOneWidget);
      await rig.done(tester);
    });

    testWidgets('nothing at all when MeshTrack is off in this build', (tester) async {
      phone(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [MeshTrackPanelRow(), MeshTrackDockButton()]))));
      expect(find.byKey(const Key('mt-dock-hit')), findsNothing);
      expect(find.byKey(const Key('mt-panel-row')), findsNothing);
    });
  });

  group('the real Drive panel', () {
    Future<Harness> pumpDrive(WidgetTester tester, MtRig rig, {required double w, required double h, double scale = 1, bool connect = true, bool drive = false, bool finished = false}) async {
      AppFlags.driveRedesign = true;
      addTearDown(() => AppFlags.driveRedesign = false);
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final hs = Harness();
      await hs.state.init();
      if (connect) await hs.state.connect(hs.bt.devices.first, RadioKind.bluetooth);
      if (drive || finished) await hs.state.startDrive();
      if (finished) await hs.state.stopDrive();
      await tester.pumpWidget(MeshTrackScope(
        binding: rig.binding,
        child: AppScope(
          state: hs.state,
          child: MaterialApp(
            theme: meshSonarTheme(Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(size: Size(w, h), padding: const EdgeInsets.only(top: 47, bottom: 106), viewPadding: const EdgeInsets.only(top: 47, bottom: 34), textScaler: TextScaler.linear(scale)),
              child: const DriveScreen(),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      return hs;
    }

    Future<void> end(WidgetTester tester, Harness hs, MtRig rig) async {
      if (hs.state.driving) await hs.state.stopDrive();
      await tester.pump(const Duration(seconds: 25));
      await rig.done(tester);
    }

    for (final (name, w, h) in [('iPhone SE', 375.0, 667.0), ('iPhone 17 Pro', 402.0, 874.0)]) {
      for (final scale in [1.0, 2.0]) {
        for (final mode in ['ready', 'driving', 'saved', 'no radio']) {
          testWidgets('$name, ${scale}x text, $mode: Dock button fits, Medium row shows, no overflow', (tester) async {
            final rig = MtRig();
            rig.svc.setRadioConnected(mode != 'no radio');
            if (mode == 'driving') {
              rig.svc
                ..addGroup(1, 'Family')
                ..driveStarted();
              rig.ops.introSeen = true;
              rig.fix();
              rig.svc.setShare(1, true);
            }
            final hs = await pumpDrive(tester, rig, w: w, h: h, scale: scale, connect: mode != 'no radio', drive: mode == 'driving', finished: mode == 'saved');
            expect(tester.takeException(), isNull, reason: 'the Dock lays out');
            expect(find.byKey(const Key('mt-dock-hit')), findsOneWidget, reason: 'MeshTrack is one tap from the Dock');
            expect(find.byKey(const Key('start-stop')), findsWidgets);
            final dock = tester.getRect(find.byKey(const Key('mt-dock-hit')));
            final start = tester.getRect(find.byKey(const Key('start-stop')).first);
            expect(dock.right, lessThanOrEqualTo(w), reason: 'on screen');
            expect(dock.overlaps(start), isFalse, reason: 'never over the main button');
            if (mode == 'driving') {
              expect(find.byKey(const Key('mt-dock-dot')), findsOneWidget, reason: 'sharing shows on the Dock');
              expect(find.byKey(const Key('ping-now')), findsOneWidget);
              expect(dock.overlaps(tester.getRect(find.byKey(const Key('ping-now')))), isFalse);
              expect(tester.getSize(find.byType(DockHero)).width, greaterThanOrEqualTo(scale > 1 ? 120 : 80), reason: 'the hero keeps room');
            }
            // Medium: the row is in the panel.
            await tester.tap(find.byKey(const Key('drive-panel-grabber')), warnIfMissed: false);
            await tester.pumpAndSettle(const Duration(milliseconds: 100));
            final row = find.byKey(const Key('mt-panel-row'));
            if (row.evaluate().isEmpty) {
              await tester.dragUntilVisible(row, find.byKey(const Key('drive-panel-medium')), const Offset(0, -80));
            }
            expect(row, findsOneWidget);
            expect(line(tester), switch (mode) {
              'driving' => 'Sharing: Family',
              'no radio' => 'Connect your radio to share',
              _ => 'Share your position with friends',
            });
            expect(tester.takeException(), isNull);
            await end(tester, hs, rig);
          });
        }
      }
    }
  });
}
