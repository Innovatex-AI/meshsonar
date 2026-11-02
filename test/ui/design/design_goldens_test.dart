// One golden per helper per mode (WP0). Text renders in the test font, so these pin layout and colour, not glyph shapes;
// the real SF Pro look is checked on the simulator (DR0, docs/planning screenshot sheet).
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_symbols.dart';
import 'package:meshsonar/ui/design/app_widgets.dart';

import 'design_test_support.dart';

void main() {
  setUp(() {
    resetDesignGlobals();
    dismissAppToast();
  });

  for (final b in Brightness.values) {
    final m = b.name;
    Future<void> shoot(WidgetTester tester, String name, void Function(BuildContext) open, {Widget? body}) async {
      await setSize(tester, const Size(390, 760));
      await tester.pumpWidget(designApp(brightness: b, home: (c) => Stack(children: [
            body ?? const SizedBox.expand(),
            Center(child: TextButton(key: const Key('open'), onPressed: () => open(c), child: const Text('open'))),
          ])));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-$m.png'));
      dismissAppToast();
    }

    testWidgets('action sheet $m', (tester) => shoot(tester, 'action_sheet', (c) => showAppActionSheet<String>(c, title: 'Export drive', message: 'Choose a format', actions: const [
          AppAction('Share PDF', 'pdf', isDefault: true),
          AppAction('Copy summary', 'copy', checked: true),
          AppAction('Delete drive', 'del', destructive: true),
        ])));

    testWidgets('alert $m', (tester) => shoot(tester, 'alert', (c) => showAppAlert(c, title: 'Discard message?', message: 'Your draft will be lost.', confirmLabel: 'Discard', destructive: true)));

    testWidgets('sheet $m', (tester) => shoot(tester, 'sheet', (c) => showAppSheet<void>(c, builder: (ctx, sc) => AppSheetScaffold(
          controller: sc,
          title: 'Layers',
          primaryAction: CupertinoButton.filled(onPressed: () {}, child: const Text('Done')),
          children: const [
            AppSwitchTile(symbol: AppSymbols.layers, title: 'Coverage', subtitle: 'Hex cells', value: true, onChanged: _noop),
            AppSwitchTile(symbol: AppSymbols.antenna, title: 'Repeaters', value: false, onChanged: _noop),
          ],
        ))));

    testWidgets('toast $m', (tester) => shoot(tester, 'toast', (c) => showAppToast(c, 'Drive saved on this phone', kind: AppToastKind.success, actionLabel: 'Undo', onAction: () {})));

    testWidgets('toast top $m', (tester) async {
      await setSize(tester, const Size(390, 760));
      await tester.pumpWidget(designApp(brightness: b, home: (c) => AppToastHost(anchor: ToastAnchor.top, inset: 44, child: Builder(builder: (c2) => Center(child: TextButton(key: const Key('open'), onPressed: () => showAppToast(c2, 'No signal', kind: AppToastKind.error), child: const Text('open')))))));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/toast_top-$m.png'));
      dismissAppToast();
    });

    testWidgets('banner and tip $m', (tester) async {
      await setSize(tester, const Size(390, 300));
      appTipStore = MemoryTipStore();
      await tester.pumpWidget(designApp(brightness: b, home: (c) => const Column(children: [
            ChatStatusBanner(kind: StatusBannerKind.warning, message: 'Radio not connected', actionLabel: 'Connect'),
            ChatStatusBanner(kind: StatusBannerKind.error, message: 'Message failed'),
            TipCard(tipId: 'g', title: 'Tip', message: 'Open the guide for the legend.'),
          ])));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/banner_tip-$m.png'));
    });
  }
}

void _noop(bool _) {}
