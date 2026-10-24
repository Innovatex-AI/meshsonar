import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/region/repeaters_panel.dart';

Map<String, dynamic> row(
  String k,
  String name,
  String status, {
  String? last,
  double? snr,
  int? nbr,
}) => {
  'key': k * 32,
  'hashPrefix': k,
  'name': name,
  'role': 'repeater',
  'lat': 40.0,
  'lon': -83.0,
  'firstSeenAt': null,
  'lastHeardAt': last,
  'relays24h': null,
  'adverts24h': null,
  'neighbours': nbr,
  'observers24h': null,
  'heardHoursPct': null,
  'snrMeanDb': snr,
  'signalGrade': null,
  'hashSizeBytes': 1,
  'ambiguous': false,
  'status': status,
};

Map<String, dynamic> body(
  List<Map<String, dynamic>> rows, {
  String state = 'ready',
  String? reason,
}) => {
  'status': {
    'state': state,
    'reason': reason,
    'computedAt': null,
    'source': 's',
  },
  'rows': rows,
  'counts': {'active': 1, 'quiet': 1, 'new': 0, 'stale': 0},
};

Widget host(http.Client c) => MaterialApp(
  home: Scaffold(
    body: RepeatersPanel(
      baseUrl: 'https://cmh.meshsonar.com',
      regionSlug: 'cmh',
      client: c,
    ),
  ),
);

void main() {
  final now = DateTime.now().toUtc();
  String ago(int m) => now.subtract(Duration(minutes: m)).toIso8601String();

  testWidgets('loading then list, search and sort', (t) async {
    final c = MockClient(
      (_) async => http.Response(
        jsonEncode(
          body([
            row('aa', 'Zulu', 'active', last: ago(5), snr: 9, nbr: 2),
            row('bb', 'Alpha', 'quiet', last: ago(300), snr: 3, nbr: 9),
          ]),
        ),
        200,
      ),
    );
    await t.pumpWidget(host(c));
    expect(find.byKey(const Key('repeaters-loading')), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('Zulu'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.textContaining('5m ago'), findsOneWidget);
    // default: last heard first
    expect(
      t.getTopLeft(find.text('Zulu')).dy < t.getTopLeft(find.text('Alpha')).dy,
      isTrue,
    );
    await t.tap(find.byKey(const Key('repeaters-sort')));
    await t.pumpAndSettle();
    await t.tap(find.text('Sort: Name'));
    await t.pumpAndSettle();
    expect(
      t.getTopLeft(find.text('Alpha')).dy < t.getTopLeft(find.text('Zulu')).dy,
      isTrue,
    );
    await t.enterText(find.byKey(const Key('repeaters-search')), 'zul');
    await t.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    await t.enterText(find.byKey(const Key('repeaters-search')), 'nope');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('repeaters-no-match')), findsOneWidget);
  });

  testWidgets('status filter', (t) async {
    final c = MockClient(
      (_) async => http.Response(
        jsonEncode(
          body([row('aa', 'Zulu', 'active'), row('bb', 'Alpha', 'quiet')]),
        ),
        200,
      ),
    );
    await t.pumpWidget(host(c));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('repeaters-filter-quiet')));
    await t.pumpAndSettle();
    expect(find.text('Zulu'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('empty state shows the server reason', (t) async {
    final c = MockClient(
      (_) async => http.Response(
        jsonEncode(body([], state: 'pending', reason: 'Nothing heard yet')),
        200,
      ),
    );
    await t.pumpWidget(host(c));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('repeaters-empty')), findsOneWidget);
    expect(find.text('Nothing heard yet'), findsOneWidget);
  });

  testWidgets('error state with retry recovers', (t) async {
    var fail = true;
    final c = MockClient(
      (_) async => fail
          ? http.Response('x', 500)
          : http.Response(jsonEncode(body([row('aa', 'Zulu', 'active')])), 200),
    );
    await t.pumpWidget(host(c));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('repeaters-error')), findsOneWidget);
    fail = false;
    await t.tap(find.byKey(const Key('repeaters-retry')));
    await t.pumpAndSettle();
    expect(find.text('Zulu'), findsOneWidget);
  });

  test('filterAndSort puts unknowns last', () {
    final rows = RegionRepeaters.fromJson(
      body([
        row('aa', 'A', 'active', snr: 1),
        row('bb', 'B', 'active'),
        row('cc', 'C', 'active', snr: 5),
      ]),
    ).rows;
    expect(
      [for (final r in filterAndSort(rows, sort: RepeaterSort.snr)) r.name],
      ['C', 'A', 'B'],
    );
    expect(lastSeenLabel(null), 'never');
  });
}
