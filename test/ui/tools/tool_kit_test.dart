import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/ui/tools/tool_kit.dart';

import '../../support/tools_ui_rig.dart';

void main() {
  group('formatters', () {
    test('snr words follow the website levels', () {
      expect(snrWord(6), 'Strong');
      expect(snrWord(5), 'Strong');
      expect(snrWord(0), 'Good');
      expect(snrWord(-5), 'Fair');
      expect(snrWord(-5.25), 'Weak');
      expect(snrWord(null), 'Unknown');
      expect(fmtSnr(3.25), '+3.3 dB, good');
      expect(fmtDb(-4.0), '−4.0 dB');
      expect(fmtDb(null), 'unknown');
    });

    test('airtime and ages', () {
      expect(fmtAir(380), '0.4 s');
      expect(fmtAir(2100), '2.1 s');
      expect(fmtAir(36000), '36 s');
      expect(fmtAir(150000), '2.5 min');
      expect(fmtAgo(const Duration(seconds: 2)), 'just now');
      expect(fmtAgo(const Duration(seconds: 40)), '40 s ago');
      expect(fmtAgo(const Duration(minutes: 4)), '4 min ago');
      expect(fmtAgo(const Duration(hours: 2)), '2 h ago');
    });
  });

  group('ToolPage gate', () {
    for (final (state, words) in [
      (LinkState.disconnected, 'No radio connected'),
      (LinkState.reconnecting, 'Getting your radio back'),
      (LinkState.connecting, 'Connecting'),
      (LinkState.handedOver, 'Radio handed to another app'),
      (LinkState.connected, 'This radio connection cannot run the tools'),
    ]) {
      testWidgets('${state.name}: says "$words"', (tester) async {
        final host = FakeToolsHost()..linkState = state;
        await pumpTool(tester, ToolPage(id: 'x', title: 'X', builder: (c, h, t) => const Text('body')), host);
        expect(find.text(words), findsOneWidget);
        expect(find.text('body'), findsNothing);
        final connect = find.byKey(const Key('tool-connect'));
        if (state == LinkState.disconnected || state == LinkState.handedOver) {
          await tester.tap(connect);
          expect(host.connectOpened, 1);
        } else {
          expect(connect, findsNothing);
        }
      });
    }

    testWidgets('a radio appearing replaces the gate with the tool', (tester) async {
      final (rig, host) = await connectedRig(tester);
      final tools = rig.tools;
      host.setTools(null, state: LinkState.disconnected);
      await pumpTool(tester, ToolPage(id: 'x', title: 'X', builder: (c, h, t) => const Text('body')), host);
      expect(find.byKey(const Key('tool-unavailable')), findsOneWidget);
      host.setTools(tools, state: LinkState.connected);
      await tester.pump();
      expect(find.text('body'), findsOneWidget);
    });
  });

  group('CooldownButton', () {
    testWidgets('counts down in words, is disabled while waiting, works after', (tester) async {
      var now = DateTime(2026, 11, 1, 12);
      final until = now.add(const Duration(seconds: 3));
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CooldownButton(
            label: 'Send local advert',
            icon: Icons.campaign,
            cooldown: () => now.isBefore(until) ? until.difference(now) : null,
            onPressed: () => taps++,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Wait 3 s'), findsOneWidget);
      await tester.tap(find.byType(FilledButton), warnIfMissed: false);
      expect(taps, 0);
      expect(tester.getSemantics(find.byType(CooldownButton)).label, contains('Available again in 3 s'));
      now = now.add(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Send local advert'), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      expect(taps, 1);
      expect(tester.getSize(find.byType(FilledButton)).height, greaterThanOrEqualTo(48));
    });
  });

  group('NoteCard, ToolMap, ToolListener', () {
    testWidgets('a note speaks its kind in words, not just colour', (tester) async {
      final sem = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: NoteCard('Nothing answered.', kind: NoteKind.caution, title: 'No reply'))));
      expect(find.bySemanticsLabel(RegExp(r'^Careful\. No reply\. Nothing answered\.')), findsOneWidget);
      sem.dispose();
    });

    testWidgets('map: empty shows the words, pins and lines build without tiles', (tester) async {
      ToolMap.tilesEnabled = false;
      addTearDown(() => ToolMap.tilesEnabled = true);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ToolMap(pins: [], semanticLabel: 'No positions known yet.'))));
      expect(find.byKey(const Key('tool-map-empty')), findsOneWidget);
      expect(find.text('No positions known yet.'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ToolMap(
            pins: [MapPin(point: LatLng(40.1, -82.9), label: 'A'), MapPin(point: LatLng(40.2, -82.8), label: 'B')],
            lines: [MapLine([LatLng(40.1, -82.9), LatLng(40.2, -82.8)], Colors.orange)],
            semanticLabel: 'Two repeaters.',
          ),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const Key('tool-map')), findsOneWidget);
    });

    testWidgets('listener rebuilds on a burst at most once per interval', (tester) async {
      final c = StreamController<void>.broadcast();
      var builds = 0;
      await tester.pumpWidget(MaterialApp(
        home: ToolListener(sources: [c.stream], every: const Duration(milliseconds: 200), builder: (_) {
          builds++;
          return const SizedBox();
        }),
      ));
      expect(builds, 1);
      for (var i = 0; i < 50; i++) {
        c.add(null);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(builds, lessThanOrEqualTo(3));
      expect(builds, greaterThan(1));
      await tester.pumpWidget(const SizedBox());
      await c.close();
    });
  });
}
