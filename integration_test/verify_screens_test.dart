// Driven by scripts/verify_sim.sh. Visits every screen in screens.dart on the real app and prints
// "APP_VERSION x+y" and "SCREEN <name>" lines for the script to screenshot, "STEP <name> ok" / "NOTE ..." per step, and
// "STEPFAIL <why>" / "OVERFLOW <what>" for problems (the script fails the run on those).
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

    // Every layout overflow on the way is reported: scripts/verify_sim.sh fails the run on an OVERFLOW line (and the test
    // itself still fails on the error, as before).
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('overflowed')) {
        // ignore: avoid_print
        print('OVERFLOW ${s.split('\n').first} ${d.context ?? ''}');
      }
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      await shot(t, 'onboarding-1');
      for (var i = 2; i <= 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(seconds: 1));
        await shot(t, 'onboarding-$i');
      }
      await t.tap(find.byKey(const Key('onboarding-next')));
      await pumpFor(t, const Duration(seconds: 1));
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue, reason: 'home shell');

    for (final s in screens) {
      try {
        await s.run(t);
      } catch (e, st) {
        if (s.optional) {
          // ignore: avoid_print
          print('SKIPTRACE ${s.name}: ${st.toString().split('\n').take(8).join(' | ')}');
          // ignore: avoid_print
          print('SKIPPED ${s.name} (not on this checkout: ${e.toString().split('\n').first})');
          continue;
        }
        // ignore: avoid_print
        print('FAILED ${s.name}: $e');
        rethrow;
      }
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 40))); // build 71: the tour also walks the eight Network sections against the live site
}
