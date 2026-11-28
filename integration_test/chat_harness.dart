// Shared steps for chat_visual_test.dart and contacts_visual_test.dart (build 77).
//
// Both harnesses run under scripts/verify_sim.sh with HARNESS=1, which reads the run's output until it sees VERIFY_DONE.
// A throw used to end the test body without that line, so the script waited for its 30-minute timeout. [runHarness]
// prints `STEPFAIL <where>: <error>` and VERIFY_DONE on any throw (the test still fails), and a watchdog does the same if a
// step hangs.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens.dart';

/// Runs [body]; always ends the run with VERIFY_DONE. Any throw is printed as STEPFAIL (verify_sim.sh fails the run on it)
/// and rethrown, so the test fails too. A body still running after [limit] prints STEPFAIL watchdog and VERIFY_DONE.
Future<void> runHarness(String name, Future<void> Function() body, {Duration limit = const Duration(minutes: 12)}) async {
  var ended = false;
  void end() {
    if (ended) return;
    ended = true;
    print('VERIFY_DONE');
  }

  final dog = Timer(limit, () {
    print('STEPFAIL $name: watchdog, the run was still going after ${limit.inMinutes} min');
    end();
  });
  try {
    await body();
  } catch (e, st) {
    print('STEPFAIL $name: ${e.toString().split('\n').where((l) => l.trim().isNotEmpty).take(3).join(' | ')} @ '
        '${st.toString().split('\n').where((l) => l.contains('_test.dart') || l.contains('chat_harness.dart')).take(2).join(' ')}');
    end();
    rethrow;
  } finally {
    dog.cancel();
  }
  end();
}

/// Build 77 decision 4: the first connect of a radio still opens the antenna sheet, and it can be closed without saving.
/// It is an app sheet (not a Material BottomSheet), so it is closed through its own navigator. Returns true when one was
/// open. Throws when it does not close.
Future<bool> closeAntennaSheet(WidgetTester t, {Duration wait = const Duration(seconds: 8)}) async {
  final sheet = find.byKey(const Key('antenna-sheet'));
  if (!await waitFor(t, sheet, timeout: wait)) return false;
  print('NOTE antenna sheet opened on the first connect (decision 4); closed without saving');
  FocusManager.instance.primaryFocus?.unfocus();
  await Navigator.of(t.element(sheet.first)).maybePop();
  await pumpFor(t, const Duration(seconds: 1));
  if (sheet.evaluate().isNotEmpty) throw StateError('the antenna sheet did not close');
  return true;
}

/// Closes the sheet or page that holds the widget keyed [key] (its own navigator), when it is on screen.
Future<void> closeRouteHolding(WidgetTester t, String key) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return;
  await Navigator.of(t.element(f.first)).maybePop();
  await pumpFor(t, const Duration(seconds: 1));
}

/// Taps the first of [keys] found within [wait]; false when none showed up.
Future<bool> tapFirstOf(WidgetTester t, List<String> keys, {Duration wait = const Duration(seconds: 5)}) async {
  final any = find.byWidgetPredicate((w) => w.key is ValueKey<String> && keys.contains((w.key as ValueKey<String>).value));
  if (!await waitFor(t, any, timeout: wait)) return false;
  await t.ensureVisible(any.first);
  await pumpFor(t, const Duration(milliseconds: 400));
  await t.tap(any.first);
  await pumpFor(t, const Duration(seconds: 1));
  return true;
}

/// Build 77 (round 3): the first send raises the alerts pre-prompt; answer Not now. True when it was shown.
Future<bool> answerAlertsPrePrompt(WidgetTester t, {Duration wait = const Duration(seconds: 5)}) async {
  final no = find.byKey(const Key('alerts-preprompt-no'));
  if (!await waitFor(t, no, timeout: wait)) return false;
  print('NOTE alerts pre-prompt after the first send; answered Not now');
  await t.ensureVisible(no);
  await pumpFor(t, const Duration(milliseconds: 400));
  await t.tap(no);
  await pumpFor(t, const Duration(seconds: 1));
  return true;
}

/// Hides the keyboard (a focused search field keeps it up and it covers the rows under it).
Future<void> hideKeyboard(WidgetTester t) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFor(t, const Duration(milliseconds: 800));
}

/// Opens Chat on one of its segments ('chats', 'contacts', 'channels') and waits for that segment to be selected.
Future<void> openChatSegment(WidgetTester t, String segment) async {
  await openShellTab(t, 'Chat');
  final seg = find.byKey(Key('segment-$segment'));
  if (!await waitFor(t, seg, timeout: const Duration(seconds: 8))) throw StateError('no segment-$segment on the Chat tab');
  await t.tap(seg.first);
  await pumpFor(t, const Duration(seconds: 1));
}

/// A tap on the Chat tab's large title: closes an open swipe or menu without landing on a row, at every text size.
Future<void> tapChatTitle(WidgetTester t) async {
  final title = find.descendant(of: find.byType(CupertinoSliverNavigationBar), matching: find.text('Chat'));
  if (title.evaluate().isEmpty) {
    await t.tapAt(const Offset(10, 10));
  } else {
    await t.tapAt(t.getCenter(title.first));
  }
  await pumpFor(t, const Duration(milliseconds: 800));
}

/// A widget whose String key starts with [prefix].
Finder keyPrefix(String prefix) => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith(prefix));

/// A widget keyed with any of [keys].
Finder anyKey(List<String> keys) => find.byWidgetPredicate((w) => w.key is ValueKey<String> && keys.contains((w.key as ValueKey<String>).value));

/// Prints `NOTE <text>` (verify_sim.sh keeps NOTE lines in the run log).
void note(String text) => print('NOTE $text');
