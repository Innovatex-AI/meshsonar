import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/ui/region/observers_panel.dart';
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

  testWidgets(
    'observers: sorted online first, shows counts, last seen, partial reason',
    (tester) async {
      final now = DateTime.now().toUtc();
      final body = {
        'status': {'state': 'partial', 'reason': 'Only CoreScope view.'},
        'rows': [
          {
            'key': 'aaaa1111',
            'name': 'Zed offline',
            'online': false,
            'lastStatusAt': now
                .subtract(const Duration(days: 2))
                .toIso8601String(),
          },
          {
            'key': 'bbbb2222',
            'name': 'Alpha online',
            'online': true,
            'lastPacketAt': now
                .subtract(const Duration(minutes: 5))
                .toIso8601String(),
            'packetsPerHour': 64,
            'nodesHeard24h': 71,
            'noiseFloorDbm': -73,
            'source': 'meshsonar',
          },
        ],
      };
      useClient((_) async => http.Response(jsonEncode(body), 200));
      await tester.pumpWidget(
        wrap(
          const ObserversPanel(
            baseUrl: 'https://cmh.example',
            regionSlug: 'cmh',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 online of 2'), findsOneWidget);
      expect(find.text('Only CoreScope view.'), findsOneWidget);
      expect(find.textContaining('64 pkt/h'), findsOneWidget);
      expect(find.textContaining('seen 5 min ago'), findsOneWidget);
      expect(find.textContaining('seen 2 d ago'), findsOneWidget);
      expect(find.byKey(const Key('dot-online')), findsOneWidget);
      expect(find.byKey(const Key('dot-offline')), findsOneWidget);
      final y1 = tester
          .getTopLeft(find.byKey(const Key('observer-bbbb2222')))
          .dy;
      final y2 = tester
          .getTopLeft(find.byKey(const Key('observer-aaaa1111')))
          .dy;
      expect(y1, lessThan(y2));
    },
  );

  testWidgets('observers: empty and error states', (tester) async {
    useClient(
      (_) async => http.Response(
        jsonEncode({
          'status': {'state': 'pending', 'reason': 'Nothing yet.'},
          'rows': [],
        }),
        200,
      ),
    );
    await tester.pumpWidget(
      wrap(const ObserversPanel(baseUrl: 'https://a.example', regionSlug: 'a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('No observers listed'), findsOneWidget);
    expect(find.text('Nothing yet.'), findsOneWidget);

    useClient((_) async => throw Exception('offline'));
    await tester.pumpWidget(
      wrap(
        const ObserversPanel(
          key: ValueKey('b'),
          baseUrl: 'https://b.example',
          regionSlug: 'b',
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Unreachable with nothing stored: the shared honest offline state (region_offline_test.dart covers Retry).
    expect(find.byKey(const Key('region-offline-empty')), findsOneWidget);
    expect(find.text('No connection'), findsOneWidget);
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
