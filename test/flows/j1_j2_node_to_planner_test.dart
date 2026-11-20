// J1 and J2 (plan 4.5 item 5): a repeater, a room or a contact anywhere in the app reaches the planner through the one node
// action bar (NodeActionBar -> ShellController.openPlan), and the planner opens in the right mode with the node in it.
// Run against the real app: the bar is on a screen of the root navigator (where repeater sheets and contact profiles live),
// the Plan tab is built, and what the planner shows afterwards is read.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/nodes/node_actions.dart';
import 'package:meshsonar/ui/nodes/node_ref.dart';
import 'package:meshsonar/ui/plan/plan_modes.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import 'flow_kit.dart';

final _key = 'aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44';
const _noRadio = NodeActionEnv();

NodeRef _repeater({String name = 'North Ridge', bool hidden = false}) =>
    NodeRef(key: _key, name: name, kind: NodeKind.repeater, lat: 40.2, lon: -82.95, source: NodeSource.network, positionHidden: hidden);

void main() {
  group('J1 repeater anywhere', () {
    testWidgets('Plan from here: the bar sends planFrom with the node, closes the sheet and the planner opens a plan from it in Coverage', (tester) async {
      phone(tester);
      final h = Harness();
      h.client.planVerifyResult = flowVerify;
      final st = await openPlanner(tester, h);
      final shell = shellOf(tester);
      await tapShellTab(tester, 'Chat');
      expect(shell.tab, AppTab.chat);

      await pushOnRoot(tester, NodeActionBar(node: _repeater(), env: _noRadio));
      expect(find.byKey(const Key('node-action-planFrom')), findsOneWidget);
      final before = st.controller!.plan.id;
      await tapKey(tester, 'node-action-planFrom');
      await settle(tester);

      expect(find.byKey(const Key('node-actions')), findsNothing, reason: 'the screen above the tabs closed so the planner shows');
      expect(shell.tab, AppTab.plan);
      expect(shell.pendingPlan, isNull, reason: 'the Plan tab took the request');
      expect(st.controller!.plan.id, isNot(before), reason: 'Plan from here starts a new plan');
      expect(st.controller!.plan.name, 'From North Ridge');
      final n = st.controller!.nodes.single;
      expect(n.existingKey, _key);
      expect(n.status, PlanNodeStatus.existing);
      expect(n.lat, 40.2);
      expect(st.mode, PlanModeId.coverage);
      expect(h.client.planVerifyAsks, isNotEmpty, reason: 'and runs its coverage');
      await finish(tester);
    });

    testWidgets('Add to plan joins the open plan and keeps the mode; Link to… opens Link with this node as an end', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final shell = shellOf(tester);
      final plan = st.controller!.plan.id;

      await pushOnRoot(tester, NodeActionBar(node: _repeater(), env: _noRadio));
      await tapKey(tester, 'node-action-addToPlan');
      await settle(tester);
      expect(shell.tab, AppTab.plan);
      expect(st.controller!.plan.id, plan, reason: 'Add to plan does not start a new plan');
      expect(st.controller!.nodes.single.existingKey, _key);

      await tapShellTab(tester, 'Chat');
      await pushOnRoot(tester, NodeActionBar(node: _repeater(name: 'South Hill').copyForTest(key: 'bb' * 32), env: _noRadio));
      await tapKey(tester, 'node-action-linkTo');
      await settle(tester);
      expect(shell.tab, AppTab.plan);
      expect(st.mode, PlanModeId.link);
      expect(st.controller!.nodes.map((n) => n.name), ['North Ridge', 'South Hill']);
      await finish(tester);
    });

    testWidgets('a repeater whose position is hidden offers no plan action at all (the actions would carry the coordinates)', (tester) async {
      phone(tester);
      final h = Harness();
      await openPlanner(tester, h);
      await pushOnRoot(tester, NodeActionBar(node: _repeater(name: 'Private \u{1F6AB}', hidden: true), env: _noRadio));
      for (final id in ['planFrom', 'addToPlan', 'linkTo']) {
        expect(find.byKey(Key('node-action-$id')), findsNothing);
      }
      await finish(tester);
    });
  });

  group('J2 contact', () {
    testWidgets('Link to… from a contact: Link opens with the person as a handheld end, never Plan from here', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final shell = shellOf(tester);
      await tapShellTab(tester, 'Chat');
      final contact = Contact(radioId: 'r1', publicKey: 'cc' * 32, type: ContactType.companion, name: 'Alex', lat: 40.15, lon: -82.91);
      await pushOnRoot(tester, NodeActionBar(node: NodeRef.fromContact(contact), env: _noRadio));
      expect(find.byKey(const Key('node-action-planFrom')), findsNothing, reason: 'a person moves: no site actions');
      expect(find.byKey(const Key('node-action-addToPlan')), findsNothing);
      await tapKey(tester, 'node-action-linkTo');
      await settle(tester);
      expect(shell.tab, AppTab.plan);
      expect(st.mode, PlanModeId.link);
      final n = st.controller!.nodes.single;
      expect(n.name, 'Alex');
      expect(n.role, PlanNodeRole.handheld);
      expect(n.lat, 40.15);
      await finish(tester);
    });

    testWidgets('Link to… from a repeater contact (Chat > Radio): the repeater joins as an existing repeater, not a handheld', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await tapShellTab(tester, 'Chat');
      final contact = Contact(radioId: 'r1', publicKey: 'dd' * 32, type: ContactType.repeater, name: 'Otterbein Hill', lat: 40.12, lon: -82.93);
      await pushOnRoot(tester, NodeActionBar(node: NodeRef.fromContact(contact), env: _noRadio));
      await tapKey(tester, 'node-action-linkTo');
      await settle(tester);
      expect(st.mode, PlanModeId.link);
      final n = st.controller!.nodes.single;
      expect(n.name, 'Otterbein Hill');
      expect(n.role, PlanNodeRole.repeater);
      expect(n.status, PlanNodeStatus.existing);
      expect(n.existingKey, 'dd' * 32);
      await finish(tester);
    });

    testWidgets('a contact with no position (0, 0) offers no Link to…', (tester) async {
      phone(tester);
      final h = Harness();
      await openPlanner(tester, h);
      final contact = Contact(radioId: 'r1', publicKey: 'cc' * 32, type: ContactType.companion, name: 'Alex', lat: 0, lon: 0);
      await pushOnRoot(tester, NodeActionBar(node: NodeRef.fromContact(contact), env: _noRadio));
      expect(find.byKey(const Key('node-action-linkTo')), findsNothing);
      await finish(tester);
    });
  });
}

extension on NodeRef {
  NodeRef copyForTest({required String key}) => NodeRef(key: key, name: name, kind: kind, lat: lat! + 0.05, lon: lon! + 0.03, source: source);
}
