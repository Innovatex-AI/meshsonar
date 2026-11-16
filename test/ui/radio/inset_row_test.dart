// InsetRow: a row with a short value ends its chevron on the same right edge as a row without one (build 67 sim tour:
// the channel page's "MeshTrack group  Open >" and "Rename  Saturday crew >" chevrons sat left of the others).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/radio/inset_list.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  testWidgets('chevrons line up whether or not the row has a value, short or long', (tester) async {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(
        body: Column(children: [
          InsetRow(key: const Key('a'), title: 'Mute for a while', onTap: () {}),
          InsetRow(key: const Key('b'), title: 'MeshTrack group', value: 'Open', onTap: () {}),
          InsetRow(key: const Key('c'), title: 'Region', value: 'None: the whole mesh', onTap: () {}),
        ]),
      ),
    ));
    double chevronRight(String k) => tester.getTopRight(find.descendant(of: find.byKey(Key(k)), matching: find.byType(Icon)).last).dx;
    expect(chevronRight('b'), moreOrLessEquals(chevronRight('a'), epsilon: 0.5));
    expect(chevronRight('c'), moreOrLessEquals(chevronRight('a'), epsilon: 0.5));
    expect(tester.getTopRight(find.text('Open')).dx, greaterThan(300), reason: 'a short value ends on the right, next to its chevron');
  });
}
