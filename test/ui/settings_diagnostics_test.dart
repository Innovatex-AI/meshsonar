// Settings > Diagnostics: the log is shown and copied with the problem-report redaction (no keys, tokens or
// passwords; coordinates rounded), and clearing it asks first.
import 'toast_test_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/redact.dart' show redactText;
import 'package:meshsonar/ui/settings/diagnostics_section.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

const _key = 'ms_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg';

void main() {
  Future<(Harness, List<String>)> open(WidgetTester tester) async {
    useTallScreen(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    h.state.diagnostics.add('Upload failed with x-driver-key: $_key at 39.961234,-82.998765');
    h.state.diagnostics.add('Bearer abc.def.ghi rejected; mqtt://user:hunter2@broker.example:1883');
    await openSettingsTab(tester);
    return (h, copied);
  }

  testWidgetsT('the screen shows the log redacted', (tester) async {
    await open(tester);
    await showSetting(tester, 'diagnostics-log');
    await tester.tap(find.byKey(const Key('diagnostics-log')));
    await tester.pumpAndSettle();
    final shown = tester.widgetList<SelectableText>(find.byType(SelectableText)).map((t) => t.data!).join('\n');
    expect(shown, isNot(contains(_key)));
    expect(shown, isNot(contains('hunter2')));
    expect(shown, isNot(contains('39.961234')));
    expect(shown, contains('[redacted:driver-key]'));
    expect(shown, contains('39.961,-82.999'));
  });

  testWidgetsT('Copy puts the redacted log (with app and settings lines) on the clipboard and says what was hidden',
      (tester) async {
    final (h, copied) = await open(tester);
    await showSetting(tester, 'diagnostics-log');
    await tester.tap(find.byKey(const Key('diagnostics-log')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-copy')));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    final text = copied.single;
    expect(text, isNot(contains(_key)));
    expect(text, isNot(contains(h.state.settings.driverKey!)), reason: 'the settings snapshot never holds the key');
    expect(text, isNot(contains('hunter2')));
    expect(text, isNot(contains('abc.def.ghi')));
    expect(text, contains('Settings: server meshsonar.com'));
    expect(text, contains('39.961,-82.999'));
    expect(text, diagnosticsExport(h.state).text);
    expect(find.textContaining('Log copied ('), findsOneWidget);
    expect(find.textContaining('secrets hidden'), findsOneWidget);
    expect(find.textContaining('positions rounded)'), findsOneWidget);
  });

  // Build 76: the newest event is what a person came for, so it is first; a count line; Copy in thumb reach.
  testWidgetsT('newest first with a count line; the full-width "Copy log" button copies like the app-bar button', (tester) async {
    final (h, copied) = await open(tester);
    await showSetting(tester, 'diagnostics-log');
    expect(find.descendant(of: find.byKey(const Key('section-storage')), matching: find.byKey(const Key('diagnostics-log'))), findsOneWidget,
        reason: 'first level of Storage & diagnostics');
    await tester.tap(find.byKey(const Key('diagnostics-log')));
    await tester.pumpAndSettle();
    final all = h.state.diagnostics.lines;
    expect(all.length, greaterThanOrEqualTo(2));
    final count = tester.widget<Text>(find.byKey(const Key('diagnostics-count'))).data!;
    expect(count, startsWith('${all.length} lines, newest first'));
    expect(count, contains('Secrets hidden, positions rounded'));
    final shown = tester.widgetList<SelectableText>(find.byType(SelectableText)).map((t) => t.data!).toList();
    expect(shown.first, redactText(all.last).text, reason: 'the newest line is the first one under the count');
    for (var i = 0; i < shown.length; i++) {
      expect(shown[i], redactText(all[all.length - 1 - i]).text, reason: 'line $i: newest first, none skipped');
    }
    Finder line(String part) => find.byWidgetPredicate((w) => w is SelectableText && w.data!.contains(part));
    expect(tester.getTopLeft(find.byKey(const Key('diagnostics-count'))).dy, lessThan(tester.getTopLeft(line('broker.example')).dy));
    expect(tester.getTopLeft(line('broker.example')).dy, lessThan(tester.getTopLeft(line('39.961,-82.999')).dy),
        reason: 'the line added last is above the one added before it');

    final button = find.byKey(const Key('diagnostics-copy-button'));
    expect(find.descendant(of: button, matching: find.text('Copy log')), findsOneWidget);
    final screen = tester.getSize(find.byType(Scaffold).last);
    expect(tester.getSize(button).width, screen.width - 32, reason: 'full width');
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single, diagnosticsExport(h.state).text);
    expect(copied.single, isNot(contains(_key)));
    expect(copied.single, isNot(contains('hunter2')));
    expect(find.textContaining('Log copied ('), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // the toast goes
    await tester.tap(find.byKey(const Key('diagnostics-copy')));
    await tester.pumpAndSettle();
    expect(copied, hasLength(2));
    expect(copied.last, diagnosticsExport(h.state).text, reason: 'the app-bar button copies the same text');
  });

  test('redactionSummary', () {
    expect(redactionSummary({'driverKey': 0, 'coords': 0}), isNull);
    expect(redactionSummary({'driverKey': 1, 'secret': 1, 'coords': 1}), '2 secrets hidden, 1 position rounded');
  });

  testWidgetsT('Clear empties the log after the Undo window; an empty log says what would appear', (tester) async {
    final (h, _) = await open(tester);
    await showSetting(tester, 'diagnostics-log');
    await tester.tap(find.byKey(const Key('diagnostics-log')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagnostics-clear-dialog')), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pump(const Duration(seconds: 7));
    expect(h.state.diagnostics.lines, isNotEmpty, reason: 'Undo keeps the log');
    await tester.tap(find.byKey(const Key('diagnostics-clear')));
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(h.state.diagnostics.lines, isEmpty);
    expect(find.byKey(const Key('diagnostics-empty')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-copy-button')), findsNothing, reason: 'nothing to copy: no Copy log button');
    expect(find.byKey(const Key('diagnostics-count')), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const Key('diagnostics-clear'))).onPressed, isNull);
  });
}
