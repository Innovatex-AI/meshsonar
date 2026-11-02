import 'package:flutter_test/flutter_test.dart';

/// `testWidgets` for tests that make the app show a toast. A toast holds a Timer (2.5 s to 5 s) that the test binding
/// treats as a leak, so this lets it run out before the test ends. Assertions about the toast stay in the test body.
void testWidgetsT(String description, WidgetTesterCallback body, {bool? skip}) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pump(const Duration(seconds: 6));
  }, skip: skip);
}
