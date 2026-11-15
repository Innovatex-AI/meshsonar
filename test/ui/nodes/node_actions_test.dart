// The one node object and its action set (release 0.38, plan 4.5 item 2): the matrix per kind x key x position x radio x
// host, the privacy rule for hidden positions, and the dispatch to the Plan tab (also from a sheet on the root navigator,
// which is not under the shell).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/model.dart' show RepeaterKind, RepeaterRef;
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/nodes/node_actions.dart';
import 'package:meshsonar/ui/nodes/node_ref.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';
import 'package:meshsonar/ui/tools/contact_ref.dart';

import '../../chat/contact_support.dart';

final _key = List.filled(32, 'ab').join();

NodeRef node(NodeKind kind, {String? key, String name = 'Hilltop', double? lat = 40.1, double? lon = -83.2, bool hidden = false}) =>
    NodeRef(key: key ?? _key, name: name, kind: kind, lat: lat, lon: lon, source: NodeSource.network, positionHidden: hidden);

List<NodeActionId> ids(NodeRef n, [NodeActionEnv env = const NodeActionEnv()]) => [for (final a in nodeActions(n, env)) a.id];

const _all = NodeActionEnv(radioConnected: true, canOpenPage: true, hostPing: true, claimAvailable: true);

void main() {
  group('matrix per kind (everything available)', () {
    const plan = [NodeActionId.planFrom, NodeActionId.addToPlan, NodeActionId.linkTo];
    test('repeater: the full set, in order', () {
      expect(ids(node(NodeKind.repeater), _all), [...plan, NodeActionId.ping, NodeActionId.openPage, NodeActionId.claim, NodeActionId.admin]);
    });
    test('room: no Claim (rooms are not claimed), Admin is "Administer room"', () {
      expect(ids(node(NodeKind.room), _all), [...plan, NodeActionId.ping, NodeActionId.openPage, NodeActionId.admin]);
      expect(nodeActions(node(NodeKind.room), _all).last.label, 'Administer room');
      expect(nodeActions(node(NodeKind.repeater), _all).last.label, 'Administer');
    });
    test('observer: plan actions only (no radio actions, no page, no claim)', () {
      expect(ids(node(NodeKind.observer), _all), plan);
    });
    test('person: Link to… and Ping, never Plan from here / Add to plan (a person moves)', () {
      expect(ids(node(NodeKind.companion), _all), [NodeActionId.linkTo, NodeActionId.ping]);
    });
    test('sensor: a site, plus Ping with the host ping', () {
      expect(ids(node(NodeKind.sensor), _all), [...plan, NodeActionId.ping]);
    });
  });

  group('availability', () {
    test('nothing from the host and no radio: plan actions, then dimmed Ping and Administer with the reasons', () {
      final a = nodeActions(node(NodeKind.repeater), const NodeActionEnv());
      expect([for (final x in a) x.id], [NodeActionId.planFrom, NodeActionId.addToPlan, NodeActionId.linkTo, NodeActionId.ping, NodeActionId.admin]);
      final ping = a.firstWhere((x) => x.id == NodeActionId.ping);
      final admin = a.firstWhere((x) => x.id == NodeActionId.admin);
      expect(ping.enabled, isFalse);
      expect(ping.reason, kNeedRadioReason);
      expect(admin.enabled, isFalse);
      expect(admin.reason, kNeedRadioAdminReason);
      for (final x in a.where((x) => x.id.index <= NodeActionId.linkTo.index)) {
        expect(x.enabled, isTrue, reason: '${x.id} needs no radio');
      }
    });
    test('a radio that cannot administer: Administer dimmed with that reason, Ping works', () {
      final a = nodeActions(node(NodeKind.repeater), const NodeActionEnv(radioConnected: true, adminBlockedReason: 'Simulator cannot.'));
      expect(a.firstWhere((x) => x.id == NodeActionId.admin).reason, 'Simulator cannot.');
      expect(a.firstWhere((x) => x.id == NodeActionId.ping).enabled, isTrue);
    });
    test('person and sensor have no Ping without the host ping (Trace targets repeaters and rooms)', () {
      expect(ids(node(NodeKind.companion), const NodeActionEnv(radioConnected: true)), [NodeActionId.linkTo]);
      expect(ids(node(NodeKind.sensor), const NodeActionEnv(radioConnected: true)), isNot(contains(NodeActionId.ping)));
    });
    test('Claim only with claims available', () {
      expect(ids(node(NodeKind.repeater), const NodeActionEnv()), isNot(contains(NodeActionId.claim)));
      expect(ids(node(NodeKind.repeater), const NodeActionEnv(claimAvailable: true)), contains(NodeActionId.claim));
    });
    test('a short drive hash (no full key): plan actions only; no Ping, Claim, Admin', () {
      expect(ids(node(NodeKind.repeater, key: 'ab12'), _all), [NodeActionId.planFrom, NodeActionId.addToPlan, NodeActionId.linkTo, NodeActionId.openPage]);
    });
    test('every action has a distinct widget key', () {
      final a = nodeActions(node(NodeKind.repeater), _all);
      expect({for (final x in a) x.widgetKey}.length, a.length);
      expect(a.first.widgetKey, const Key('node-action-planFrom'));
    });
  });

  group('hidden positions never offer plan actions', () {
    const plan = {NodeActionId.planFrom, NodeActionId.addToPlan, NodeActionId.linkTo};
    for (final kind in NodeKind.values) {
      test('${kind.name}: U+1F6AB in the name', () {
        final n = node(kind, name: 'Hilltop $kNoPositionMark');
        expect(n.planSeed, isNull);
        expect(ids(n, _all).toSet().intersection(plan), isEmpty);
      });
      test('${kind.name}: the source says not public', () {
        final n = node(kind, hidden: true);
        expect(n.planSeed, isNull);
        expect(ids(n, _all).toSet().intersection(plan), isEmpty);
      });
      test('${kind.name}: no position, or (0, 0), or off the globe', () {
        for (final n in [node(kind, lat: null, lon: null), node(kind, lat: 0, lon: 0), node(kind, lat: 95, lon: 0), node(kind, lat: double.nan, lon: 1)]) {
          expect(n.planSeed, isNull);
          expect(ids(n, _all).toSet().intersection(plan), isEmpty);
        }
      });
    }
    test('the non-plan actions stay (a hidden repeater can still be pinged and administered)', () {
      expect(ids(node(NodeKind.repeater, hidden: true), _all), [NodeActionId.ping, NodeActionId.openPage, NodeActionId.claim, NodeActionId.admin]);
    });
    test('a contact whose advertised name carries the mark is hidden even with a custom name', () {
      final c = radioContact(3, type: ContactType.repeater, name: 'Tower $kNoPositionMark').copyWith(customName: 'My tower');
      final n = NodeRef.fromContact(c);
      expect(n.name, 'My tower');
      expect(n.positionPublic, isFalse);
    });
  });

  group('NodeRef', () {
    test('a public node seeds the plan with key, name, spot and source word', () {
      final s = node(NodeKind.repeater).planSeed!;
      expect(s, PlanNodeSeed(key: _key, name: 'Hilltop', lat: 40.1, lon: -83.2, source: 'repeater'));
      expect(NodeRef(key: 'ab12', name: 'x', kind: NodeKind.repeater, lat: 1, lon: 1, source: NodeSource.drive).planSeed!.key, isNull,
          reason: 'a short hash is not a key');
      expect(NodeRef(key: _key, name: 'o', kind: NodeKind.observer, lat: 1, lon: 1, source: NodeSource.observer).planSeed!.source, 'observer');
    });
    test('from a contact and from a drive repeater', () {
      final c = radioContact(2, type: ContactType.room);
      final n = NodeRef.fromContact(c);
      expect((n.kind, n.key, n.source, n.lat), (NodeKind.room, c.publicKey, NodeSource.contact, c.lat));
      final r = NodeRef.fromRepeaterRef(RepeaterRef(key: _key.toUpperCase(), name: 'Hill', lat: 1, lon: 2, kind: RepeaterKind.room));
      expect((r.kind, r.key, r.source), (NodeKind.room, _key, NodeSource.drive));
    });
    test('ContactRef is a thin adapter: the tools read the node', () {
      final c = radioContact(4, type: ContactType.repeater);
      final ref = ContactRef.of(c);
      expect(ref.node, NodeRef.fromContact(c));
      expect((ref.keyHex, ref.name, ref.type, ref.lat, ref.lon), (c.publicKey, c.displayName, 2, c.lat, c.lon));
      final m = ContactRef.fromNode(node(NodeKind.room));
      expect(m.type, 3);
      expect(ContactRef(keyHex: 'AB', name: 'n', type: 1).node.kind, NodeKind.companion);
    });
  });

  group('dispatch', () {
    Future<ShellController> host(WidgetTester tester, Widget Function(BuildContext) sheetBody) async {
      final shell = ShellController(initial: AppTab.drive);
      await tester.pumpWidget(MaterialApp(
        home: ShellScope(
          controller: shell,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('open'),
                onPressed: () => showAppSheet<void>(context, builder: (ctx, c) => ListView(controller: c, children: [sheetBody(ctx)])),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      return shell;
    }

    for (final (id, kind) in [
      (NodeActionId.planFrom, PlanRequestKind.planFrom),
      (NodeActionId.addToPlan, PlanRequestKind.addNode),
      (NodeActionId.linkTo, PlanRequestKind.linkTo),
    ]) {
      testWidgets('${id.name} from a sheet on the root navigator: the sheet closes, the Plan tab gets ${kind.name}', (tester) async {
        final shell = await host(tester, (_) => NodeActionBar(node: node(NodeKind.repeater), env: const NodeActionEnv()));
        expect(find.byKey(const Key('node-actions')), findsOneWidget);
        await tester.tap(find.byKey(Key('node-action-${id.name}')));
        await tester.pumpAndSettle();
        expect(shell.tab, AppTab.plan);
        final r = shell.takePendingPlan()!;
        expect(r.kind, kind);
        expect(r.node, node(NodeKind.repeater).planSeed);
        expect(find.byKey(const Key('node-actions')), findsNothing, reason: 'the sheet is closed so the planner shows');
      });
    }

    testWidgets('a dimmed action says why and does nothing else', (tester) async {
      final shell = await host(tester, (_) => NodeActionBar(node: node(NodeKind.repeater), env: const NodeActionEnv()));
      expect(find.text(kNeedRadioReason), findsOneWidget, reason: 'the first reason is written under the bar');
      await tester.tap(find.byKey(const Key('node-action-admin')));
      await tester.pump();
      expect(find.text(kNeedRadioAdminReason), findsOneWidget);
      expect(shell.pendingPlan, isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Open page calls the host; a hidden node shows no plan buttons', (tester) async {
      var opened = 0;
      await host(
        tester,
        (_) => Column(children: [
          NodeActionBar(node: node(NodeKind.repeater, hidden: true), onOpenPage: () => opened++, env: const NodeActionEnv(canOpenPage: true)),
        ]),
      );
      expect(find.byKey(const Key('node-action-planFrom')), findsNothing);
      expect(find.byKey(const Key('node-action-linkTo')), findsNothing);
      await tester.tap(find.byKey(const Key('node-action-openPage')));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('buttons are at least the platform target and labelled for VoiceOver', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: NodeActionBar(node: node(NodeKind.room), env: const NodeActionEnv()))));
      for (final id in [NodeActionId.planFrom, NodeActionId.addToPlan, NodeActionId.linkTo, NodeActionId.ping, NodeActionId.admin]) {
        expect(tester.getSize(find.byKey(Key('node-action-${id.name}'))).height, greaterThanOrEqualTo(44), reason: id.name);
      }
      expect(find.bySemanticsLabel(RegExp(r'^Administer room, unavailable\. Connect your radio')), findsOneWidget);
      expect(find.bySemanticsLabel('Link to…'), findsOneWidget);
    });

    testWidgets('no shell (an isolated screen): the person is told, nothing breaks', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: NodeActionBar(node: node(NodeKind.repeater), env: const NodeActionEnv()))));
      await tester.tap(find.byKey(const Key('node-action-linkTo')));
      await tester.pump();
      expect(find.text('The planner is not available here.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
