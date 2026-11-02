// WP8: every popup reachable from the Drive tab goes through the shared helpers. Stop-drive is an action sheet (keys kept),
// phone-raised prompts queue behind the drive guard, the antenna and ping-settings sheets open full height at AX3 and
// never ellipsise their helper text, and the drive report opens as a page sheet with Done on Apple platforms.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/ui/antenna_sheet.dart';
import 'package:meshsonar/ui/design/drive_guard.dart';
import 'package:meshsonar/ui/drive/drive_controls.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';

import 'design/design_test_support.dart';
import 'drive_flow_test.dart' show settle;
import 'fakes.dart';

/// Paragraphs under [root] that were cut off (ellipsis or max-lines clip).
List<String> clippedText(WidgetTester tester, Finder root) {
  final out = <String>[];
  for (final e in find.descendant(of: root, matching: find.byType(RichText)).evaluate()) {
    final r = e.renderObject;
    if (r is RenderParagraph && r.didExceedMaxLines) out.add(r.text.toPlainText());
  }
  return out;
}

void main() {
  setUp(resetDesignGlobals);

  group('stop drive action sheet', () {
    Future<bool?> open(WidgetTester tester, void Function(bool) got) async {
      await tester.pumpWidget(designApp(home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () async => got(await confirmStopDrive(c)),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      return null;
    }

    testWidgets('iOS: a Cupertino action sheet, red Stop drive, Keep driving separate and last; no AlertDialog', (tester) async {
      bool? got;
      await open(tester, (v) => got = v);
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const Key('stop-drive-dialog')), findsOneWidget);
      expect(tester.widget<CupertinoActionSheetAction>(find.byKey(const Key('stop-drive-confirm'))).isDestructiveAction, isTrue);
      expect(tester.getTopLeft(find.byKey(const Key('stop-drive-keep'))).dy,
          greaterThan(tester.getTopLeft(find.byKey(const Key('stop-drive-confirm'))).dy));
      await tester.tap(find.byKey(const Key('stop-drive-keep')));
      await tester.pumpAndSettle();
      expect(got, isFalse, reason: 'cancel does nothing');
    });

    testWidgets('confirm returns true', (tester) async {
      bool? got;
      await open(tester, (v) => got = v);
      await tester.tap(find.byKey(const Key('stop-drive-confirm')));
      await tester.pumpAndSettle();
      expect(got, isTrue);
    });

    testWidgets('Android: a bottom sheet with the same keys', (tester) async {
      bool? got;
      await tester.pumpWidget(designApp(
        platform: TargetPlatform.android,
        home: (c) => TextButton(key: const Key('open'), onPressed: () async => got = await confirmStopDrive(c), child: const Text('open')),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const Key('stop-drive-confirm')));
      await tester.pumpAndSettle();
      expect(got, isTrue);
    });
  });

  group('drive guard', () {
    testWidgets('the antenna auto prompt queues while driving, then shows when the drive ends', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final ctx = tester.element(find.byType(Scaffold).first);
      DriveGuard.instance.setDriving(true);
      unawaited(showAntennaSheet(ctx, userInitiated: false));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('antenna-sheet')), findsNothing);
      expect(DriveGuard.instance.queued, 1);
      DriveGuard.instance.setDriving(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('antenna-sheet')), findsOneWidget);
    });

    testWidgets('a tap-opened antenna sheet is never held', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final ctx = tester.element(find.byType(Scaffold).first);
      DriveGuard.instance.setDriving(true);
      unawaited(showAntennaSheet(ctx));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('antenna-sheet')), findsOneWidget);
    });
  });

  group('AX3 form sheets', () {
    void ax3(WidgetTester tester) {
      tester.platformDispatcher.textScaleFactorTestValue = 2.35;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    Future<void> expectFullHeightScrollsNoClip(WidgetTester tester, Finder content) async {
      final view = tester.view.physicalSize / tester.view.devicePixelRatio;
      final sheet = find.byKey(const Key('app-sheet'));
      expect(sheet, findsOneWidget);
      expect(tester.getSize(sheet).height / view.height, greaterThan(0.85), reason: 'opens at the full-height detent');
      final scrollable = find.descendant(of: content, matching: find.byType(Scrollable)).first;
      final pos = tester.state<ScrollableState>(scrollable).position;
      expect(pos.maxScrollExtent, greaterThan(0), reason: 'AX3 content scrolls');
      await tester.drag(scrollable, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(pos.pixels, greaterThan(0));
      expect(clippedText(tester, content), isEmpty, reason: 'no ellipsised helper text');
    }

    testWidgets('antenna sheet', (tester) async {
      useTallScreen(tester);
      ax3(tester);
      final h = Harness(antennaProfile: false)..approveKey();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('antenna-sheet')), findsOneWidget);
      await expectFullHeightScrollsNoClip(tester, find.byKey(const Key('antenna-sheet')));
    });

    testWidgets('ping settings sheet', (tester) async {
      useTallScreen(tester);
      ax3(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('ping-settings-chip')));
      await tester.tap(find.byKey(const Key('ping-settings-chip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ping-settings-sheet')), findsOneWidget);
      await expectFullHeightScrollsNoClip(tester, find.byKey(const Key('ping-settings-sheet')));
    });
  });

  testWidgets('openDriveReport on iOS is a page sheet with Done; Done closes it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    useTallScreen(tester);
    final h = Harness();
    h.store.seed(DriveSession(id: 's1', startedAt: DateTime.utc(2026, 10, 16, 18), endedAt: DateTime.utc(2026, 10, 16, 18, 3)), [
      DrivePing(id: 'p1', ts: DateTime.utc(2026, 10, 16, 18), lat: 40.1, lon: -82.9),
    ]);
    await h.pumpApp(tester);
    final ctx = tester.element(find.byType(Scaffold).first);
    try {
      unawaited(openDriveReport(ctx, 's1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-report')), findsOneWidget);
      expect(find.byKey(const Key('report-done')), findsOneWidget);
      await tester.tap(find.byKey(const Key('report-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-report')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
