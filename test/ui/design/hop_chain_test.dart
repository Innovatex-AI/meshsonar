import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/hop_chain.dart';
import 'package:meshsonar/ui/theme.dart';

Future<void> pump(WidgetTester tester, List<HopNode> nodes, {double scale = 1.0, Brightness b = Brightness.light}) async {
  tester.view.physicalSize = const Size(393 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(b),
    home: MediaQuery(
      data: MediaQueryData(size: const Size(393, 800), textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: HopChain(nodes: nodes))),
    ),
  ));
}

List<HopNode> chain(int n, {bool weak = false, bool unknownMiddle = false}) => [
      const HopNode('You', linkToNext: LinkQuality.strong),
      for (var i = 1; i < n - 1; i++)
        HopNode('Rep$i', detail: 'a$i', unknown: unknownMiddle && i == 1, linkToNext: weak && i == 1 ? LinkQuality.weak : LinkQuality.good),
      const HopNode('Maya'),
    ];

void main() {
  group('layout rule', () {
    test('horizontal only for 3 nodes or fewer at 1.3x text or less', () {
      expect(HopChain.horizontalFits(2, 1.0), isTrue);
      expect(HopChain.horizontalFits(3, 1.3), isTrue);
      expect(HopChain.horizontalFits(3, 1.31), isFalse);
      expect(HopChain.horizontalFits(4, 1.0), isFalse);
    });
  });

  group('rendering', () {
    for (final n in [2, 3, 4, 6]) {
      testWidgets('$n nodes at 1.0x: ${n <= 3 ? 'horizontal' : 'vertical'}', (tester) async {
        await pump(tester, chain(n));
        for (var i = 0; i < n; i++) {
          expect(find.byKey(Key('hop-label-$i')), findsOneWidget);
        }
        final first = tester.getTopLeft(find.byKey(const Key('hop-label-0')));
        final last = tester.getTopLeft(find.byKey(Key('hop-label-${n - 1}')));
        if (n <= 3) {
          expect(last.dy, first.dy, reason: 'same row');
          expect(last.dx, greaterThan(first.dx));
        } else {
          expect(last.dy, greaterThan(first.dy), reason: 'stacked');
          expect(last.dx, first.dx);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('AX text turns even a short chain into a vertical timeline', (tester) async {
      await pump(tester, chain(3), scale: 2.0);
      final first = tester.getTopLeft(find.byKey(const Key('hop-label-0')));
      final last = tester.getTopLeft(find.byKey(const Key('hop-label-2')));
      expect(last.dy, greaterThan(first.dy));
      expect(tester.takeException(), isNull);
    });

    testWidgets('weak link and unknown hop render, dark too, without overflow', (tester) async {
      await pump(tester, chain(4, weak: true, unknownMiddle: true), b: Brightness.dark);
      expect(find.text('Weak link'), findsOneWidget);
      expect(find.text('Unknown repeater'), findsOneWidget);
      expect(find.text('?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('horizontal shows the quality words under the links', (tester) async {
      await pump(tester, chain(3, weak: true));
      expect(find.text('Strong'), findsOneWidget);
      expect(find.text('Weak'), findsOneWidget);
    });
  });

  group('VoiceOver text', () {
    test('a plain sentence with hashes and weak links', () {
      expect(describeHopChain(chain(4, weak: true)),
          'Route: You, then Rep1 (a1), then Rep2 (a2), then Maya. You to Rep1 is a strong link. Rep1 to Rep2 is a weak link. Rep2 to Maya is a good link.');
    });
    test('an unknown hop is named as such; an empty chain says no route', () {
      expect(describeHopChain([const HopNode('You'), const HopNode('a1', detail: 'a1', unknown: true), const HopNode('Maya')]),
          'Route: You, then unknown repeater a1, then Maya.');
      expect(describeHopChain(const []), 'Route: no route.');
    });
    test('prefix for route out / back', () => expect(describeHopChain([const HopNode('You'), const HopNode('Maya')], prefix: 'Route out'), 'Route out: You, then Maya.'));

    testWidgets('the widget exposes exactly one label', (tester) async {
      await pump(tester, chain(3));
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('^Route: You, then Rep1')), findsOneWidget);
      handle.dispose();
    });

    test('SNR to words', () {
      expect(linkQualityOfSnr(8), LinkQuality.strong);
      expect(linkQualityOfSnr(0), LinkQuality.good);
      expect(linkQualityOfSnr(-9), LinkQuality.weak);
      expect(linkQualityOfSnr(null), LinkQuality.unknown);
    });
  });
}
