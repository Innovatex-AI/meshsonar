// The "Always" location explainer (first run and Settings > Privacy, read-only) and the words of the region preset
// question. Build 76: one sentence per point with the rest on a tap, buttons pinned at the bottom, nothing printed as
// "SFnull".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/always_location_screen.dart';
import 'package:meshsonar/ui/settings/data_sharing.dart' show locationPoints;
import 'package:meshsonar/ui/theme.dart';

Future<void> pumpAt(WidgetTester tester, Widget home, {double scale = 1}) async {
  tester.view.physicalSize = const Size(750, 1334); // 375 x 667 pt: the smallest iPhone
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: home));
  await tester.pumpAndSettle();
}

void main() {
  test('splitFirstSentence: the first sentence and the rest; nothing is dropped', () {
    expect(splitFirstSentence('One. Two. Three.'), ('One.', 'Two. Three.'));
    expect(splitFirstSentence('Only one sentence.'), ('Only one sentence.', ''));
    for (final p in locationPoints) {
      final (first, rest) = splitFirstSentence(p.body);
      expect(first, isNotEmpty);
      expect(rest.isEmpty ? first : '$first $rest', p.body);
    }
  });

  test('presetLine: leaves out what the radio has not reported, never prints null', () {
    expect(presetLine(910.525, 62.5, 7, 5), '910.525 MHz · 62.5 kHz · SF7 · CR5');
    expect(presetLine(910.525, 62.5, null, null), '910.525 MHz · 62.5 kHz');
    expect(presetLine(null, null, null, null), 'Not reported yet');
    expect(presetLine(0, 0, null, null), 'Not reported yet');
  });

  testWidgets('first run: the buttons are on screen without scrolling; each point shows one sentence and opens', (tester) async {
    await pumpAt(tester, const AlwaysLocationScreen());
    expect(tester.takeException(), isNull);
    final screen = tester.getRect(find.byKey(const Key('always-location-screen')));
    for (final k in ['always-location-continue', 'always-location-not-now']) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.bottom, lessThanOrEqualTo(screen.bottom), reason: '$k is on screen');
      expect(r.height, greaterThanOrEqualTo(48), reason: k);
    }
    expect(find.byKey(const Key('always-location-next')), findsOneWidget);
    expect(find.byKey(const Key('always-location-settings')), findsNothing);
    final (first, rest) = splitFirstSentence(locationPoints.first.body);
    expect(find.text(first), findsOneWidget);
    expect(find.text(rest), findsNothing);
    await tester.tap(find.byKey(const Key('always-location-point-0')));
    await tester.pumpAndSettle();
    expect(find.text(rest), findsOneWidget);
  });

  testWidgets('from Settings: its own heading, Done and a way to iOS Settings, no permission button; 2x text fits', (tester) async {
    await pumpAt(tester, const AlwaysLocationScreen(explainOnly: true), scale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('How MeshSonar uses your location'), findsOneWidget);
    expect(find.byKey(const Key('always-location-continue')), findsNothing);
    expect(find.byKey(const Key('always-location-next')), findsNothing);
    final screen = tester.getRect(find.byKey(const Key('always-location-screen')));
    for (final k in ['always-location-done', 'always-location-settings']) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.bottom, lessThanOrEqualTo(screen.bottom), reason: '$k is on screen');
      expect(r.height, greaterThanOrEqualTo(48), reason: k);
    }
    final scroll = find.byType(Scrollable).first;
    for (final (i, p) in locationPoints.indexed) {
      await tester.scrollUntilVisible(find.byKey(Key('always-location-point-$i')), 150, scrollable: scroll);
      expect(find.text(p.head), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
