// The How it works / Method pages. (The old region packet and observer detail screens were retired in build 71: every
// packet, node and observer opens on the `/v1` screens, tested in test/ui/network/.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/info/method_screens.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  group('info pages', () {
    testWidgets('How it works: four numbered steps, regions, replay button calls back', (tester) async {
      var replayed = 0;
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: HowItWorksScreen(onReplayTour: () => replayed++)));
      expect(find.text('From a phone in a car to a coloured hexagon on the map, in four steps.'), findsOneWidget);
      expect(find.textContaining('Your phone pings.', findRichText: true), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Regions'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('howitworks-tour')), 200);
      await tester.tap(find.byKey(const Key('howitworks-tour')));
      expect(replayed, 1);
    });

    testWidgets('How it works at 375 pt and 2x text: no overflow, 48 pt buttons, and Method is one tap away', (tester) async {
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: HowItWorksScreen(onReplayTour: () {})));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Every ping is filed by where it was sent'), findsNothing, reason: 'reference text opens on a tap');
      await tester.scrollUntilVisible(find.text('Regions'), 200);
      await tester.tap(find.text('Regions'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Every ping is filed by where it was sent'), findsOneWidget);
      for (final k in ['howitworks-method', 'howitworks-tour']) {
        await tester.scrollUntilVisible(find.byKey(Key(k)), 200);
        expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
      }
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('howitworks-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('howitworks-method')));
      await tester.pumpAndSettle();
      expect(find.byType(MethodScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Method: the limits and the privacy rules are there', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: const MethodScreen()));
      expect(find.text('What it cannot say'), findsOneWidget);
      expect(find.text('Privacy rules applied before anything is public'), findsOneWidget);
      // Build 76: a heading per subject; the first is open, the others open on a tap.
      expect(find.textContaining('A ping is a short message'), findsOneWidget);
      expect(find.textContaining('MS: and ten random characters'), findsNothing);
      await tester.scrollUntilVisible(find.text('Channels and pings'), 200);
      await tester.tap(find.text('Channels and pings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('MS: and ten random characters'), findsOneWidget);
    });
  });
}
