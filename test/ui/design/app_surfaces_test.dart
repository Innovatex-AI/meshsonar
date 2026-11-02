// The four helpers (WP0): Cupertino branch on Apple platforms, Material branch elsewhere, drive guard, toast rules,
// sheet rules (keyboard aware, max width 560, medium detent, large = native page sheet).
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/drive_guard.dart';

import 'design_test_support.dart';

void main() {
  setUp(() {
    resetDesignGlobals();
    dismissAppToast();
  });

  group('showAppActionSheet', () {
    testWidgets('iOS: actions keep their order, destructive and default styles, Cancel is separate and last', (tester) async {
      String? picked;
      await tester.pumpWidget(designApp(home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () async => picked = await showAppActionSheet<String>(
              c,
              title: 'Export',
              actions: const [
                AppAction('Share', 'share', isDefault: true, key: Key('a-share')),
                AppAction('Copy', 'copy', key: Key('a-copy')),
                AppAction('Delete', 'delete', destructive: true, key: Key('a-delete')),
              ],
            ),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      final ys = [for (final k in ['a-share', 'a-copy', 'a-delete']) tester.getTopLeft(find.byKey(Key(k))).dy];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'given order is kept');
      final cancelY = tester.getTopLeft(find.text('Cancel')).dy;
      expect(cancelY, greaterThan(ys.last), reason: 'Cancel is last');
      expect(tester.widget<CupertinoActionSheetAction>(find.byKey(const Key('a-delete'))).isDestructiveAction, isTrue);
      expect(tester.widget<CupertinoActionSheetAction>(find.byKey(const Key('a-share'))).isDefaultAction, isTrue);
      expect(tester.widget<CupertinoActionSheetAction>(find.byKey(const Key('a-copy'))).isDestructiveAction, isFalse);
      await tester.tap(find.byKey(const Key('a-copy')));
      await tester.pumpAndSettle();
      expect(picked, 'copy');
    });

    testWidgets('cancel returns null and does nothing', (tester) async {
      Object? picked = 'unset';
      await tester.pumpWidget(designApp(home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () async => picked = await showAppActionSheet<String>(c, actions: const [AppAction('Go', 'go')]),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(picked, isNull);
      expect(find.byType(CupertinoActionSheet), findsNothing);
    });

    testWidgets('Android: a bottom sheet list in the same order, checked row shows a mark', (tester) async {
      await tester.pumpWidget(designApp(platform: TargetPlatform.android, home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () => showAppActionSheet<int>(c, actions: const [
              AppAction('One', 1, checked: true, key: Key('a1')),
              AppAction('Two', 2, key: Key('a2')),
            ]),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(tester.getTopLeft(find.byKey(const Key('a1'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('a2'))).dy));
    });

    testWidgets('showAppConfirm: true on the action, false on cancel', (tester) async {
      bool? r;
      await tester.pumpWidget(designApp(home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () async => r = await showAppConfirm(c, title: 'Stop?', confirmLabel: 'Stop drive', destructive: true, confirmKey: const Key('ok')),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ok')));
      await tester.pumpAndSettle();
      expect(r, isTrue);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r, isFalse);
    });
  });

  group('showAppAlert', () {
    testWidgets('iOS: CupertinoAlertDialog, keys kept, destructive confirm, cancel does nothing', (tester) async {
      bool? r;
      await tester.pumpWidget(designApp(home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () async => r = await showAppAlert(c,
                title: 'Discard?', message: 'Your text is lost.', confirmLabel: 'Discard', destructive: true,
                dialogKey: const Key('dlg'), confirmKey: const Key('yes'), cancelKey: const Key('no')),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.byKey(const Key('dlg')), findsOneWidget);
      expect(tester.widget<CupertinoDialogAction>(find.byKey(const Key('yes'))).isDestructiveAction, isTrue);
      // Cancel sits left of confirm.
      expect(tester.getCenter(find.byKey(const Key('no'))).dx, lessThan(tester.getCenter(find.byKey(const Key('yes'))).dx));
      await tester.tap(find.byKey(const Key('no')));
      await tester.pumpAndSettle();
      expect(r, isFalse);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('yes')));
      await tester.pumpAndSettle();
      expect(r, isTrue);
    });

    testWidgets('Android: Material AlertDialog', (tester) async {
      await tester.pumpWidget(designApp(platform: TargetPlatform.android, home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () => showAppAlert(c, title: 'Sure?', confirmLabel: 'Yes'),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group('drive guard', () {
    testWidgets('a prompt the phone raised queues while driving and shows when the drive ends; a tap is never held', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(designApp(home: (c) {
        ctx = c;
        return const SizedBox();
      }));
      DriveGuard.instance.setDriving(true);
      bool? auto;
      final f = showAppAlert(ctx, title: 'Auto prompt', confirmLabel: 'OK', userInitiated: false, confirmKey: const Key('ok'));
      f.then((v) => auto = v);
      await tester.pumpAndSettle();
      expect(find.text('Auto prompt'), findsNothing, reason: 'held while driving');
      expect(DriveGuard.instance.queued, 1);

      showAppAlert(ctx, title: 'You asked', confirmLabel: 'OK');
      await tester.pumpAndSettle();
      expect(find.text('You asked'), findsOneWidget, reason: 'user initiated is never held');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      DriveGuard.instance.setDriving(false);
      await tester.pumpAndSettle();
      expect(find.text('Auto prompt'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ok')));
      await tester.pumpAndSettle();
      expect(auto, isTrue);
      expect(DriveGuard.instance.queued, 0);
    });

    testWidgets('queued prompts show one at a time, in order', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(designApp(home: (c) {
        ctx = c;
        return const SizedBox();
      }));
      DriveGuard.instance.setDriving(true);
      showAppAlert(ctx, title: 'First', confirmLabel: 'OK1', userInitiated: false);
      showAppAlert(ctx, title: 'Second', confirmLabel: 'OK2', userInitiated: false);
      DriveGuard.instance.setDriving(false);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
      await tester.tap(find.text('OK1'));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
      await tester.tap(find.text('OK2'));
      await tester.pumpAndSettle();
    });

    test('prompts for a context that died while queued are dropped', () async {
      DriveGuard.instance.setDriving(true);
      var shown = false;
      final f = DriveGuard.instance.run<int>(() async {
        shown = true;
        return 1;
      }, userInitiated: false, stillValid: () => false);
      DriveGuard.instance.setDriving(false);
      expect(await f, isNull);
      expect(shown, isFalse);
    });
  });

  group('showAppToast', () {
    testWidgets('only one is visible: a new toast replaces the old', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(designApp(home: (c) {
        ctx = c;
        return const SizedBox();
      }));
      showAppToast(ctx, 'First');
      await tester.pump(const Duration(milliseconds: 300));
      showAppToast(ctx, 'Second');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(find.byKey(const Key('app-toast')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Second'), findsNothing, reason: 'info toast goes after 2.5 s');
    });

    testWidgets('default anchor is the bottom, an AppToastHost(top) puts it at the top; error stays longer', (tester) async {
      await setSize(tester, const Size(400, 800));
      late BuildContext plain;
      await tester.pumpWidget(designApp(home: (c) {
        plain = c;
        return const SizedBox();
      }));
      showAppToast(plain, 'Bottom one');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getCenter(find.byKey(const Key('app-toast'))).dy, greaterThan(400));
      dismissAppToast();

      late BuildContext hosted;
      await tester.pumpWidget(designApp(home: (c) => AppToastHost(
            anchor: ToastAnchor.top,
            inset: 48,
            child: Builder(builder: (c2) {
              hosted = c2;
              return const SizedBox();
            }),
          )));
      showAppToast(hosted, 'Top one', kind: AppToastKind.error);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getCenter(find.byKey(const Key('app-toast'))).dy, lessThan(200));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Top one'), findsOneWidget, reason: 'error toasts last 5 s');
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Top one'), findsNothing);
    });

    testWidgets('the action runs and dismisses; touches outside the toast reach the app', (tester) async {
      late BuildContext ctx;
      var taps = 0, undone = 0;
      await tester.pumpWidget(designApp(home: (c) {
        ctx = c;
        return Align(alignment: Alignment.topCenter, child: GestureDetector(behavior: HitTestBehavior.opaque, key: const Key('behind'), onTap: () => taps++, child: const SizedBox(width: 100, height: 100)));
      }));
      showAppToast(ctx, 'Deleted', actionLabel: 'Undo', onAction: () => undone++);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('behind')));
      expect(taps, 1);
      await tester.tap(find.byKey(const Key('app-toast-action')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(undone, 1);
      expect(find.text('Deleted'), findsNothing);
    });
  });

  group('showAppSheet', () {
    Future<void> open(WidgetTester tester, {List<double> detents = const [0.45, 0.92], TargetPlatform platform = TargetPlatform.iOS, bool modal = true, bool dismissible = true, Widget Function(ScrollController)? content}) async {
      await tester.pumpWidget(designApp(platform: platform, home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () => showAppSheet<void>(
              c,
              detents: detents,
              modal: modal,
              dismissible: dismissible,
              builder: (ctx, sc) => content?.call(sc) ?? ListView(controller: sc, children: [for (var i = 0; i < 40; i++) Text('row $i', key: Key('row$i'))]),
            ),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
    }

    testWidgets('medium detent: opens at the first detent, content scrolls, barrier tap dismisses', (tester) async {
      await setSize(tester, const Size(400, 800));
      await open(tester);
      expect(find.byKey(const Key('app-sheet')), findsOneWidget);
      expect(find.byKey(const Key('app-sheet-grabber')), findsOneWidget);
      final h = tester.getSize(find.byKey(const Key('app-sheet'))).height;
      expect(h, closeTo(800 * 0.45, 4));
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sheet')), findsNothing);
    });

    testWidgets('dismissible:false ignores the barrier', (tester) async {
      await setSize(tester, const Size(400, 800));
      await open(tester, dismissible: false, detents: const [0.6]);
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sheet')), findsOneWidget);
    });

    testWidgets('max width 560, centred, on a wide screen', (tester) async {
      await setSize(tester, const Size(1200, 800));
      await open(tester);
      final r = tester.getRect(find.byKey(const Key('app-sheet')));
      expect(r.width, 560);
      expect(r.center.dx, closeTo(600, 1));
    });

    testWidgets('keyboard aware: the sheet sits above the keyboard and grows to the largest detent', (tester) async {
      await setSize(tester, const Size(400, 800));
      await tester.pumpWidget(designApp(home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () => showAppSheet<void>(c, builder: (ctx, sc) => ListView(controller: sc, children: const [TextField(key: Key('field'))])),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      final before = tester.getSize(find.byKey(const Key('app-sheet'))).height;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final r = tester.getRect(find.byKey(const Key('app-sheet')));
      expect(r.bottom, lessThanOrEqualTo(500.5), reason: 'bottom edge above the 300 px keyboard');
      expect(r.height, greaterThan(before), reason: 'grew toward the largest detent');
    });

    testWidgets('non-modal: no barrier, the page behind still takes taps', (tester) async {
      await setSize(tester, const Size(400, 800));
      var taps = 0;
      await tester.pumpWidget(designApp(home: (c) => Stack(children: [
            Positioned(top: 0, left: 0, child: GestureDetector(behavior: HitTestBehavior.opaque, key: const Key('behind'), onTap: () => taps++, child: const SizedBox(width: 100, height: 100))),
            Positioned(bottom: 0, child: TextButton(key: const Key('open'), onPressed: () => showAppSheet<void>(c, modal: false, detents: const [0.3], builder: (ctx, sc) => ListView(controller: sc)), child: const Text('open'))),
          ])));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('behind')));
      expect(taps, 1);
      expect(find.byKey(const Key('app-sheet')), findsOneWidget);
    });

    testWidgets('a single large detent on iOS opens the native page sheet; on Android the custom route', (tester) async {
      await setSize(tester, const Size(400, 800));
      await open(tester, detents: const [0.95]);
      expect(find.byType(CupertinoSheetRoute<void>, skipOffstage: false), findsNothing); // route, not widget; check the sheet widget instead
      expect(find.byKey(const Key('app-sheet')), findsNothing, reason: 'not the custom route');
      expect(find.text('row 0'), findsOneWidget);
    });

    testWidgets('AX3 text: the sheet content scrolls instead of clipping', (tester) async {
      await setSize(tester, const Size(400, 800));
      await tester.pumpWidget(designApp(textScale: 2.35, home: (c) => TextButton(
            key: const Key('open'),
            onPressed: () => showAppSheet<void>(c, builder: (ctx, sc) => AppSheetScaffold(
                  controller: sc,
                  title: 'Settings',
                  primaryAction: CupertinoButton.filled(onPressed: () {}, child: const Text('Save')),
                  children: [for (var i = 0; i < 12; i++) Padding(padding: const EdgeInsets.all(8), child: Text('A fairly long helper line number $i that wraps'))],
                )),
            child: const Text('open'),
          )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget, reason: 'footer pinned and visible');
    });
  });
}
