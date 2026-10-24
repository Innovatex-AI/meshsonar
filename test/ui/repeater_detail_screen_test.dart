import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/ui/region/repeater_detail_screen.dart';
import 'package:meshsonar/ui/theme.dart';

const _key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';

Widget _app(http.Client c, {String key = _key}) => MaterialApp(
  theme: meshSonarTheme(Brightness.light),
  home: RepeaterDetailScreen(
    baseUrl: 'https://cmh.meshsonar.com',
    regionSlug: 'cmh',
    repeaterKey: key,
    client: c,
    mapTiles: false,
    now: DateTime.utc(2026, 10, 24, 2),
  ),
);

void main() {
  void tall(WidgetTester t) {
    t.view.physicalSize = const Size(800, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets(
    'shows identity, stats, position, heatmap, neighbours, observers',
    (t) async {
      t.view.physicalSize = const Size(800, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final body = File('test/fixtures/region_repeater_cmh.json')
          .readAsStringSync();
      await t.pumpWidget(
        _app(MockClient((_) async => http.Response(body, 200))),
      );
      expect(find.byKey(const Key('repdetail-loading')), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('INNO-ALBANY-WEST'), findsWidgets);
      expect(find.byKey(const Key('repdetail-hash')), findsOneWidget);
      expect(find.text('da5d'), findsOneWidget);
      expect(find.text(_key), findsOneWidget);
      expect(find.textContaining('Last heard: 36 min ago'), findsOneWidget);
      expect(find.byKey(const Key('repdetail-coords')), findsOneWidget);
      expect(find.byKey(const Key('repdetail-sparkline')), findsOneWidget);
      expect(find.byKey(const Key('repdetail-heatmap')), findsOneWidget);
      expect(
        find.text('Sat 10/24'),
        findsOneWidget,
      ); // anchored on heatmapEnd 2026-10-24
      expect(find.text('Sun 10/18'), findsOneWidget);
      expect(find.text('OH.FRA.ForestPark'), findsWidgets);
      expect(find.text('SNR unknown'), findsWidgets);
      expect(find.text('OH.FRA.ForestPark.OB'), findsOneWidget);
    },
  );

  testWidgets('unknown key: honest not-found, no retry', (t) async {
    await t.pumpWidget(
      _app(
        MockClient(
          (_) async =>
              http.Response('{"status":{"state":"not_found"},"row":null}', 404),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Not in this region'), findsOneWidget);
    expect(find.byKey(const Key('repdetail-retry')), findsNothing);
  });

  testWidgets('offline: error with retry that recovers', (t) async {
    final body = File('test/fixtures/region_repeater_cmh.json')
        .readAsStringSync();
    var fail = true;
    await t.pumpWidget(
      _app(
        MockClient((_) async {
          if (fail) throw const SocketException('down');
          return http.Response(body, 200);
        }),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Can\'t reach the server'), findsOneWidget);
    fail = false;
    await t.tap(find.byKey(const Key('repdetail-retry')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('repdetail-list')), findsOneWidget);
  });

  testWidgets('no position, no history, partial status', (t) async {
    tall(t);
    final body = jsonEncode({
      'status': {
        'state': 'partial',
        'reason': 'Observers offline.',
        'computedAt': '2026-10-24T01:00:00Z',
        'source': 'x',
      },
      'row': {
        'key': _key,
        'hashPrefix': 'da5d',
        'name': null,
        'role': 'room',
        'lat': null,
        'lon': null,
        'status': 'quiet',
      },
      'neighbours': [],
      'heatmap': null,
      'snrHourly': [],
      'observers': [],
    });
    await t.pumpWidget(_app(MockClient((_) async => http.Response(body, 200))));
    await t.pumpAndSettle();
    expect(find.text('Repeater da5d'), findsWidgets);
    expect(
      find.textContaining('Partial data. Observers offline.'),
      findsOneWidget,
    );
    expect(
      find.text('This repeater has not reported a position.'),
      findsOneWidget,
    );
    expect(
      find.text('No packet history for this repeater yet.'),
      findsOneWidget,
    );
    expect(find.text('No neighbours known.'), findsOneWidget);
    expect(find.text('Last heard: unknown'), findsOneWidget);
    expect(find.text('Room server'), findsOneWidget);
  });

  testWidgets('openRepeaterDetail pushes the screen', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => openRepeaterDetail(
              c,
              baseUrl: 'http://127.0.0.1:1',
              regionSlug: 'cmh',
              repeaterKey: 'bad',
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Invalid repeater key'), findsOneWidget);
  });
}
