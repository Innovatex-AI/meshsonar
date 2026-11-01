// The Tools from the app's side: the More list, the AppState-backed host, and one real tool end to end through AppState and the
// simulated radio.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/tools/tool_kit.dart';
import 'package:meshsonar/ui/tools/tools_host.dart';

import '../../support/tools_app_harness.dart';
import '../fakes.dart';

Future<void> openMore(WidgetTester tester) async {
  await tester.tap(find.text('More').last);
  await tester.pumpAndSettle();
}

Future<void> showRow(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) await tester.dragUntilVisible(f, find.byKey(const Key('more-list')), const Offset(0, -150));
  await tester.ensureVisible(f);
  await tester.pump();
}

void main() {
  testWidgets('More has a "Radios and tools" group with every tool, in order', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openMore(tester);
    expect(find.text('Radios and tools'), findsOneWidget);
    final keys = ['trace', 'discover', 'adverts', 'rxLog', 'noiseFloor', 'telemetry', 'radioSetup'];
    // The list is lazy: scroll to each row, and check the order by the row's place in the list's scroll space.
    final list = find.byKey(const Key('more-list'));
    final top = tester.getTopLeft(list).dy;
    final order = <double>[];
    final scrollable = tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first);
    for (final k in keys) {
      await showRow(tester, 'more-$k');
      expect(find.byKey(Key('more-$k')), findsOneWidget, reason: k);
      order.add(scrollable.position.pixels + tester.getTopLeft(find.byKey(Key('more-$k'))).dy - top);
    }
    expect([...order]..sort(), order);
  });

  for (final (item, id, title) in [
    ('trace', 'trace', 'Trace path'),
    ('discover', 'discover', 'Discover nearby'),
    ('adverts', 'adverts', 'Adverts'),
    ('rxLog', 'rx-log', 'Rx log'),
    ('noiseFloor', 'noise', 'Noise floor and health'),
    ('telemetry', 'telemetry', 'Telemetry'),
    ('radioSetup', 'radio-setup', 'Radio setup'),
  ]) {
    testWidgets('$title opens from More; with no radio it says so and offers to connect', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await openMore(tester);
      await showRow(tester, 'more-$item');
      await tester.tap(find.byKey(Key('more-$item')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('tool-$id')), findsOneWidget);
      expect(find.text('Radio not connected'), findsOneWidget);
      expect(find.byKey(const Key('tool-connect')), findsOneWidget);
    });
  }

  testWidgets('a connected radio whose link cannot run tools says so (not a blank screen)', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    final okc = await h.state.connectSimulator();
    await tester.pumpAndSettle();
    expect(okc, isTrue);
    final host = AppStateToolsHost.of(h.state);
    expect(host.linkState, LinkState.connected);
    expect(host.tools, isNull, reason: 'the harness link is a fake, not a MeshCore companion link');
    await tester.pumpWidget(MaterialApp(home: AppScope(state: h.state, child: ToolPage(id: 'x', title: 'X', builder: (c, h, t) => const Text('body')))));
    expect(find.text('This radio connection cannot run the tools'), findsOneWidget);
  });

  testWidgets('through AppState and the simulated radio: the host gives the session\'s Tools, one instance, with the app\'s hooks', (tester) async {
    useTallScreen(tester);
    final h = ToolsAppHarness();
    final ok = await tester.runAsync(() async {
      await h.state.init();
      return h.state.connectSimulator();
    });
    expect(ok, isTrue);
    addTearDown(() async => tester.runAsync(() => h.state.radioSessions.disconnect()));
    final host = AppStateToolsHost.of(h.state);
    expect(identical(host, AppStateToolsHost.of(h.state)), isTrue);
    final tools = host.tools;
    expect(tools, isNotNull);
    expect(identical(host.tools, tools), isTrue, reason: 'screens come and go; the Tools and their results stay');
    expect(host.radioName, 'MeshSonar Sim');
    expect(host.driveRecording, isFalse);
    expect(h.state.radioSession!.pingBusy!(), isFalse, reason: 'wired to AppState.pinging');
    expect(host.regionPreset, isNull, reason: 'no site config in this harness');
    expect(host.scopeNames, isEmpty);
    final cfg = await tester.runAsync(() => tools!.setup.read());
    expect(cfg!.name, 'MeshSonar Sim');
    // a real trace through the app's own session
    final contacts = (await tester.runAsync(() => tools!.radio.contacts()))!;
    expect(contacts.where((c) => c.type == 2), isNotEmpty);
  });
}
