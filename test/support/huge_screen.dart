// A phone-width surface tall enough that the whole layers sheet (about 25 rows, lazily built, shrink-wrapped to 40% of the
// screen at its first detent) is built: 432 x 8000 logical, device pixel ratio 1 (a high ratio makes pumpAndSettle time out).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void useHugeScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(432, 8000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Makes [target] findable inside the layers sheet. With [useHugeScreen] every row is already built, so this only checks
/// that; it exists so a test says what it relies on.
Future<void> revealInLayersSheet(WidgetTester tester, Finder target) async {
  expect(target, findsWidgets, reason: 'the layers sheet row is not built: use useHugeScreen');
}
