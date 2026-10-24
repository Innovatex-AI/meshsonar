import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_packets_api.dart';
import 'package:meshsonar/ui/region/packets_panel.dart';
import 'package:meshsonar/ui/theme.dart';

PacketRow row(String h, DateTime at, {int type = 5, int route = 1, double? snr = 6, int hops = 2, int obs = 2}) =>
    PacketRow(hash: h, type: type, route: route, firstAt: at, observers: obs, minHops: hops, bestSnrDb: snr);

class FakeApi implements RegionPacketsApi {
  final List<Object> script; // PacketPage or PacketsException, consumed in order, last repeats
  final calls = <int?>[];
  FakeApi(this.script);
  @override
  Future<PacketPage> packets({int limit = 50, int? route, int? type, String? cursor}) async {
    calls.add(route);
    final i = calls.length - 1 < script.length ? calls.length - 1 : script.length - 1;
    final s = script[i];
    if (s is PacketsException) throw s;
    return s as PacketPage;
  }
}

PacketPage page(List<PacketRow> rows, [PacketsStatus st = const PacketsStatus(SourcedState.ready, null)]) =>
    PacketPage(status: st, rows: rows);

Widget host(FakeApi api, {Duration poll = const Duration(seconds: 10), bool visible = true, DateTime Function()? clock}) => MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      home: Scaffold(
        body: TickerMode(
          enabled: visible,
          child: PacketsPanel(baseUrl: Uri.parse('https://cmh.meshsonar.com'), regionSlug: 'cmh', api: api, pollEvery: poll, clock: clock),
        ),
      ),
    );

void main() {
  final now = DateTime.now().toUtc();

  testWidgets('shows rows with type, route, hops, observers and SNR', (t) async {
    final api = FakeApi([page([row('a1', now.subtract(const Duration(seconds: 30)), type: 4, route: 2, hops: 0, snr: -3.5, obs: 1)])]);
    await t.pumpWidget(host(api, clock: () => now)); // fixed clock: the age was '31s' on a slow run
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    expect(find.text('Advert'), findsOneWidget);
    expect(find.textContaining('Direct · direct · 1 observer'), findsOneWidget);
    expect(find.text('-3.5 dB'), findsOneWidget);
    expect(find.text('30s'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('empty (pending) state shows the server reason', (t) async {
    final api = FakeApi([page(const [], const PacketsStatus(SourcedState.pending, 'No trusted observers in this region yet.'))]);
    await t.pumpWidget(host(api));
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    expect(find.byKey(const Key('packets-empty')), findsOneWidget);
    expect(find.text('No trusted observers in this region yet.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('first load error shows error state; pull-to-refresh recovers', (t) async {
    final api = FakeApi([const PacketsException('network error: down'), page([row('a1', now)])]);
    await t.pumpWidget(host(api));
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    expect(find.byKey(const Key('packets-error')), findsOneWidget);
    await t.fling(find.byKey(const Key('packets-error')), const Offset(0, 400), 1000);
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('packets-list')), findsOneWidget);
    expect(api.calls.length, 2);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('live mode polls every 10 s, keeps rows on failure, shows busy and reconnecting', (t) async {
    final api = FakeApi([
      page([row('a1', now)]),
      const PacketsException('busy', status: 429, busy: true),
      const PacketsException('network error'),
      page([row('a1', now), row('b2', now.add(const Duration(seconds: 5)), type: 0)]),
    ]);
    await t.pumpWidget(host(api));
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    expect(api.calls.length, 1);
    await t.pump(const Duration(seconds: 10));
    await t.pump();
    expect(api.calls.length, 2);
    expect(find.text('Server busy, retrying shortly.'), findsOneWidget);
    expect(find.text('Anonymous request'), findsNothing);
    expect(find.text('Group text'), findsOneWidget); // old rows kept
    await t.pump(const Duration(seconds: 10));
    await t.pump();
    expect(find.textContaining('Reconnecting'), findsOneWidget);
    await t.pump(const Duration(seconds: 10));
    await t.pump();
    expect(find.byKey(const Key('packets-banner')), findsNothing);
    expect(find.text('Request'), findsOneWidget); // new row merged
    expect(find.text('Group text'), findsOneWidget); // deduped, not doubled
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('does not poll when paused or when hidden', (t) async {
    final api = FakeApi([page([row('a1', now)])]);
    await t.pumpWidget(host(api));
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    await t.tap(find.byKey(const Key('packets-live-switch')));
    await t.pump();
    final n = api.calls.length;
    await t.pump(const Duration(seconds: 35));
    expect(api.calls.length, n);
    await t.pumpWidget(const SizedBox());

    final api2 = FakeApi([page([row('a1', now)])]);
    await t.pumpWidget(host(api2, visible: false));
    await t.pump(const Duration(seconds: 35));
    expect(api2.calls.length, 1); // only the initial load
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('route chip refetches with the route filter', (t) async {
    final api = FakeApi([page([row('a1', now)])]);
    await t.pumpWidget(host(api));
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    await t.tap(find.byKey(const Key('packets-route-2')));
    await t.pumpAndSettle(const Duration(milliseconds: 1));
    expect(api.calls.last, 2);
    await t.pumpWidget(const SizedBox());
  });

  test('packetAge', () {
    final n = DateTime.utc(2026, 1, 1, 12);
    expect(packetAge(n.subtract(const Duration(minutes: 5)), n), '5m');
    expect(packetAge(n.subtract(const Duration(hours: 3)), n), '3h');
    expect(packetAge(n.add(const Duration(seconds: 2)), n), 'now');
  });
}
