// More > Observers (ID step 5, build 74): the row shows only when the server offers radio proof. The nine-row test in
// more_groups_test.dart covers the flag off (production); here the flag is on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/account/person_observers_screen.dart';

import 'fakes.dart';
import 'radio_proof_app_test.dart' as rp show open, settle;
import 'shell_test.dart' show drain;

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _on = SiteConfig(region: _region, capabilities: {'nodeClaims', 'radioProof'});

void main() {
  testWidgets('with radio proof on, More has an Observers row under Settings, and it opens the Observers screen', (tester) async {
    useTallScreen(tester);
    final h = await rp.open(tester, caps: _on, connect: false);
    expect(h.state.radioProofCapable, isTrue);
    await tapShellTab(tester, 'More');
    await rp.settle(tester, () => find.byKey(const Key('more-observers')).evaluate().isNotEmpty);
    final row = find.byKey(const Key('more-observers'));
    expect(row, findsOneWidget);
    // Build 77: Devices and keys is in Settings > Account only, so the row follows Settings.
    expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('more-settings'))).dy));
    await tester.tap(row);
    await rp.settle(tester, () => find.byType(PersonObserversScreen).evaluate().isNotEmpty);
    expect(find.byType(PersonObserversScreen), findsOneWidget);
    await drain(tester);
  });
}
