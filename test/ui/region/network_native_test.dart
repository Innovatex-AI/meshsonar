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

    testWidgets('Method: the limits and the privacy rules are there', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: const MethodScreen()));
      expect(find.text('What it cannot say'), findsOneWidget);
      expect(find.text('Privacy rules applied before anything is public'), findsOneWidget);
      expect(find.textContaining('MS: and ten random characters'), findsOneWidget);
    });
  });
}
