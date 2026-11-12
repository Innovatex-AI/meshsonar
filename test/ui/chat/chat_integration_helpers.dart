import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text(label)));
  await tester.pumpAndSettle();
}
