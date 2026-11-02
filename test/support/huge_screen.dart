// A phone-width surface tall enough that the whole layers sheet (about 20 rows, lazily built) fits at its first detent.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void useHugeScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4800);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}
