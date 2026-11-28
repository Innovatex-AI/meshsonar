// Round 2 N-U1, N-U5, N-V1 (build 77): "Who heard it" grouped by observer, every hop of a copy's route in plain words
// (known, likely, shared ID, unknown), "Replay on map" and "Work out the likely route" per copy, the copies past the
// first 50 fetched per observer; the hop's own position (the defect at packet_models.dart PacketHop.position); one
// name for a private channel; signal numbers with two decimals at most.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/v1/channels_api.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/ui/network/packets/packet_ui.dart';
import 'package:meshsonar/ui/network/packets/who_heard.dart';
import 'package:meshsonar/ui/theme.dart';

const ob2 = PacketObserver(id: 'ob2', name: 'INNO-OB-2');
const ob3 = PacketObserver(id: 'ob3', name: 'Clintonville', kind: 'phone');

PacketObservation copy(String id, PacketObserver o, int sec, {double? snr, String? pathId, List<String> path = const []}) =>
    PacketObservation(id: id, observer: o, at: DateTime.utc(2026, 11, 25, 23, 13, sec), snr: snr, pathId: pathId, path: path);

const hilltop = PacketNode(key: 'aa11', name: 'Hilltop RPT', role: 'repeater');
const north = PacketNode(key: 'bb22', name: 'North Tower', role: 'repeater');
final path = PacketPath(id: 'p1', observationIds: const ['c1'], hops: [
  const PacketHop(index: 0, prefix: 'aa', confidence: HopConfidence.unique, node: hilltop),
  const PacketHop(index: 1, prefix: 'bb', confidence: HopConfidence.likely, node: north, score: 0.8),
  const PacketHop(index: 2, prefix: '5e', confidence: HopConfidence.ambiguous, candidatesTotal: 3, candidates: [
    HopCandidate(node: PacketNode(key: '5e01', name: 'East A'), score: 0.4),
    HopCandidate(node: PacketNode(key: '5e02', name: 'East B'), score: 0.3),
  ]),
  const PacketHop(index: 3, prefix: '7c', confidence: HopConfidence.unknown),
]);

void main() {
  test('groupByObserver: one entry per observer in first-seen order, copies oldest first, best signal', () {
    final g = groupByObserver([copy('c3', ob2, 9, snr: 2), copy('c1', ob2, 1, snr: 11.8), copy('c2', ob3, 5, snr: -6.8), copy('c4', ob2, 4)]);
    expect([for (final x in g) x.observer.id], ['ob2', 'ob3']);
    expect([for (final c in g.first.copies) c.id], ['c1', 'c4', 'c3']);
    expect(g.first.bestSnr, 11.8);
    expect(g.first.first, DateTime.utc(2026, 11, 25, 23, 13, 1));
    expect(WhoHeard.heading(9, 3), 'Heard 9 times by 3 observers');
    expect(WhoHeard.heading(1, 1), 'Heard 1 time by 1 observer');
  });

  test('copyRoute: Sender › every hop in words › this observer, never shortened', () {
    final steps = copyRoute(copy('c1', ob2, 1, pathId: 'p1', path: const ['aa', 'bb', '5e', '7c']), paths: [path], origin: const PacketNode(key: 'k', name: 'Kestrel-07'));
    expect([for (final s in steps) s.text], [
      'Kestrel-07',
      'Hilltop RPT (aa)',
      'North Tower (likely, 80%)',
      '5e · one of 3 repeaters',
      '7c · unknown repeater',
      'INNO-OB-2',
    ]);
    expect([for (final s in steps) s.kind], [RouteStepKind.sender, RouteStepKind.known, RouteStepKind.likely, RouteStepKind.shared, RouteStepKind.unknown, RouteStepKind.observer]);
    // No resolved path for the copy: every code, each "not named"; a long route is never cut to "after N hops".
    final raw = copyRoute(copy('c9', ob3, 2, pathId: 'raw:1:x', path: [for (var i = 0; i < 12; i++) 'c$i']));
    expect(raw.length, 14);
    expect(raw[1].text, 'c0 · not named');
    expect(raw[12].text, 'c11 · not named');
    expect(raw.first.text, 'Sender');
    expect(raw.where((s) => s.unsure), hasLength(12));
  });

  testWidgets('the widget: one row per observer; a tap shows its copies with Replay on map and Work out the likely route', (t) async {
    t.view.physicalSize = const Size(375, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final replayed = <String>[], inspected = <String>[], shared = <String>[];
    final fetched = <String>[];
    await t.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: WhoHeard(
            hash: 'c4b06ee8fc39b187',
            observations: [copy('c1', ob2, 1, snr: 11.800000190734863, pathId: 'p1', path: const ['aa', 'bb', '5e', '7c']), copy('c2', ob2, 3, snr: 1.75), copy('c3', ob3, 2, snr: -6.8)],
            paths: [path],
            observationCount: 60,
            observerCount: 2,
            moreOnServer: true,
            fetchObserver: (id) async {
              fetched.add(id);
              return [for (var i = 0; i < 4; i++) copy('f$i', ob2, 10 + i)];
            },
            onReplay: (o) => replayed.add(o.id),
            onInspectRoute: (o) => inspected.add(o.id),
            onSharedId: shared.add,
          ),
        ),
      ),
    ));
    expect(find.text('Heard 60 times by 2 observers'), findsOneWidget);
    expect(find.byKey(const ValueKey('packet-observer-row-ob2')), findsOneWidget);
    expect(find.byKey(const ValueKey('packet-observer-row-ob3')), findsOneWidget);
    expect(find.text('11.8 dB'), findsOneWidget, reason: 'best signal, two decimals at most (N-V1)');
    expect(find.textContaining('heard 2 times or more'), findsOneWidget, reason: 'more copies may wait on the server');
    expect(find.byKey(const ValueKey('packet-obs-c1')), findsNothing, reason: 'closed until tapped');

    await t.tap(find.byKey(const ValueKey('packet-observer-row-ob2')));
    await t.pumpAndSettle();
    expect(fetched, ['ob2'], reason: 'copies past the first 50 are fetched for that observer');
    expect(find.textContaining('heard 6 times'), findsOneWidget, reason: 'the fetched copies join the loaded ones');
    expect(find.byKey(const ValueKey('packet-obs-route-c1')), findsOneWidget);
    expect(find.text('North Tower (likely, 80%)'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('packet-obs-replay-c1')));
    expect(replayed, ['c1']);
    await t.tap(find.byKey(const ValueKey('packet-obs-inspect-c1')));
    expect(inspected, ['c1']);
    // A shared ID is one tap from its candidates and the Prefix Tool.
    await t.tap(find.byKey(const ValueKey('packet-hop-shared-c1-2')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('hop-candidates-sheet')), findsOneWidget);
    expect(find.text('East A'), findsOneWidget);
    expect(find.text('and 1 more'), findsOneWidget);
    await t.tap(find.byKey(const Key('hop-see-shares')));
    await t.pumpAndSettle();
    expect(shared, ['5e']);
    expect(t.getSize(find.byKey(const ValueKey('packet-obs-replay-c1'))).height, greaterThanOrEqualTo(44));
    expect(t.takeException(), isNull);
  });

  test('N-V1: signal numbers keep two decimals at most, trailing zeros trimmed', () {
    expect(snrText(11.800000190734863), '11.8 dB');
    expect(snrText(1.7999999523162842), '1.8 dB');
    expect(snrText(-6.800000190734863), '-6.8 dB');
    expect(snrText(1.75), '1.75 dB');
    expect(snrText(10), '10 dB');
    expect(snrText(-0.001), '0 dB');
    expect(snrText(null), 'no reading');
  });

  test('defect fixed: a resolved hop is placed at its own position even with no candidates', () {
    final h = PacketHop.tryParse({
      'index': 0,
      'prefix': 'aa',
      'confidence': 'unique',
      'node': {'key': 'aa11', 'name': 'Hilltop RPT', 'role': 'repeater'},
      'position': {'lat': 40.1, 'lon': -83.0},
      'candidates': [],
    })!;
    expect(h.position?.lat, 40.1);
    expect(h.position?.lon, -83.0);
    // An unresolved hop is never placed, whatever it carries.
    final u = PacketHop.tryParse({'index': 1, 'prefix': '5e', 'confidence': 'ambiguous', 'position': {'lat': 1, 'lon': 2}})!;
    expect(u.position, isNull);
  });

  test('N-U5: a private channel is "Private channel" everywhere; its ID only where it is needed', () {
    const c = PacketChannel(id: 'enc:96', kind: 'unknown');
    expect(c.label, 'Private channel');
    expect(c.isPrivate, isTrue);
    expect(c.privateId, '96');
    final row = PacketListRow(
        hash: 'h', firstSeen: DateTime.utc(2026), lastSeen: DateTime.utc(2026), type: 5, typeName: 'GRP_TXT', route: 'FLOOD',
        summary: 'Channel message (channel 96, no key)', channel: c);
    expect(row.title, 'Private channel message', reason: "an older server's line is replaced");
    const ch = ChannelRow(id: 'enc:96', kind: 'unknown', hashByte: '96', decodable: false);
    expect(ch.label, 'Private channel');
    expect(ch.privateId, '96');
    const pub = ChannelRow(id: 'public', name: 'Public', kind: 'public', hashByte: '11', decodable: true);
    expect(pub.privateId, isNull);
  });

  test('N-V5: dotJoin ties each separator to the part before it', () {
    expect(dotJoin(['Repeater', '', 'Active', 'heard 5 min ago']), 'Repeater · Active · heard 5 min ago');
  });
}
