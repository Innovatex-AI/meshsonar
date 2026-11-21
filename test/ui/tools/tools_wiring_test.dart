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
  // Build 71: the radio tools live once in Network > Tools (test/ui/network/tools); More keeps one Radio row whose
  // screen holds the radio's own settings and the tools that need no network (layout: test/ui/network/more_links_test.dart).
  for (final (item, id, title) in [
    ('noiseFloor', 'noise', 'Noise floor and health'),
    ('telemetry', 'telemetry', 'Telemetry'),
    ('radioSetup', 'radio-setup', 'Radio setup'),
  ]) {
    testWidgets('$title opens from More > Radio; with no radio it says so and offers to connect', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await openMore(tester);
      await showRow(tester, 'more-radio');
      await tester.tap(find.byKey(const Key('more-radio')));
      await tester.pumpAndSettle();
      final row = find.byKey(Key('more-$item'));
      await tester.scrollUntilVisible(row, 200, scrollable: find.descendant(of: find.byKey(const Key('more-radio-list')), matching: find.byType(Scrollable)).first);
      await tester.tap(row);
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
