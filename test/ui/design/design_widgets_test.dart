import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/anchored_sheet.dart';
import 'package:meshsonar/ui/design/app_symbols.dart';
import 'package:meshsonar/ui/design/app_widgets.dart';
import 'package:meshsonar/ui/design/state_views.dart';
import 'package:meshsonar/ui/design/tokens.dart';

import 'design_test_support.dart';

void main() {
  setUp(() => appTipStore = MemoryTipStore());

  group('AppSwitchTile', () {
    testWidgets('iOS: Cupertino switch, whole row toggles, 44 high, semantics toggled', (tester) async {
      var v = false;
      await tester.pumpWidget(designApp(home: (c) => StatefulBuilder(builder: (c, set) => AppSwitchTile(
            key: const Key('tile'),
            symbol: AppSymbols.bell,
            title: 'Notifications',
            subtitle: 'Alerts for new messages',
            value: v,
            onChanged: (n) => set(() => v = n),
          ))));
      expect(find.byType(CupertinoSwitch), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('tile'))).height, greaterThanOrEqualTo(Hit.min));
      await tester.tap(find.text('Notifications'));
      await tester.pump();
      expect(v, isTrue);
      expect(tester.getSemantics(find.byKey(const Key('tile'))), matchesSemantics(label: 'Notifications. Alerts for new messages', hasToggledState: true, isToggled: true, hasEnabledState: true, isEnabled: true, hasTapAction: true));
    });

    testWidgets('Android: Material switch; disabled when onChanged is null', (tester) async {
      await tester.pumpWidget(designApp(platform: TargetPlatform.android, home: (c) => const AppSwitchTile(title: 'X', value: true, onChanged: null)));
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    });
  });

  group('ChatStatusBanner', () {
    testWidgets('min height 44, live region, grows at AX3, action fires', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(designApp(textScale: 2.35, home: (c) => ChatStatusBanner(
            kind: StatusBannerKind.warning,
            message: 'Sending is paused while you drive. Messages wait in the outbox.',
            actionLabel: 'Details',
            onAction: () => tapped++,
          )));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(ChatStatusBanner)).height, greaterThan(Hit.min));
      await tester.tap(find.text('Details'));
      expect(tapped, 1);
    });
  });

  group('TipCard', () {
    testWidgets('shows once: dismiss hides it and it stays hidden', (tester) async {
      var dismissed = 0;
      Widget build() => designApp(home: (c) => TipCard(tipId: 'drive-guide', title: 'Tip', message: 'Open the guide for the legend.', onDismissed: () => dismissed++));
      await tester.pumpWidget(build());
      expect(find.text('Open the guide for the legend.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tip-dismiss')));
      await tester.pump();
      expect(find.text('Open the guide for the legend.'), findsNothing);
      expect(dismissed, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(build());
      expect(find.text('Open the guide for the legend.'), findsNothing, reason: 'remembered');
    });
  });

  group('state views', () {
    testWidgets('empty view with action', (tester) async {
      var n = 0;
      await tester.pumpWidget(designApp(home: (c) => AppEmptyView(symbol: AppSymbols.tray, title: 'No messages', message: 'Say hello.', actionLabel: 'New message', onAction: () => n++)));
      await tester.tap(find.text('New message'));
      expect(n, 1);
    });

    testWidgets('loading gives up after its timeout and offers a retry', (tester) async {
      var n = 0;
      await tester.pumpWidget(designApp(home: (c) => AppLoadingView(label: 'Loading', timeout: const Duration(seconds: 2), onRetry: () => n++)));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.tap(find.text('Try again'));
      expect(n, 1);
    });
  });

  group('Hit.pad', () {
    testWidgets('a 20 px visual gets a 44 px hit area', (tester) async {
      var n = 0;
      await tester.pumpWidget(designApp(home: (c) => Center(child: Hit.pad(onTap: () => n++, child: const SizedBox(key: Key('v'), width: 20, height: 20)))));
      expect(tester.getSize(find.byKey(const Key('v'))), const Size(20, 20));
      await tester.tapAt(tester.getCenter(find.byKey(const Key('v'))) + const Offset(20, 0));
      expect(n, 1);
    });
  });

  group('AnchoredSheetHost', () {
    testWidgets('sits above the dock inset, replaces the previous sheet, drag down closes, map behind stays tappable', (tester) async {
      await setSize(tester, const Size(400, 800));
      final ctl = AnchoredSheetController();
      var mapTaps = 0, closed = 0;
      await tester.pumpWidget(designApp(home: (c) => AnchoredSheetHost(
            controller: ctl,
            bottomInset: 120,
            child: GestureDetector(behavior: HitTestBehavior.opaque, key: const Key('map'), onTap: () => mapTaps++, child: const SizedBox.expand()),
          )));
      ctl.show(id: 'layers', builder: (c) => const SizedBox(height: 200, child: Text('Layers')), onClosed: () => closed++);
      await tester.pump();
      expect(find.text('Layers'), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('anchored-layers'))).bottom, closeTo(800 - 120, 0.5), reason: 'bounded by the dock top');
      await tester.tapAt(const Offset(200, 100));
      expect(mapTaps, 1, reason: 'no barrier');
      ctl.show(id: 'inspector', builder: (c) => const SizedBox(height: 100, child: Text('Inspector')));
      await tester.pump();
      expect(find.text('Layers'), findsNothing);
      expect(find.text('Inspector'), findsOneWidget);
      expect(closed, 1, reason: 'replaced sheet reports closed');
      await tester.drag(find.byKey(const Key('anchored-grabber')), const Offset(0, 200));
      await tester.pump();
      expect(ctl.isOpen, isFalse);
    });
  });
}
