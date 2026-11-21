// MapPanel, MapPanelGroup, MapPanelStore and MapPanelHost (build 71, "One shared panel", rules 1 to 6).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/anchored_sheet.dart';
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/theme.dart';

const _phone = Size(390, 844);

Future<void> _pump(WidgetTester tester, Widget body, {Size size = _phone, EdgeInsets padding = EdgeInsets.zero, double textScale = 1}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(Brightness.dark),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(padding: padding, viewPadding: padding, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: body),
      ),
    ),
  ));
  await tester.pump();
}

Widget _map(List<Widget> panels, {MapPanelGroup? group, VoidCallback? onMapTap}) {
  final stack = Stack(fit: StackFit.expand, children: [
    Positioned.fill(child: GestureDetector(key: const Key('the-map'), behavior: HitTestBehavior.opaque, onTap: onMapTap)),
    for (final p in panels) Positioned.fill(child: p),
  ]);
  return group == null ? stack : MapPanelScope(group: group, child: stack);
}

MapPanel _panel(String id, {bool allowFull = false, VoidCallback? onClose, Widget? action, bool locked = false, ValueChanged<MapPanelState>? onState, double height = 200, bool bottomSafe = true}) =>
    MapPanel(
      id: id,
      title: 'Title $id',
      status: Text('status $id'),
      allowFull: allowFull,
      onClose: onClose,
      action: action,
      locked: locked,
      bottomSafe: bottomSafe,
      onStateChanged: onState,
      child: SizedBox(height: height, child: Text('body $id')),
    );

Finder _header(String id) => find.byKey(Key('map-panel-$id-header'));
Finder _body(String id) => find.byKey(Key('map-panel-$id-body'));
Rect _rect(WidgetTester t, String id) => t.getRect(find.byKey(Key('map-panel-$id')));

void main() {
  setUp(MapPanelStore.clear);

  test('state names are the same words everywhere', () {
    expect(MapPanelState.values.map(mapPanelStateLabel), ['Collapsed', 'Open', 'Full']);
  });

  testWidgets('rule 1, 2, 6: starts collapsed on a phone, bottom-anchored, header only and at least 44 pt', (tester) async {
    await _pump(tester, _map([_panel('a')]));
    expect(_body('a'), findsNothing);
    final r = _rect(tester, 'a');
    expect(r.bottom, 844);
    expect(r.left, 0);
    expect(r.width, 390);
    expect(r.height, kMapPanelHeader);
    expect(tester.getSize(_header('a')).height, greaterThanOrEqualTo(44));
    expect(find.text('Title a'), findsOneWidget);
    expect(find.text('status a'), findsOneWidget);
    expect(find.byType(MapPanelGrabber), findsOneWidget);
    expect(find.byType(MapPanelChevron), findsOneWidget);
  });

  testWidgets('the surface runs behind the tab bar and home indicator, the header stays above them', (tester) async {
    await _pump(tester, _map([_panel('a')]), padding: const EdgeInsets.only(bottom: 83));
    expect(_rect(tester, 'a').bottom, 844);
    expect(tester.getRect(_header('a')).bottom, 844 - 83, reason: 'nothing of the header hides under the tab bar');
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    expect(tester.getRect(_body('a')).bottom, lessThanOrEqualTo(844 - 83));
  });

  testWidgets('rule 3: a tap toggles; a drag up opens, a drag down collapses; Open is at most 60 % of the height', (tester) async {
    await _pump(tester, _map([_panel('a', height: 2000)]));
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    expect(_body('a'), findsOneWidget);
    expect(_rect(tester, 'a').height, lessThanOrEqualTo(844 * 0.6 + 0.5));
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    expect(_body('a'), findsNothing);
    await tester.drag(_header('a'), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(_body('a'), findsOneWidget);
    await tester.drag(_header('a'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(_body('a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Full only for work panels', (tester) async {
    final seen = <MapPanelState>[];
    await _pump(tester, _map([_panel('a', onState: seen.add), _panel('w', allowFull: true, onState: seen.add)].sublist(0, 1)));
    await tester.drag(_header('a'), const Offset(0, -60));
    await tester.pumpAndSettle();
    await tester.drag(_header('a'), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(seen, [MapPanelState.open], reason: 'a plain panel stops at Open');

    seen.clear();
    await _pump(tester, _map([_panel('w', allowFull: true, onState: seen.add, height: 100)]));
    await tester.drag(_header('w'), const Offset(0, -60));
    await tester.pumpAndSettle();
    await tester.drag(_header('w'), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(seen, [MapPanelState.open, MapPanelState.full]);
    expect(_rect(tester, 'w').height, closeTo(844 * kMapPanelFull, 1));
  });

  testWidgets('rule 4: never modal, the map under it takes taps and nothing dims it', (tester) async {
    var taps = 0;
    await _pump(tester, _map([_panel('a')], onMapTap: () => taps++));
    await tester.tapAt(const Offset(195, 200));
    expect(taps, 1);
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 200));
    expect(taps, 2, reason: 'open: the map above the panel still takes the tap');
    expect(find.byType(ModalBarrier), findsOneWidget, reason: 'only the route\'s own barrier; the panel adds none');
    await tester.tapAt(_rect(tester, 'a').center);
    expect(taps, 2, reason: 'a tap on the panel does not fall through to the map');
  });

  testWidgets('rule 5: one open panel per map', (tester) async {
    final group = MapPanelGroup();
    addTearDown(group.dispose);
    await _pump(
      tester,
      _map([
        _panel('a'),
        Padding(padding: const EdgeInsets.only(bottom: kMapPanelHeader), child: _panel('b', bottomSafe: false)),
      ], group: group),
    );
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    expect(group.openId, 'a');
    await tester.tap(_header('b'));
    await tester.pumpAndSettle();
    expect(group.openId, 'b');
    expect(_body('a'), findsNothing, reason: 'opening b collapsed a');
    expect(_body('b'), findsOneWidget);
    expect(MapPanelStore.read('a'), MapPanelState.open, reason: 'a was collapsed by the group, not by the person: its remembered state stays');
    await tester.tap(_header('b'));
    await tester.pumpAndSettle();
    expect(group.openId, isNull);
  });

  testWidgets('rule 6: the open state is remembered per id; a rebuild with new data never moves the panel', (tester) async {
    await _pump(tester, _map([_panel('a')]));
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    expect(MapPanelStore.read('a'), MapPanelState.open);
    // The screen goes away and comes back: the panel is where the person left it.
    await _pump(tester, const SizedBox());
    await _pump(tester, _map([_panel('a'), ]));
    expect(_body('a'), findsOneWidget);
    // Another id is untouched.
    await _pump(tester, _map([_panel('c')]));
    expect(_body('c'), findsNothing);
    // New data (a rebuild with other content) leaves the state alone.
    await _pump(tester, _map([_panel('c', height: 120)]));
    expect(_body('c'), findsNothing);
  });

  test('the Drive panel and the Planner always cold-start collapsed: their state is never saved', () {
    MapPanelStore.write('drive.main', MapPanelState.open);
    MapPanelStore.write('plan.main', MapPanelState.full);
    expect(MapPanelStore.read('drive.main'), isNull);
    expect(MapPanelStore.read('plan.main'), isNull);
  });

  testWidgets('a wide screen shows a floating card that starts open', (tester) async {
    await _pump(tester, _map([_panel('a')]), size: const Size(1024, 768));
    expect(_body('a'), findsOneWidget);
    final r = _rect(tester, 'a');
    expect(r.width, kMapPanelCardWidth);
    expect(r.left, 16);
    expect(r.bottom, 768 - 16);
  });

  testWidgets('header action works while collapsed and does not toggle; locked panels do not open', (tester) async {
    var pressed = 0;
    await _pump(tester, _map([_panel('a', action: IconButton(key: const Key('act'), icon: const Icon(Icons.pause), onPressed: () => pressed++))]));
    await tester.tap(find.byKey(const Key('act')));
    await tester.pumpAndSettle();
    expect(pressed, 1);
    expect(_body('a'), findsNothing);
    expect(tester.getSize(find.byKey(const Key('act'))).height, greaterThanOrEqualTo(44));

    await _pump(tester, _map([_panel('l', locked: true, onClose: () {})]));
    await tester.tap(_header('l'));
    await tester.pumpAndSettle();
    expect(_body('l'), findsNothing);
  });

  testWidgets('large text: the header grows and nothing overflows', (tester) async {
    await _pump(tester, _map([_panel('a', action: IconButton(icon: const Icon(Icons.pause), onPressed: () {}))]), textScale: 2.4, size: const Size(320, 568));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(_header('a')).height, kMapPanelGrabberZone + kMapPanelRowAx);
    await tester.tap(_header('a'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('MapPanelHost (the transient slot)', () {
    testWidgets('one at a time, above the persistent panel, opens without touching its remembered state, X closes', (tester) async {
      final group = MapPanelGroup();
      final host = MapPanelHostController();
      addTearDown(group.dispose);
      addTearDown(host.dispose);
      final closed = <String>[];
      await _pump(
        tester,
        MapPanelScope(
          group: group,
          child: MapPanelHost(
            controller: host,
            bottomInset: kMapPanelHeader,
            child: _map([_panel('main')]),
          ),
        ),
      );
      await tester.tap(_header('main'));
      await tester.pumpAndSettle();
      expect(MapPanelStore.read('main'), MapPanelState.open);

      host.show(id: 't1', onClosed: () => closed.add('t1'), builder: (_) => _panel('t1', onClose: () => host.close('t1'), bottomSafe: false));
      await tester.pumpAndSettle();
      expect(_body('t1'), findsOneWidget, reason: 'a transient panel is shown open');
      expect(_body('main'), findsNothing, reason: 'one open panel per map');
      expect(MapPanelStore.read('main'), MapPanelState.open, reason: 'the persistent panel\'s remembered state is not changed');
      expect(MapPanelStore.read('t1'), isNull, reason: 'transient state is not remembered');
      expect(_rect(tester, 't1').bottom, 844 - kMapPanelHeader, reason: 'directly above the persistent panel\'s header');

      host.show(id: 't2', onClosed: () => closed.add('t2'), builder: (_) => _panel('t2', onClose: () => host.close('t2'), bottomSafe: false));
      await tester.pumpAndSettle();
      expect(closed, ['t1']);
      expect(find.byKey(const Key('map-panel-t1')), findsNothing);
      expect(host.currentId, 't2');

      await tester.tap(find.byKey(const Key('map-panel-t2-close')));
      await tester.pumpAndSettle();
      expect(closed, ['t1', 't2']);
      expect(host.isOpen, isFalse);
      expect(group.openId, isNull);
    });
  });
}
