import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/ui/region/overview_panel.dart';
import 'package:meshsonar/ui/region/region_common.dart';
import 'package:meshsonar/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: meshSonarTheme(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void useClient(Future<http.Response> Function(http.Request) h) {
  regionApiFactory = (b) => RegionOverviewApi(b, client: MockClient(h));
}

Map<String, dynamic> overview({
  String state = 'ready',
  String? reason,
  int? packets = 612,
  List<int>? hours,
}) => {
  'status': {
    'state': state,
    'reason': reason,
    'computedAt': DateTime.now().toUtc().toIso8601String(),
  },
  'packets24h': packets,
  'observersOnline': 1,
  'observersTotal': 9,
  'repeaters': 326,
  'repeatersHeard24h': 64,
  'packetsPerHour': [
    for (var i = 0; i < (hours ?? [7, 28, 44]).length; i++)
      {
        'at': '2026-10-23T0$i:00:00.000Z',
        'n': (hours ?? [7, 28, 44])[i],
      },
  ],
  'lastPacketAt': null,
  'recentEvents': [],
};

void main() {
  tearDown(() => regionApiFactory = (b) => RegionOverviewApi(b));

  testWidgets('overview: loading then ready cards, sparkline, ready chip', (
    tester,
  ) async {
    final c = Completer<http.Response>();
    useClient((_) => c.future);
    await tester.pumpWidget(
      wrap(
        const OverviewPanel(baseUrl: 'https://cmh.example', regionSlug: 'cmh'),
      ),
    );
    expect(find.byKey(const Key('overview-loading')), findsOneWidget);
    c.complete(http.Response(jsonEncode(overview()), 200));
    await tester.pumpAndSettle();
    expect(find.text('612'), findsOneWidget);
    expect(find.text('1 / 9'), findsOneWidget);
    expect(find.text('326'), findsOneWidget);
    expect(find.text('64'), findsOneWidget);
    expect(find.byKey(const Key('sparkline')), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byKey(const Key('region-status-reason')), findsNothing);
  });

  testWidgets('overview: partial shows the server reason verbatim', (
    tester,
  ) async {
    const reason =
        'No MeshSonar observers in this region yet: only the CoreScope view is shown.';
    useClient(
      (_) async => http.Response(
        jsonEncode(
          overview(state: 'partial', reason: reason, packets: 0, hours: [0, 0]),
        ),
        200,
      ),
    );
    await tester.pumpWidget(
      wrap(
        const OverviewPanel(baseUrl: 'https://day.example', regionSlug: 'day'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Partial'), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(find.text('0'), findsWidgets);
    expect(find.textContaining('No packets in the last 2 h'), findsOneWidget);
  });

  testWidgets(
    'overview: pending with no numbers shows empty state, nulls are dashes',
    (tester) async {
      final j =
          overview(
              state: 'pending',
              reason: 'Region is being set up.',
              packets: null,
            )
            ..['repeaters'] = null
            ..['packetsPerHour'] = [];
      useClient((_) async => http.Response(jsonEncode(j), 200));
      await tester.pumpWidget(
        wrap(
          const OverviewPanel(baseUrl: 'https://x.example', regionSlug: 'x'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Region is being set up.'), findsOneWidget);
      expect(find.text('No overview data yet'), findsOneWidget);
    },
  );

  testWidgets('overview: error shows banner and retry works', (tester) async {
    var fail = true;
    useClient(
      (_) async => fail
          ? http.Response('{"error":"per region"}', 400)
          : http.Response(jsonEncode(overview()), 200),
    );
    await tester.pumpWidget(
      wrap(
        const OverviewPanel(baseUrl: 'https://hub.example', regionSlug: 'hub'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('per region'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('612'), findsOneWidget);
  });



  test('agoText and groupInt', () {
    final now = DateTime.utc(2026, 10, 24, 12);
    expect(agoText(null), 'never');
    expect(
      agoText(now.subtract(const Duration(minutes: 3)), now: now),
      '3 min ago',
    );
    expect(
      agoText(now.subtract(const Duration(hours: 5)), now: now),
      '5 h ago',
    );
    expect(groupInt(1234567), '1,234,567');
    expect(groupInt(12), '12');
  });
}
