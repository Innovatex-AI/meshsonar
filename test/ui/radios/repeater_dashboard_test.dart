// The repeater dashboard (chat plan 4.10, WP10): role matrix, firmware gating, glance grid + history, pull to refresh through the
// queue, auto refresh off by default, drop-when-busy, the request strip, session end, AX layouts. Runs against the fake repeater.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/chat/db/stats_history_repository.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/command_queue.dart' show CommandPriority;
import 'package:meshsonar/radio/has_connection.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/repeater_admin.dart';
import 'package:meshsonar/radio/claim_radio.dart' show RemoteLogin;
import 'package:meshsonar/radio/repeater_wire.dart';
import 'package:meshsonar/ui/radios/repeater_admin/admin_controller.dart';
import 'package:meshsonar/ui/radios/repeater_admin/repeater_dashboard_screen.dart';

import '../../support/repeater_admin_fake.dart';
import 'admin_rig.dart';
import '../../support/semantics_audit.dart';

class Dash {
  final AdminRig rig;
  final RemoteStatsHistoryRepository history;
  Dash(this.rig, this.history);
  RepeaterAdminController get c => rig.controller;
}

/// Logs in directly (the login sheet has its own tests), then shows the dashboard.
Future<Dash> openDash(WidgetTester tester,
    {String password = 'secret',
    double w = 390,
    double h = 2400,
    double textScale = 1.0,
    bool dark = false,
    int? level,
    bool gate = true,
    bool owns = false,
    void Function(FakeAdminRepeater)? setup}) async {
  AppFlags.chatRedesign = true;
  addTearDown(() => AppFlags.chatRedesign = false);
  sizeScreen(tester, w: w, h: h);
  final store = ChatStore.inMemory();
  addTearDown(store.close);
  final rig = (await tester.runAsync(() => makeRig(setup: setup, history: store.statsHistory, gateByFirmware: gate)))!;
  addTearDown(() async => tester.runAsync(() => rig.link.close()));
  await tester.runAsync(() async {
    await rig.controller.login(password);
    while (rig.controller.loadingOverview) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  if (level != null) rig.controller.session.adoptLogin(RemoteLogin(isAdmin: rig.controller.session.isAdmin, firmwareLevel: level));
  await tester.pumpWidget(app(RepeaterDashboardScreen(controller: rig.controller, keyHex: rig.rep.keyHex, ownsController: owns, routeLine: 'Via 3'), dark: dark, textScale: textScale));
  await settle(tester);
  await tester.pump(const Duration(milliseconds: 100));
  return Dash(rig, store.statsHistory);
}

void main() {
  group('role matrix', () {
    adminTest('admin sees the glance grid, status rows and every drill-in row', (tester) async {
      final d = await openDash(tester);
      expect(find.byKey(const Key('glance-battery')), findsOneWidget);
      expect(find.byKey(const Key('glance-uptime')), findsOneWidget);
      expect(find.byKey(const Key('glance-noise')), findsOneWidget);
      expect(find.byKey(const Key('glance-airtime')), findsOneWidget);
      expect(find.text('3.86'), findsOneWidget);
      expect(find.text('1'), findsWidgets); // uptime 1 d
      expect(find.text('-108'), findsOneWidget);
      expect(find.text('Signed in as Admin · Via 3 · fw 1.17.1.5 (Build: 4 Oct 2026)'), findsOneWidget);
      for (final k in ['neighbours', 'telemetry', 'settings', 'access', 'console', 'regions', 'health']) {
        expect(find.byKey(Key('row-$k')), findsOneWidget, reason: k);
      }
      expect(find.textContaining('Admin features need'), findsNothing);
      expect(find.byKey(const Key('airtime-chip')), findsNothing, reason: 'jargon removed from the primary UI');
      expect(find.textContaining('slot'), findsNothing);
      expect(d.c.isAdmin, isTrue);
    });

    adminTest('a guest has no admin rows and gets the footer sentence', (tester) async {
      await openDash(tester, password: 'guest');
      expect(find.byKey(const Key('glance-battery')), findsOneWidget);
      expect(find.byKey(const Key('row-neighbours')), findsOneWidget);
      expect(find.byKey(const Key('row-telemetry')), findsOneWidget);
      for (final k in ['settings', 'access', 'console']) {
        expect(find.byKey(Key('row-$k')), findsNothing, reason: k);
      }
      expect(find.text('Signed in as Guest. Admin features need the admin password.'), findsOneWidget);
      expect(find.textContaining('Signed in as Guest'), findsWidgets);
      expect(find.byKey(const Key('factory-nag')), findsNothing);
    });
  });

  group('firmware gating', () {
    adminTest('Neighbours hide below remote level 2 and show from 2', (tester) async {
      await openDash(tester, level: 1);
      expect(find.byKey(const Key('row-neighbours')), findsNothing);
    });

    adminTest('Neighbours show at level 2', (tester) async {
      await openDash(tester, level: 2);
      expect(find.byKey(const Key('row-neighbours')), findsOneWidget);
    });

    adminTest('settings rows newer than the repeater firmware are hidden', (tester) async {
      final d = await openDash(tester, setup: (r) => r.firmware = 'v1.11.0 (Build: 1 Jan 2026)');
      final keys = d.c.visibleSettings.map((s) => s.key).toSet();
      expect(keys, isNot(contains('dutycycle')));
      expect(keys, isNot(contains('path.hash.mode')));
      expect(keys, isNot(contains('loop.detect')));
      expect(keys, isNot(contains('owner.info')));
      expect(keys, contains('name'));
      expect(d.c.hasRegions, isTrue, reason: '1.11 has regions (1.10)');
    });

    adminTest('a new repeater keeps every row; an unknown firmware hides nothing', (tester) async {
      final d = await openDash(tester);
      expect(d.c.visibleSettings.map((s) => s.key), containsAll(['dutycycle', 'path.hash.mode', 'loop.detect', 'owner.info']));
      final old = await openDash(tester, setup: (r) => r.firmware = 'v1.9.0');
      expect(old.c.hasRegions, isFalse);
    });
  });

  group('history and sparklines', () {
    adminTest('each successful status read writes a remote_stats_history row and the cards read them back', (tester) async {
      final d = await openDash(tester);
      expect(d.history.count(d.c.session.keyHex), 1, reason: 'the login read');
      expect(d.c.statusAt, isNotNull);
      await tester.runAsync(() => d.c.refreshStatus());
      await tester.pump();
      expect(d.history.count(d.c.session.keyHex), 2);
      final p = d.history.recent(d.c.session.keyHex, nowMs: DateTime.now().millisecondsSinceEpoch).last;
      expect(p.batteryMv, 3860);
      expect(p.noiseFloor, -108);
      expect(p.uptimeS, 149365);
      expect(p.txAirS, 173);
      expect(d.c.history.length, 2);
    });

    adminTest('tapping a glance card opens the full chart page with lowest / highest', (tester) async {
      final d = await openDash(tester);
      await tester.runAsync(() => d.c.refreshStatus());
      await tester.pump();
      await tester.tap(find.byKey(const Key('glance-battery')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('chart-battery')), findsOneWidget);
      expect(find.byKey(const Key('chart-latest')), findsOneWidget);
      expect(find.text('3.86 V'), findsWidgets);
      expect(find.byKey(const Key('chart-empty')), findsNothing);
    });

    adminTest('with a single reading the chart page says a line needs one more', (tester) async {
      final d = await openDash(tester);
      await tester.tap(find.byKey(const Key('glance-noise')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('chart-empty')), findsOneWidget);
      expect(d.c.history.length, 1);
    });
  });

  group('status rows and truncated blocks', () {
    adminTest('STATUS rows come from the 56-byte struct', (tester) async {
      await openDash(tester);
      expect(find.text('Airtime TX / RX'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('v-airtime'))).data, '0.1% / 0.2%');
      expect(tester.widget<Text>(find.byKey(const Key('v-packets'))).data, 'recv 1,165  sent 604');
      expect(tester.widget<Text>(find.byKey(const Key('v-signal'))).data, '-103 / -3.0');
      expect(tester.widget<Text>(find.byKey(const Key('v-queue'))).data, '0 · 8');
    });

    test('a truncated status block decodes what is there and flags the rest as missing', () {
      final full = const RepeaterStats(battMilliVolts: 3900, txQueueLen: 1, noiseFloorDbm: -100, lastRssiDbm: -90, packetsRecv: 5, packetsSent: 6, airTimeSecs: 10, upTimeSecs: 1000, rxAirTimeSecs: 50, errEvents: 3).encode();
      for (final len in [24, 40, 42, 44, 48, 52, 56]) {
        final p = RepeaterStats.parse(Uint8List.sublistView(full, 0, len))!;
        expect(p.bytes, len);
        expect(p.battMilliVolts, 3900);
        expect(p.upTimeSecs, 1000);
        expect(p.hasErrEvents, len >= 42);
        expect(p.hasSnr, len >= 44);
        expect(p.hasRxAir, len >= 52);
        if (len < 52) expect(p.rxAirTimeSecs, 0);
      }
      expect(RepeaterStats.parse(Uint8List(23)), isNull);
    });

    test('a short block carries n/a flags for the fields it lacks', () {
      // the fake always answers 56 bytes; the short block's flags are what the rows read
      final short = RepeaterStats.parse(Uint8List.sublistView(const RepeaterStats(battMilliVolts: 3800, txQueueLen: 0, noiseFloorDbm: -99, lastRssiDbm: -90, packetsRecv: 1, packetsSent: 1, airTimeSecs: 1, upTimeSecs: 100).encode(), 0, 40))!;
      expect(short.hasRxAir, isFalse);
      expect(short.hasSnr, isFalse);
    });
  });

  group('refresh', () {
    adminTest('Updated N s ago and pull to refresh really asks again', (tester) async {
      final d = await openDash(tester);
      expect(find.textContaining('Updated 0 s ago'), findsOneWidget);
      expect(find.textContaining('pull to refresh'), findsOneWidget);
      final before = d.history.count(d.c.session.keyHex);
      await tester.drag(find.byKey(const Key('dashboard-scroll')), const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await pumpUntil(tester, () => d.history.count(d.c.session.keyHex) > before, rounds: 200);
      await tester.pump(const Duration(seconds: 1));
      expect(d.history.count(d.c.session.keyHex), greaterThan(before), reason: 'a new status request went through the queue');
    });

    adminTest('a refresh while the radio is busy waits its turn (user taps are queued)', (tester) async {
      final d = await openDash(tester);
      final before = d.history.count(d.c.session.keyHex);
      await tester.runAsync(() async {
        final gate = Completer<void>();
        final job = d.c.session.queue.enqueue<void>(kind: RemoteKind.neighbours, target: d.c.session.keyHex, run: (_) => gate.future);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final pending = d.c.refreshStatus();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(d.history.count(d.c.session.keyHex), before, reason: 'queued behind the running request');
        gate.complete();
        await job.result;
        await pending;
      });
      expect(d.history.count(d.c.session.keyHex), before + 1);
    });

    adminTest('auto refresh is off by default and a tick does nothing while the queue is busy', (tester) async {
      final d = await openDash(tester);
      expect(d.c.autoRefresh, isFalse);
      final before = d.history.count(d.c.session.keyHex);
      await tester.runAsync(() async {
        final gate = Completer<void>();
        final job = d.c.session.queue.enqueue<void>(kind: RemoteKind.neighbours, target: d.c.session.keyHex, run: (_) => gate.future);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await d.c.autoTick();
        expect(d.history.count(d.c.session.keyHex), before, reason: 'dropped, not queued');
        expect(d.c.session.queue.waiting, 0, reason: 'nothing queued behind the running request');
        expect(d.c.notices['overview'], isNull, reason: 'a dropped auto refresh is silent');
        gate.complete();
        await job.result;
        await d.c.autoTick();
      });
      expect(d.history.count(d.c.session.keyHex), before + 1, reason: 'idle queue: the tick reads');
    });

    adminTest('the background read is dropped by the queue itself when it is busy', (tester) async {
      final d = await openDash(tester);
      await tester.runAsync(() async {
        final gate = Completer<void>();
        final job = d.c.session.queue.enqueue<void>(kind: RemoteKind.cli, target: d.c.session.keyHex, run: (_) => gate.future);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await expectLater(d.c.session.readStatus(background: true), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.busy)));
        gate.complete();
        await job.result;
      });
      expect(CommandPriority.background, isNot(CommandPriority.admin));
    });

    adminTest('the menu switches auto refresh on (and a foreground gate stops ticks)', (tester) async {
      final d = await openDash(tester);
      await tester.tap(find.byKey(const Key('admin-menu')));
      await frames(tester);
      await tester.tap(find.byKey(const Key('dash-auto')));
      await frames(tester);
      expect(d.c.autoRefresh, isTrue);
      d.c.foreground = false;
      final before = d.history.count(d.c.session.keyHex);
      await tester.runAsync(() => d.c.autoTick());
      expect(d.history.count(d.c.session.keyHex), before, reason: 'not while the app is in the background');
      d.c.setAutoRefresh(false);
      expect(d.c.autoRefresh, isFalse);
    });
  });

  group('menu and session', () {
    adminTest('Reboot repeater confirms in an action sheet with no typed word, then reboots', (tester) async {
      final d = await openDash(tester);
      await tester.tap(find.byKey(const Key('admin-menu')));
      await frames(tester);
      await tester.tap(find.byKey(const Key('dash-reboot')));
      await frames(tester);
      expect(find.byKey(const Key('typed-confirm')), findsNothing);
      expect(find.text('Reboot INNO-OB-2?'), findsOneWidget);
      expect(d.rig.rep.rebootCount, 0);
      await tester.tap(find.byKey(const Key('dash-reboot-confirm')));
      await pumpUntil(tester, () => d.rig.rep.rebootCount > 0);
      expect(d.rig.rep.rebootCount, 1);
    });

    adminTest('a guest has no Reboot in the menu', (tester) async {
      await openDash(tester, password: 'guest');
      await tester.tap(find.byKey(const Key('admin-menu')));
      await frames(tester);
      expect(find.byKey(const Key('dash-reboot')), findsNothing);
      expect(find.byKey(const Key('admin-menu-logout')), findsOneWidget);
    });

    adminTest('Log out ends the session', (tester) async {
      final d = await openDash(tester);
      await tester.tap(find.byKey(const Key('admin-menu')));
      await frames(tester);
      await tester.tap(find.byKey(const Key('admin-menu-logout')));
      await pumpUntil(tester, () => d.c.stage == AdminStage.login);
      expect(d.c.stage, AdminStage.login);
      expect(AdminSessions.of(d.c.session.keyHex), isNull);
    });

    adminTest('leaving logs out unless Stay logged in is on', (tester) async {
      final d = await openDash(tester, owns: true);
      final key = d.c.session.keyHex;
      AdminSessions.set(key, const RemoteLogin(isAdmin: true));
      await tester.pumpWidget(const SizedBox());
      await pumpUntil(tester, () => !d.c.session.loggedIn);
      expect(d.c.session.loggedIn, isFalse);
      expect(AdminSessions.of(key), isNull);
    });

    adminTest('Stay logged in keeps the login for a while after leaving', (tester) async {
      final d = await openDash(tester, owns: true);
      final key = d.c.session.keyHex;
      RepeaterDashboardScreen.stayFor = const Duration(milliseconds: 30);
      addTearDown(() => RepeaterDashboardScreen.stayFor = const Duration(minutes: 10));
      AdminSessions.set(key, const RemoteLogin(isAdmin: true));
      d.c.stayLoggedIn = true;
      await tester.pumpWidget(const SizedBox());
      expect(AdminSessions.of(key), isNotNull, reason: 'kept');
      await tester.pump(const Duration(milliseconds: 100));
      expect(AdminSessions.of(key), isNull, reason: 'after the stay time it is dropped');
    });

    adminTest('the default password card appears for an admin on the factory password and jumps to Settings', (tester) async {
      await openDash(tester, password: 'password', setup: (r) => r.adminPassword = 'password');
      expect(find.byKey(const Key('factory-nag')), findsOneWidget);
      expect(find.text('Change now'), findsOneWidget);
      await tester.tap(find.byKey(const Key('factory-nag-change')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('subpage-settings')), findsOneWidget);
    });
  });

  group('request queue strip and sheet', () {
    adminTest('a waiting request shows the strip; the sheet lists it and can cancel it', (tester) async {
      final d = await openDash(tester);
      expect(find.byKey(const Key('queue-strip')), findsNothing);
      final gate = Completer<void>();
      final run = d.c.session.queue.enqueue<void>(kind: RemoteKind.neighbours, target: d.c.session.keyHex, run: (_) => gate.future);
      final waiting = d.c.session.queue.enqueue<void>(kind: RemoteKind.telemetry, target: d.c.session.keyHex, run: (_) async {});
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('queue-strip')), findsOneWidget);
      expect(find.text('Asking INNO-OB-2 for neighbours… (1 waiting)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('queue-strip')));
      await frames(tester);
      expect(find.text('What the radio is doing'), findsOneWidget);
      expect(find.byKey(Key('activity-${run.id}')), findsOneWidget);
      expect(find.byKey(Key('activity-${waiting.id}')), findsOneWidget);
      await tester.tap(find.byKey(Key('activity-cancel-${waiting.id}')));
      await frames(tester);
      expect(waiting.state, RemoteState.cancelled);
      expect(find.textContaining('Cancelled'), findsWidgets, reason: 'finished requests stay listed');
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(run.state, RemoteState.done);
    });
  });

  group('large text and iPad', () {
    // WP14: AX2 and AX5 at 393 / 375 / 744 / 1024 wide.
    for (final (w, h) in [(393.0, 852.0), (375.0, 667.0), (744.0, 1133.0), (1024.0, 768.0)]) {
      for (final scale in [2.0, 3.1]) {
        adminTest('dashboard at ${w.toInt()} wide, text ${scale}x: no overflow, tap targets, labels', (tester) async {
          final sem = tester.ensureSemantics();
          await openDash(tester, w: w, h: h * 4, textScale: scale);
          expect(tester.takeException(), isNull);
          expectHeader(tester);
          sem.dispose();
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        });
      }
    }

    adminTest('at 2x text the glance grid is one column', (tester) async {
      await openDash(tester, textScale: 2.0, h: 6000);
      expect(find.byKey(const Key('glance-one-column')), findsOneWidget);
      expect(find.byKey(const Key('glance-two-by-two')), findsNothing);
      final a = tester.getTopLeft(find.byKey(const Key('glance-battery'))), b = tester.getTopLeft(find.byKey(const Key('glance-uptime')));
      expect(b.dx, a.dx);
      expect(b.dy, greaterThan(a.dy));
      expect(tester.takeException(), isNull);
    });

    adminTest('at normal text on a phone it is 2 x 2', (tester) async {
      await openDash(tester);
      expect(find.byKey(const Key('glance-two-by-two')), findsOneWidget);
      final a = tester.getTopLeft(find.byKey(const Key('glance-battery'))), b = tester.getTopLeft(find.byKey(const Key('glance-uptime'))), c = tester.getTopLeft(find.byKey(const Key('glance-noise')));
      expect(b.dy, a.dy);
      expect(b.dx, greaterThan(a.dx));
      expect(c.dy, greaterThan(a.dy));
    });

    adminTest('on an iPad the four cards sit in one row', (tester) async {
      await openDash(tester, w: 1024, h: 1200);
      expect(find.byKey(const Key('glance-four-up')), findsOneWidget);
      final ys = [for (final m in ['battery', 'uptime', 'noise', 'airtime']) tester.getTopLeft(find.byKey(Key('glance-$m'))).dy];
      expect(ys.toSet().length, 1);
    });

    adminTest('1.5x text in dark mode lays out without overflow', (tester) async {
      await openDash(tester, textScale: 1.5, dark: true, h: 4000);
      expect(tester.takeException(), isNull);
    });
  });

  group('existing views are reachable', () {
    adminTest('Settings, Access list and Console open the existing views', (tester) async {
      await openDash(tester);
      for (final (row, page) in [('settings', 'subpage-settings'), ('access', 'subpage-access-list'), ('console', 'subpage-console')]) {
        await tester.ensureVisible(find.byKey(Key('row-$row')));
        await tester.tap(find.byKey(Key('row-$row')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(Key(page)), findsOneWidget, reason: row);
        await pumpUntil(tester, () => !_loading(tester), rounds: 400);
        Navigator.of(tester.element(find.byKey(Key(page)))).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
    });

    adminTest('Telemetry shows the battery and chip temperature', (tester) async {
      await openDash(tester);
      await tester.tap(find.byKey(const Key('row-telemetry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('tele-battery')), findsOneWidget);
      expect(find.text('3.86 V'), findsOneWidget);
      expect(find.byKey(const Key('tele-temp')), findsOneWidget);
    });
  });
}

bool _loading(WidgetTester t) => false;
