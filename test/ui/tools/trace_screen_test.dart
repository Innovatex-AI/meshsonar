import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/radio/tools/trace_tool.dart';
import 'package:meshsonar/ui/tools/trace_screen.dart';

import '../../support/tools_rig.dart';
import '../../support/tools_ui_rig.dart';

RadioContact contact(String key, String name, {int type = AdvType.repeater, double? lat, double? lon}) =>
    RadioContact(publicKeyHex: key, type: type, outPath: Uint8List(0), name: name, lat: lat, lon: lon);

String key(String first, int fill) => first + fill.toRadixString(16).padLeft(2, '0') * (32 - first.length ~/ 2);

TraceResult saved(String id, String name, String keyHex, double snr, double fin, {double? lat, double? lon, bool ok = true}) {
  final stop = TraceStop(name: name, keyHex: keyHex, lat: lat, lon: lon);
  return TraceResult(
    id: id,
    at: DateTime(2026, 11, 1, 12, int.parse(id)),
    status: ok ? TraceStatus.ok : TraceStatus.silent,
    hashSize: 2,
    hops: [TraceHopResult(stop: stop, hashHex: keyHex.substring(0, 4), snrDb: snr, distanceKm: lat == null ? null : 1.2)],
    finalSnrDb: fin,
    originLat: 40.1258,
    originLon: -82.9312,
  );
}

/// Tools over a scripted radio with [contacts] and saved traces already in the store.
(RadioTools, FakeToolsRadio) fakeTools({List<RadioContact> contacts = const [], List<TraceResult> store = const []}) {
  final f = FakeToolsRadio()..contactList = contacts;
  return (RadioTools(f, testArbiter(), traceStore: TraceStore(initial: store)), f);
}

/// Scrolls [key] into view and taps it.
Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pump();
  await tester.tap(find.byKey(Key(key)));
}

/// The simulated radio runs on real timers, the screen and the tool's wait on the test clock: let real time pass for the
/// radio, then move the test clock so the screen and the tool see the answer.
Future<void> realThenFake(WidgetTester tester, {int realMs = 800, double fakeSecs = 2}) async {
  await advance(tester, 0.3); // the command leaves the phone on the first pump
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: realMs)));
  await advance(tester, fakeSecs);
}

/// Moves the test clock: work started from a tap (the radio, the tool's wait) runs on fake timers.
Future<void> advance(WidgetTester tester, double seconds) async {
  for (var i = 0; i < (seconds * 10).round(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> openAddHop(WidgetTester tester) async {
  await tapKey(tester, 'trace-add-hop');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no radio: the gate, nothing else', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pumpTool(tester, const TraceScreen(), host);
    expect(find.text('Radio not connected'), findsOneWidget);
    expect(find.byKey(const Key('trace-send')), findsNothing);
  });

  testWidgets('radio with no repeaters: says what to do', (tester) async {
    final (tools, _) = fakeTools(contacts: [contact(key('ab', 1), 'Ann', type: AdvType.chat)]);
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const TraceScreen(), host);
    await settleReal(tester, real: const Duration(milliseconds: 50));
    expect(find.byKey(const Key('trace-no-contacts')), findsOneWidget);
    expect(find.textContaining('Use Discover nearby'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('trace-add-hop'))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.descendant(of: find.byKey(const Key('trace-send')), matching: find.byType(FilledButton))).onPressed, isNull);
    expect(find.byKey(const Key('trace-no-result')), findsOneWidget);
  });

  testWidgets('build a chain on the simulated radio, send it, read hop SNR, distance and map', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const TraceScreen(), host);
    await settleReal(tester);
    expect(find.byKey(const Key('trace-no-hops')), findsOneWidget);
    await openAddHop(tester);
    final r = rig.nearest;
    expect(find.byKey(const Key('trace-picker')), findsOneWidget);
    await tester.tap(find.byKey(Key('trace-pick-${r.keyHex.substring(0, 8)}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trace-hop-0')), findsOneWidget);
    expect(find.text(r.name), findsWidgets);

    await tapKey(tester, 'trace-send');
    await realThenFake(tester);
    final frame = rig.radio.sentFrames.lastWhere((f) => f[0] == ToolCmd.sendTracePath);
    expect(frame[9], 1, reason: 'default is 2-byte hashes');
    expect(frame.sublist(10), r.publicKey.sublist(0, 2));

    expect(find.text('Trace complete'), findsOneWidget);
    expect(find.byKey(const Key('trace-result-hop-0')), findsOneWidget);
    expect(find.textContaining('heard at'), findsWidgets);
    expect(find.byKey(const Key('trace-final')), findsOneWidget);
    expect(find.textContaining('Heard back at'), findsOneWidget);
    expect(find.textContaining('from the previous point'), findsOneWidget, reason: 'distance from the phone to the repeater');
    expect(find.textContaining('Total distance'), findsOneWidget);
    expect(find.byKey(const Key('trace-total')), findsOneWidget);
    expect(find.byKey(const Key('tool-map')), findsOneWidget);
    expect(find.byKey(const Key('airtime-note')), findsOneWidget);
    // right after a run the next trace waits, in words
    expect(find.textContaining('Wait'), findsWidgets);

    final sem = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('^Hop 1, ${r.name}, hash .*Heard it at')), findsOneWidget);
    sem.dispose();

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hop order: move, remove, clear; at most 8 hops', (tester) async {
    final cs = [for (var i = 0; i < 3; i++) contact(key('c$i', i), 'Rep $i')];
    final (tools, _) = fakeTools(contacts: cs);
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const TraceScreen(), host);
    await settleReal(tester, real: const Duration(milliseconds: 50));
    for (final c in cs.take(2)) {
      await openAddHop(tester);
      await tester.tap(find.byKey(Key('trace-pick-${c.publicKeyHex.substring(0, 8)}')));
      await tester.pumpAndSettle();
    }
    expect(find.descendant(of: find.byKey(const Key('trace-hop-0')), matching: find.text('Rep 0')), findsOneWidget);
    await tapKey(tester, 'trace-hop-0-down');
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('trace-hop-0')), matching: find.text('Rep 1')), findsOneWidget);
    await tapKey(tester, 'trace-hop-0-remove');
    await tester.pump();
    expect(find.byKey(const Key('trace-hop-1')), findsNothing);
    for (var i = 0; i < 7; i++) {
      await openAddHop(tester);
      await tester.tap(find.byKey(Key('trace-pick-${cs[0].publicKeyHex.substring(0, 8)}')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('trace-hop-7')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('trace-add-hop'))).onPressed, isNull);
    expect(find.textContaining('Longest path'), findsOneWidget);
    await tapKey(tester, 'trace-clear-hops');
    await tester.pump();
    expect(find.byKey(const Key('trace-hop-0')), findsNothing);
  });

  testWidgets('a 1-byte hash shared by two repeaters is flagged by name; 2 bytes clear it', (tester) async {
    final a = contact(key('df01', 1), 'Hill A');
    final b = contact(key('df02', 2), 'Hill B');
    final (tools, _) = fakeTools(contacts: [a, b]);
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const TraceScreen(), host);
    await settleReal(tester, real: const Duration(milliseconds: 50));
    await openAddHop(tester);
    await tester.tap(find.byKey(Key('trace-pick-${a.publicKeyHex.substring(0, 8)}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trace-ambiguous-0')), findsNothing);
    await tester.tap(find.descendant(of: find.byKey(const Key('trace-hash-size')), matching: find.text('1 byte')));
    await tester.pump();
    expect(find.byKey(const Key('trace-ambiguous-0')), findsOneWidget);
    expect(find.textContaining('shares its 1-byte hash with Hill B'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const Key('trace-hash-size')), matching: find.text('2 bytes')));
    await tester.pump();
    expect(find.byKey(const Key('trace-ambiguous-0')), findsNothing, reason: 'df01 and df02 differ in the second byte');
  });

  testWidgets('a hop that never answers: "No answer" with what to try (the tool waits est timeout + 2 s, at least 4 s)', (tester) async {
    final a = contact(key('aa01', 1), 'Far hill');
    final (tools, fake) = fakeTools(contacts: [a]);
    fake.onSend = (f) => const SentFrame(flood: false, tag: 1, estTimeoutMs: 100);
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const TraceScreen(), host);
    await settleReal(tester, real: const Duration(milliseconds: 50));
    await openAddHop(tester);
    await tester.tap(find.byKey(Key('trace-pick-${a.publicKeyHex.substring(0, 8)}')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'trace-send');
    await advance(tester, 6);
    expect(find.text('No answer'), findsOneWidget);
    expect(find.textContaining('may not exist'), findsOneWidget);
    expect(find.textContaining('Try a shorter path'), findsOneWidget);
    expect(find.byKey(const Key('trace-save')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('radio refuses: a problem note, not silence', (tester) async {
    final a = contact(key('aa01', 1), 'Hill');
    final (tools, fake) = fakeTools(contacts: [a]);
    fake.onSend = (f) => const ErrFrame(ErrCode.illegalArg);
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const TraceScreen(), host);
    await settleReal(tester, real: const Duration(milliseconds: 50));
    await openAddHop(tester);
    await tester.tap(find.byKey(Key('trace-pick-${a.publicKeyHex.substring(0, 8)}')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'trace-send');
    await settleReal(tester, real: const Duration(milliseconds: 100));
    expect(find.text('The radio refused the trace'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('saved traces', () {
    final k = key('df01', 1);
    final second = key('ab02', 2);

    testWidgets('saved list, open one, native network routes screen, delete', (tester) async {
      final (tools, _) = fakeTools(store: [saved('02', 'Hill', k, 2.0, 1.0, lat: 40.13, lon: -82.97), saved('01', 'Hill', k, 4.0, 3.0)]);
      final host = FakeToolsHost()..toolsValue = tools;
      await pumpTool(tester, const TraceScreen(), host);
      await settleReal(tester, real: const Duration(milliseconds: 50));
      expect(find.byKey(const Key('trace-saved-02')), findsOneWidget);
      expect(find.textContaining('Worked'), findsWidgets);
      await tester.ensureVisible(find.byKey(const Key('trace-saved-02-open')));
      await tester.tap(find.byKey(const Key('trace-saved-02-open')));
      await tester.pump();
      expect(find.byKey(const Key('trace-result')), findsOneWidget);
      expect(find.byKey(const Key('tool-map')), findsOneWidget, reason: 'hop with a position and an origin');
      expect(find.byKey(const Key('trace-saved-note')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('trace-network-routes')));
      await tapKey(tester, 'trace-network-routes');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(host.openedUrls, isEmpty, reason: 'native, not a browser hop');
      expect(find.byKey(const Key('routes-list')), findsOneWidget);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.ensureVisible(find.byKey(const Key('trace-saved-02-delete')));
      await tester.tap(find.byKey(const Key('trace-saved-02-delete')));
      await tester.pump();
      expect(find.byKey(const Key('trace-saved-02')), findsNothing);
      expect(tools.trace.store.items.length, 1);
    });

    testWidgets('compare two saved traces: per hop A, B and the change in words', (tester) async {
      final (tools, _) = fakeTools(store: [saved('02', 'Hill', k, 2.0, 1.0), saved('01', 'Hill', k, 4.5, 3.0)]);
      final host = FakeToolsHost()..toolsValue = tools;
      await pumpTool(tester, const TraceScreen(), host);
      await settleReal(tester, real: const Duration(milliseconds: 50));
      expect(tester.widget<FilledButton>(find.byKey(const Key('trace-compare'))).onPressed, isNull);
      for (final id in ['01', '02']) {
        await tester.ensureVisible(find.byKey(Key('trace-saved-$id-tick')));
        await tester.tap(find.byKey(Key('trace-saved-$id-tick')));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const Key('trace-compare')));
      await tapKey(tester, 'trace-compare');
      await tester.pump();
      expect(find.byKey(const Key('trace-comparison')), findsOneWidget);
      expect(find.textContaining('Different chains'), findsNothing);
      // first ticked = 01 (+4.5), second = 02 (+2.0): the second is 2.5 dB worse
      expect(find.textContaining('worse by'), findsWidgets);
      expect(find.byKey(const Key('trace-cmp-final')), findsOneWidget);
    });

    testWidgets('different chains are called out', (tester) async {
      final (tools, _) = fakeTools(store: [saved('02', 'Hill', k, 2.0, 1.0), saved('01', 'Ridge', second, 4.5, 3.0)]);
      final host = FakeToolsHost()..toolsValue = tools;
      await pumpTool(tester, const TraceScreen(), host);
      await settleReal(tester, real: const Duration(milliseconds: 50));
      for (final id in ['01', '02']) {
        await tester.ensureVisible(find.byKey(Key('trace-saved-$id-tick')));
        await tester.tap(find.byKey(Key('trace-saved-$id-tick')));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const Key('trace-compare')));
      await tapKey(tester, 'trace-compare');
      await tester.pump();
      expect(find.text('Different chains'), findsOneWidget);
    });

    testWidgets('nothing saved: says so', (tester) async {
      final (tools, _) = fakeTools();
      final host = FakeToolsHost()..toolsValue = tools;
      await pumpTool(tester, const TraceScreen(), host);
      await settleReal(tester, real: const Duration(milliseconds: 50));
      await tester.ensureVisible(find.byKey(const Key('trace-no-saved')));
      expect(find.byKey(const Key('trace-no-saved')), findsOneWidget);
    });
  });

  testWidgets('every look: no overflow, tap targets 48 px, result and comparison readable', (tester) async {
    final a = contact(key('df01', 1), 'Hill Top Repeater With A Long Name', lat: 40.13, lon: -82.97);
    final k = a.publicKeyHex;
    late FakeToolsHost host;
    Widget open() {
      final (tools, _) = fakeTools(contacts: [a], store: [saved('02', 'Hill Top Repeater With A Long Name', k, 2.0, 1.0, lat: 40.13, lon: -82.97), saved('01', 'Hill Top Repeater With A Long Name', k, 4.5, 3.0)]);
      host = FakeToolsHost()..toolsValue = tools;
      return const TraceScreen();
    }

    // pumpTool needs the host before the widget, so build both first
    for (final look in <({Device d, double scale, Brightness b})>[
      (d: Device.iphone, scale: 1.0, b: Brightness.light),
      (d: Device.iphone, scale: 2.5, b: Brightness.dark),
      (d: Device.iphoneSmall, scale: 2.5, b: Brightness.light),
      (d: Device.ipad, scale: 1.0, b: Brightness.dark),
    ]) {
      final screen = open();
      await pumpTool(tester, screen, host, device: look.d, textScale: look.scale, brightness: look.b);
      await settleReal(tester, real: const Duration(milliseconds: 50));
      await openAddHop(tester);
      await tester.tap(find.byKey(Key('trace-pick-${a.publicKeyHex.substring(0, 8)}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('trace-saved-02-open')));
      await tester.tap(find.byKey(const Key('trace-saved-02-open')));
      await tester.pump();
      for (final id in ['01', '02']) {
        await tester.ensureVisible(find.byKey(Key('trace-saved-$id-tick')));
        await tester.tap(find.byKey(Key('trace-saved-$id-tick')));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const Key('trace-compare')));
      await tapKey(tester, 'trace-compare');
      await tester.pump();
      expectTapTargets(tester);
      expect(tester.takeException(), isNull, reason: 'overflow at ${look.d.name} x${look.scale} ${look.b.name}');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
