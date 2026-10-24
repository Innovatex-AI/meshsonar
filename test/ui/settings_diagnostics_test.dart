// Settings > Diagnostics: the log is shown and copied with the problem-report redaction (no keys, tokens or
// passwords; coordinates rounded), and clearing it asks first.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('the screen shows the log redacted', (tester) async {
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

  testWidgets('Copy puts the redacted log (with app and settings lines) on the clipboard and says what was hidden',
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
    final snack = find.byType(SnackBar);
    expect(find.descendant(of: snack, matching: find.textContaining('Log copied (')), findsOneWidget);
    expect(find.descendant(of: snack, matching: find.textContaining('secrets hidden')), findsOneWidget);
    expect(find.descendant(of: snack, matching: find.textContaining('rounded')), findsOneWidget);
  });

  test('redactionSummary', () {
    expect(redactionSummary({'driverKey': 0, 'coords': 0}), isNull);
    expect(redactionSummary({'driverKey': 1, 'secret': 1, 'coords': 1}), '2 secrets hidden, 1 position rounded');
  });

  testWidgets('Clear asks, then empties the log; an empty log says what would appear', (tester) async {
    final (h, _) = await open(tester);
    await showSetting(tester, 'diagnostics-log');
    await tester.tap(find.byKey(const Key('diagnostics-log')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-clear-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(h.state.diagnostics.lines, isNotEmpty);
    await tester.tap(find.byKey(const Key('diagnostics-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-clear-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(h.state.diagnostics.lines, isEmpty);
    expect(find.byKey(const Key('diagnostics-empty')), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('diagnostics-clear'))).onPressed, isNull);
  });
}
