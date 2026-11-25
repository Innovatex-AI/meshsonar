// The Network search sheet before anything is typed (build 76): a title that says what is searched and three plain
// examples of what can be found, instead of one paragraph of jargon.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/v1/search_api.dart';
import 'package:meshsonar/ui/network/network_search.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  testWidgets('says what it searches and what can be typed; nothing overflows at 375 pt', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sc = ScrollController();
    addTearDown(sc.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(
        body: NetworkSearchSheet(controller: sc, region: null, baseUrl: 'https://meshsonar.com', local: const LocalSearchIndex(nodes: [], regions: [], region: null)),
      ),
    ));
    await tester.pump();
    expect(find.text('Search every region'), findsOneWidget);
    expect(find.byKey(const Key('network-search-hint')), findsOneWidget);
    expect(find.text('A region, by city or code'), findsOneWidget);
    expect(find.textContaining('key prefix'), findsNothing, reason: 'no jargon in the hint');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the search field of All regions fits one line at 375 pt', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: const Scaffold(body: Padding(padding: EdgeInsets.all(12), child: NetworkSearchField(region: null, hubUrl: 'https://meshsonar.com'))),
    ));
    expect(find.text('Search every region'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('network-search-field'))).height, greaterThanOrEqualTo(44));
  });
}
