// MeshTrack MT-13 "Ask for location" screenshot flow, on the real app with the debug-only simulated radio:
//   FLOW_TEST=integration_test/ask_location_flow_test.dart LOCATION=40.1258,-82.9312 scripts/verify_sim.sh <worktree> [out]
// The simulated people answer all three ways (lib/radio/simulator.dart): Bob W8BOB with a position about 3 km NE, Cara
// N8CRA without one, Ann KE8ANN never. Shoots: ready, asking (spinner + Cancel), the position with distance and direction,
// the Drive map with Bob's "Asked" pin, no position, no answer, Cancel (countdown), and no radio. A miss prints STEPFAIL
// (the script fails the run) and the flow goes on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart';

import 'screens.dart';

final List<String> _failed = [];

class _Miss implements Exception {
  final String why;
  _Miss(this.why);
  @override
  String toString() => why;
}

Never _fail(String why) => throw _Miss(why);

Future<void> step(WidgetTester t, String name, Future<void> Function() body) async {
  try {
    await body();
    // ignore: avoid_print
    print('STEP $name ok');
  } catch (e) {
    _failed.add(name);
    // ignore: avoid_print
    print('STEPFAIL $name: ${e.toString().split('\n').first}');
    await popToRoots(t);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ask for location', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue);
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }
    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }

    Future<void> openContact(String name) async {
      await popToRoots(t);
      await openShellTab(t, 'Chat');
      final seg = find.byKey(const Key('segment-contacts'));
      if (seg.evaluate().isNotEmpty) {
        await t.tap(seg.first);
        await pumpFor(t, const Duration(seconds: 1));
      }
      if (!await waitFor(t, find.byKey(const Key('contacts-list')))) _fail('no contacts list');
      final yes = find.byKey(const Key('ask-yes'));
      if (await waitFor(t, yes, timeout: const Duration(seconds: 3))) {
        await t.tap(yes);
        await pumpFor(t, const Duration(seconds: 2));
      }
      final row = find.textContaining(name);
      await t.scrollUntilVisible(row, 200, scrollable: find.descendant(of: find.byKey(const Key('contacts-list')), matching: find.byType(Scrollable)).first);
      await t.tap(row.first);
      await pumpFor(t, const Duration(seconds: 2));
      final info = find.byKey(const Key('dm-contact-info'));
      if (info.evaluate().isNotEmpty) {
        await t.tap(info);
        await pumpFor(t, const Duration(seconds: 2));
      }
      if (find.byKey(const Key('contact-profile')).evaluate().isEmpty) {
        final title = find.byKey(const Key('conv-title'));
        if (title.evaluate().isNotEmpty) {
          await t.tap(title.first);
          await pumpFor(t, const Duration(seconds: 2));
        }
      }
      if (!await waitFor(t, find.byKey(const Key('contact-profile')), timeout: const Duration(seconds: 8))) _fail('$name: no contact screen');
    }

    /// Scrolls the contact screen so the Ask for location card is in the middle and holds still.
    Future<void> showCard() async {
      final card = find.byKey(const Key('ask-location-card'));
      if (!await scrollToFind(t, card, find.byKey(const Key('contact-profile')))) _fail('no Ask for location card');
      await Scrollable.ensureVisible(t.element(card.first), alignment: 0.45);
      await pumpFor(t, const Duration(milliseconds: 600));
    }

    Future<void> tapKey(String key) async {
      final f = find.byKey(Key(key));
      if (!await waitFor(t, f, timeout: const Duration(seconds: 5))) _fail('no $key');
      await t.tap(f.first, warnIfMissed: false);
      await pumpFor(t, const Duration(milliseconds: 300));
    }

    await step(t, 'ready', () async {
      await openContact('Bob W8BOB');
      await showCard();
      if (find.text('Ask for location').evaluate().isEmpty) _fail('no Ask for location row');
      await shot(t, 'ask-01-ready');
    });

    await step(t, 'asking-and-position', () async {
      await tapKey('ask-location');
      if (find.byKey(const Key('ask-location-asking')).evaluate().isEmpty) _fail('no asking row');
      await shot(t, 'ask-02-asking');
      if (!await waitFor(t, find.byKey(const Key('ask-location-answer')), timeout: const Duration(seconds: 40))) _fail('Bob did not answer');
      await pumpFor(t, const Duration(milliseconds: 500));
      await showCard();
      await shot(t, 'ask-03-position');
    });

    await step(t, 'map-pin', () async {
      await tapKey('ask-location-open');
      await pumpFor(t, const Duration(seconds: 3));
      final pin = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('map-asked-'));
      if (!await waitFor(t, pin, timeout: const Duration(seconds: 10))) _fail('no Asked pin on the Drive map');
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'ask-04-map-pin');
    });

    await step(t, 'no-position', () async {
      await openContact('Cara N8CRA');
      await showCard();
      await tapKey('ask-location');
      if (!await waitFor(t, find.byKey(const Key('ask-location-no-position')), timeout: const Duration(seconds: 40))) _fail('Cara: no "did not share" answer');
      await showCard();
      await shot(t, 'ask-05-no-position');
    });

    await step(t, 'no-answer', () async {
      await openContact('Ann KE8ANN');
      await showCard();
      await tapKey('ask-location');
      if (!await waitFor(t, find.byKey(const Key('ask-location-no-answer')), timeout: const Duration(seconds: 70))) _fail('Ann: no "No answer"');
      await showCard();
      await shot(t, 'ask-06-no-answer');
    });

    await step(t, 'cancel', () async {
      // Ann was last asked over 30 s ago (the wait itself is longer), so Try again asks at once.
      await tapKey('ask-location-retry');
      if (find.byKey(const Key('ask-location-asking')).evaluate().isEmpty) _fail('Try again did not ask');
      await pumpFor(t, const Duration(seconds: 2));
      await tapKey('ask-location-cancel');
      await pumpFor(t, const Duration(seconds: 1));
      if (find.byKey(const Key('ask-location-asking')).evaluate().isNotEmpty) _fail('Cancel did not stop asking');
      await showCard();
      await shot(t, 'ask-07-cancelled');
    });

    await step(t, 'no-radio', () async {
      await popToRoots(t);
      await state.disconnect(quiet: true);
      await pumpFor(t, const Duration(seconds: 2));
      await openContact('Bob W8BOB');
      await showCard();
      if (find.text('Connect your radio to ask.').evaluate().isEmpty) _fail('no "Connect your radio to ask."');
      await shot(t, 'ask-08-no-radio');
    });

    // ignore: avoid_print
    print('VERIFY_DONE');
    expect(_failed, isEmpty, reason: 'failed steps: $_failed');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
