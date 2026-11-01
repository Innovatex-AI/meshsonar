// More > Radios and tools > Become an observer: the wizard walks the existing claim flow; it adds no new network call.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/claims/claim_repeater_screen.dart';
import 'package:meshsonar/ui/radios/observer_join_screen.dart';

import 'claims_ui_test.dart' show open, openScreen;
import 'fakes.dart';

void main() {
  testWidgets('no claims on the server: every claim step is waiting and the reason is shown', (tester) async {
    await open(tester, caps: false);
    await openScreen(tester, const ObserverJoinScreen());
    expect(find.byKey(const Key('observer-intro')), findsOneWidget);
    expect(find.byKey(const Key('observer-why-not')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('observer-claim-repeater'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('observer-claim-radio'))).onPressed, isNull);
  });

  testWidgets('radio connected and claims offered: Claim a repeater opens the existing claim screen', (tester) async {
    await open(tester);
    await openScreen(tester, const ObserverJoinScreen());
    expect(find.byKey(const Key('observer-why-not')), findsNothing);
    final btn = find.byKey(const Key('observer-claim-repeater'));
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.byType(ClaimRepeaterScreen), findsOneWidget);
  });

  testWidgets('More lists the wizard under Radios and tools', (tester) async {
    useTallScreen(tester);
    await Harness().pumpApp(tester);
    await tapShellTab(tester, 'More');
    final row = find.byKey(const Key('more-observerJoin'));
    await tester.scrollUntilVisible(row, 100, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('observer-join-screen')), findsOneWidget);
  });
}
