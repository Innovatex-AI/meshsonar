// Driven by scripts/verify_sim.sh. Visits every screen in screens.dart on the real app and prints
// "APP_VERSION x+y" and "SCREEN <name>" lines for the script to screenshot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:package_info_plus/package_info_plus.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('visit every screen', (t) async {
    await app.main();
    final info = await PackageInfo.fromPlatform();
    // ignore: avoid_print
    print('APP_VERSION ${info.version}+${info.buildNumber}');

    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      await shot(t, 'onboarding-1');
      for (var i = 2; i <= 3; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(seconds: 1));
        await shot(t, 'onboarding-$i');
      }
      await t.tap(find.byKey(const Key('onboarding-next')));
      await pumpFor(t, const Duration(seconds: 1));
    }
    expect(await waitFor(t, find.text('Drive')), isTrue, reason: 'home shell');

    for (final s in screens) {
      try {
        await s.run(t);
      } catch (e) {
        if (s.optional) {
          // ignore: avoid_print
          print('SKIPPED ${s.name} (not on this checkout)');
          continue;
        }
        // ignore: avoid_print
        print('FAILED ${s.name}: $e');
        rethrow;
      }
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
