// Save / share / export / deep links (release 0.38 A11): the share sheet (position warning, 1 km rounding, copy / share
// link, exports), paste import (links, codes, Plan JSON, MeshCore contacts), the saved-plans sheet (open, rename,
// duplicate, delete) and plan links arriving from outside (`meshsonar://plan#<code>`, `https://meshsonar.com/share/plan#`).
import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_codec.dart';
import 'package:meshsonar/core/plan/plan_export.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;
import 'package:meshsonar/core/plan/plan_repository.dart';
import 'package:meshsonar/core/plan/saved_plans.dart';
import 'package:meshsonar/core/plan_contract.dart' show PlanPoint;
import 'package:meshsonar/ui/plan/plan_share.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/plan/saved_plans.dart';

import '../fakes.dart';
import '../shell_test.dart' show phone, drain;
import 'planner_test.dart' show openPlanner, settle, tapIn;

final _t = DateTime.utc(2026, 11, 1);

Plan _shared() => Plan(
      id: 'p_shared',
      name: 'Club plan',
      nodes: const [PlanNode(id: 'n1', name: 'Tower', lat: 40.2, lon: -82.9), PlanNode(id: 'n2', name: 'Mine', lat: 40.1234, lon: -82.8765, mine: true)],
      createdAt: _t,
    );

String _contacts() => jsonEncode({
      'aa' * 32: {'type': 2, 'adv_name': 'Ridge Rpt', 'adv_lat': 40.13, 'adv_lon': -82.95},
      'bb' * 32: {'type': 2, 'adv_name': 'Far Rpt', 'adv_lat': 41.5, 'adv_lon': -82.0},
      'cc' * 32: {'type': 1, 'adv_name': 'No fix', 'adv_lat': 0, 'adv_lon': 0},
    });

class _BrokenRepo implements PlanRepository {
  bool broken = true;
  @override
  Future<List<String>> ids() async => broken ? throw const FileSystemException('locked') : const [];
  @override
  Future<String?> read(String id) async => null;
  @override
  Future<void> write(String id, String json) async {}
  @override
  Future<void> delete(String id) async {}
}

Future<void> openMenu(WidgetTester tester, String key) async {
  await tapIn(tester, find.byKey(const Key('plan-menu')));
  await settle(tester);
  await tapIn(tester, find.byKey(Key(key)));
  await settle(tester);
}

/// Scrolls the open sheet until [f] is built and on screen, then taps it.
Future<void> tapSheet(WidgetTester tester, Finder f) async {
  await reveal(tester, f);
  await tapIn(tester, f);
}

/// Moves the open sheet's list (no drag gesture, which the sheet would take) until [f] is built.
Future<void> reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    tester.state<ScrollableState>(find.byType(Scrollable).last).position.jumpTo(0);
    await tester.pump();
  }
  for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
    final pos = tester.state<ScrollableState>(find.byType(Scrollable).last).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 150).clamp(0, pos.maxScrollExtent).toDouble());
    await tester.pump();
  }
}

void main() {
  test('build 76: saved-plan times read today / yesterday / a date', () {
    final now = DateTime(2026, 11, 25, 15, 0);
    expect(savedWhen(DateTime(2026, 11, 25, 9, 5), now), 'today 09:05');
    expect(savedWhen(DateTime(2026, 11, 24, 23, 59), now), 'yesterday 23:59');
    expect(savedWhen(DateTime(2026, 11, 20, 8, 0), now), '2026-11-20');
  });

  tearDown(PlanShareSeams.reset);

  group('readPlanPaste', () {
    final code = encodePlanShare(_shared()).code;

    test('a plan link anywhere in a message, both schemes, a bare code and #code', () {
      for (final text in [
        'Look at this: https://meshsonar.com/share/plan#$code.',
        'meshsonar://plan#$code',
        'http://meshsonar.com/share/plan#plan=$code',
        code,
        '#$code',
      ]) {
        final r = readPlanPaste(text);
        expect(r, isA<PlanPasteLink>(), reason: text);
        expect(decodePlanUri((r as PlanPasteLink).uri).name, 'Club plan', reason: text);
      }
    });

    test('a Plan JSON document opens as a plan; contacts JSON as nodes', () {
      final p = readPlanPaste(jsonEncode(_shared().toJson()));
      expect(decodePlanUri((p as PlanPasteLink).uri).nodes, hasLength(2));
      final n = readPlanPaste(_contacts());
      expect((n as PlanPasteNodes).nodes.nodes, hasLength(2));
    });

    test('everything else says what is wrong', () {
      String msg(String s) => (readPlanPaste(s) as PlanPasteError).message;
      expect(msg('  '), contains('first'));
      expect(msg('https://meshsonar.com/share/plan#${code.substring(0, 20)}'), contains('damaged'));
      expect(msg('https://meshsonar.com/share/plan'), contains('no plan'));
      expect(msg('https://example.com/x'), contains('not a MeshSonar plan link'));
      expect(msg('hello there'), contains('not a plan link'));
      expect(msg('{"a": '), contains('cut short'));
    });
  });

  group('share sheet', () {
    testWidgets('warns about the rounded positions; the link and files round them unless Exact positions is on', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'Home', lat: 40.123456, lon: -82.987654, mine: true, heightM: 20);
      c.addNode(name: 'Barn', lat: 40.2, lon: -82.9);
      final shared = <String>[];
      final files = <PlanExportFile>[];
      final copied = <String>[];
      PlanShareSeams.shareText = (t, _) async => shared.add(t);
      PlanShareSeams.shareFile = (f) async => files.add(f);
      PlanShareSeams.copy = (t) async => copied.add(t);
      await openMenu(tester, 'plan-menu-share');
      expect(find.byKey(const Key('plan-share')), findsOneWidget);
      expect(find.byKey(const Key('plan-share-warning')), findsOneWidget);
      expect(find.textContaining('1 position of your own or installed radios is rounded'), findsOneWidget);

      await tapIn(tester, find.byKey(const Key('plan-share-link')));
      expect(shared, hasLength(1));
      final got = decodePlanUri(Uri.parse(shared.single));
      final home = got.nodes.firstWhere((n) => n.name == 'Home');
      expect(home.lat, 40.12);
      expect(home.approximate, isTrue);
      expect(home.mine, isFalse, reason: 'the mine flag never travels');

      await tapSheet(tester, find.byKey(const Key('plan-export-kml')));
      expect(files.single.fileName, endsWith('.kml'));
      expect(files.single.content, contains('<coordinates>-82.99,40.12,20.0</coordinates>'));

      await tapSheet(tester, find.byKey(const Key('plan-share-exact')));
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('plan-share-exact'))).value, isTrue);
      expect(find.textContaining('Exact positions are on', skipOffstage: false), findsOneWidget);
      await tapIn(tester, find.byKey(const Key('plan-share-copy')));
      expect(decodePlanUri(Uri.parse(copied.single)).nodes.firstWhere((n) => n.name == 'Home').lat, 40.12346);
      await tapSheet(tester, find.byKey(const Key('plan-export-geojson')));
      expect(jsonDecode(files.last.content)['features'][0]['geometry']['coordinates'], [-82.98765, 40.12346]);

      await tapSheet(tester, find.byKey(const Key('plan-export-cli')));
      expect(files.last.fileName, endsWith('-setup.txt'));
      expect(files.last.content, contains('set lat 40.123456'));
      expect(files.last.content, contains('set name Home'));
      await drain(tester);
    });

    testWidgets('an empty plan has nothing to share; setup commands need a repeater of yours', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await openMenu(tester, 'plan-menu-share');
      expect(find.byKey(const Key('plan-share-empty')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const Key('plan-share')))).pop();
      await settle(tester);
      st.controller!.addNode(name: 'Theirs', lat: 40.2, lon: -82.9, status: PlanNodeStatus.existing, existingKey: 'ab' * 32);
      await openMenu(tester, 'plan-menu-share');
      expect(find.byKey(const Key('plan-share-warning')), findsNothing, reason: 'nothing sensitive');
      await reveal(tester, find.byKey(const Key('plan-export-cli')));
      final row = tester.widget<ListTile>(find.descendant(of: find.byKey(const Key('plan-export-cli')), matching: find.byType(ListTile)));
      expect(row.onTap, isNull);
      expect(find.textContaining('this plan has none'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a file that cannot be made says so', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'Barn', lat: 40.2, lon: -82.9);
      PlanShareSeams.shareFile = (f) async => throw StateError('disk full');
      await openMenu(tester, 'plan-menu-share');
      await tapSheet(tester, find.byKey(const Key('plan-export-geojson')));
      expect(find.textContaining('could not be made'), findsOneWidget);
      await drain(tester);
    });
  });

  group('import', () {
    testWidgets('a pasted meshsonar:// link opens the plan as a new saved plan', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      PlanShareSeams.paste = () async => 'meshsonar://plan#${encodePlanShare(_shared()).code}';
      await openMenu(tester, 'plan-menu-import');
      // Build 76: with an empty box the filled button is Paste.
      expect(find.byKey(const Key('plan-import-paste')), findsOneWidget);
      expect(tester.widget(find.byKey(const Key('plan-import-paste'))), isA<FilledButton>());
      expect(find.byKey(const Key('plan-import-clear')), findsNothing);
      await tapIn(tester, find.byKey(const Key('plan-import-paste')));
      await settle(tester);
      expect(st.controller!.plan.name, 'Club plan');
      expect(st.controller!.plan.id, isNot('p_shared'));
      expect(find.textContaining('Opened the shared plan'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a bad paste says why and stays open', (tester) async {
      phone(tester);
      final h = Harness();
      await openPlanner(tester, h);
      await openMenu(tester, 'plan-menu-import');
      await tester.enterText(find.byKey(const Key('plan-import-field')), 'https://example.com/nope');
      await tapIn(tester, find.byKey(const Key('plan-import-go')));
      expect(find.textContaining('not a MeshSonar plan link'), findsOneWidget);
      expect(find.byKey(const Key('plan-import')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('MeshCore contacts: previewed nearest first, the picked ones join the plan, one Undo removes them', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await openMenu(tester, 'plan-menu-import');
      await tester.enterText(find.byKey(const Key('plan-import-field')), _contacts());
      await tapIn(tester, find.byKey(const Key('plan-import-go')));
      expect(find.byKey(const Key('plan-import-preview')), findsOneWidget);
      expect(find.text('2 with a position; 1 without a position left out.'), findsOneWidget);
      expect(find.text('Add 2 to the plan'), findsOneWidget);
      await tapSheet(tester, find.byKey(const Key('plan-import-row-1')));
      expect(find.text('Add 1 to the plan'), findsOneWidget);
      await tapIn(tester, find.byKey(const Key('plan-import-add')));
      final nodes = st.controller!.nodes;
      expect(nodes, hasLength(1));
      expect(nodes.single.status, PlanNodeStatus.existing);
      expect(nodes.single.existingKey, isNotNull);
      expect(find.textContaining('Added 1 node'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(st.controller!.nodes, isEmpty);
      await drain(tester);
    });
  });

  group('saved plans', () {
    testWidgets('rename the open plan, duplicate it, open and delete another', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'Kept', lat: 40.0, lon: -83.0);
      final other = Plan(id: 'p_other', name: 'Other plan', createdAt: DateTime.utc(2026, 1, 1));
      await h.planRepository.write(other.id, jsonEncode(other.toJson()));
      await openMenu(tester, 'plan-menu-open');
      expect(find.byKey(Key('saved-plan-${c.plan.id}')), findsOneWidget);
      expect(find.byKey(const Key('saved-plan-p_other')), findsOneWidget);

      await tapIn(tester, find.byKey(Key('saved-plan-more-${c.plan.id}')));
      expect(find.byKey(Key('saved-plan-delete-${c.plan.id}')), findsNothing, reason: 'the open plan is not deleted from under the planner');
      await tapIn(tester, find.byKey(Key('saved-plan-rename-${c.plan.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('saved-plan-name-field')), 'Ridge plan');
      await tapIn(tester, find.byKey(const Key('saved-plan-name-save')));
      expect(c.plan.name, 'Ridge plan');
      expect(await h.planRepository.read(c.plan.id), contains('Ridge plan'));

      dismissAppToast(); // the "Renamed" toast sits over the bottom action sheet in a test
      await tester.pump();
      await tapIn(tester, find.byKey(Key('saved-plan-more-${c.plan.id}')));
      await tapIn(tester, find.byKey(Key('saved-plan-duplicate-${c.plan.id}')));
      await settle(tester);
      expect(await h.planRepository.ids(), hasLength(3));
      expect(find.text('Copy of Ridge plan', skipOffstage: false), findsOneWidget);

      dismissAppToast();
      await tester.pump();
      await tapIn(tester, find.byKey(const Key('saved-plan-more-p_other')));
      await tapIn(tester, find.byKey(const Key('saved-plan-delete-p_other')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('saved-plan-delete-confirm-p_other')));
      await settle(tester);
      expect(find.byKey(const Key('saved-plan-p_other')), findsNothing);
      expect(await h.planRepository.read('p_other'), isNull);

      final copyRow = find.ancestor(of: find.text('Copy of Ridge plan'), matching: find.byType(ListTile));
      await tapIn(tester, copyRow);
      await settle(tester);
      expect(c.plan.name, 'Copy of Ridge plan');
      expect(c.nodes.single.name, 'Kept');
      await drain(tester);
    });

    testWidgets('a plan store that cannot be read shows the error with a retry; then the empty state', (tester) async {
      phone(tester);
      final repo = _BrokenRepo();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (ctx) => SavedPlansSheet(saved: SavedPlans(repo), scroll: ScrollController()))),
      ));
      await settle(tester);
      expect(find.byKey(const Key('saved-plans-error')), findsOneWidget);
      repo.broken = false;
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(find.byKey(const Key('saved-plans-empty')), findsOneWidget);
    });

    testWidgets('Import from the saved-plans sheet opens the paste sheet', (tester) async {
      phone(tester);
      final h = Harness();
      await openPlanner(tester, h);
      await openMenu(tester, 'plan-menu-open');
      await tapIn(tester, find.byKey(const Key('saved-plans-import')));
      await settle(tester);
      expect(find.byKey(const Key('plan-import')), findsOneWidget);
      await drain(tester);
    });
  });

  group('deep links', () {
    for (final scheme in ['meshsonar://plan#', 'https://meshsonar.com/share/plan#']) {
      testWidgets('a link that reaches the app ($scheme) opens the plan', (tester) async {
        phone(tester);
        final h = Harness();
        final st = await openPlanner(tester, h);
        h.incomingLinks.add(Uri.parse('$scheme${encodePlanShare(_shared()).code}'));
        await settle(tester);
        await settle(tester);
        expect(st.controller!.plan.name, 'Club plan');
        expect(st.controller!.nodes.firstWhere((n) => n.name == 'Mine').approximate, isTrue);
        await drain(tester);
      });
    }
  });

  group('Dynamic Type', () {
    for (final scale in [1.0, 2.35]) {
      Future<void> start(WidgetTester tester) async {
        phone(tester, scale: scale, w: 390, h: 844);
      }

      testWidgets('the share sheet fits at ${scale}x', (tester) async {
        await start(tester);
        final st = await openPlanner(tester, Harness());
        st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 40.1, lon: -82.9, mine: true);
        unawaited(showPlanShare(tester.element(find.byType(PlannerScreen)), st.controller!.plan));
        await settle(tester);
        expect(find.byKey(const Key('plan-share')), findsOneWidget);
        await reveal(tester, find.byKey(const Key('plan-export-cli-copy')));
        expect(find.byKey(const Key('plan-export-cli-copy')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await drain(tester);
      });

      testWidgets('the import preview fits at ${scale}x', (tester) async {
        await start(tester);
        final st = await openPlanner(tester, Harness());
        unawaited(showPlanImport(tester.element(find.byType(PlannerScreen)), controller: st.controller!, near: const PlanPoint(40, -83)));
        await settle(tester);
        await reveal(tester, find.byKey(const Key('plan-import-field')));
        await tester.enterText(find.byKey(const Key('plan-import-field')), _contacts());
        await tapIn(tester, find.byKey(const Key('plan-import-go')));
        expect(find.byKey(const Key('plan-import-preview')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await drain(tester);
      });

      testWidgets('the saved-plans sheet fits at ${scale}x', (tester) async {
        await start(tester);
        final h = Harness();
        final st = await openPlanner(tester, h);
        st.controller!.addNode(name: 'Kept', lat: 40.0, lon: -83.0);
        st.controller!.rename('A long plan name for the north side of the county');
        unawaited(showSavedPlans(tester.element(find.byType(PlannerScreen)), saved: SavedPlans(h.planRepository), current: st.controller));
        await settle(tester);
        expect(find.byKey(const Key('saved-plans')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await drain(tester);
      });
    }
  });

  testWidgets('VoiceOver: the sheets have headers and every action a label', (tester) async {
    phone(tester);
    final h = Harness();
    final st = await openPlanner(tester, h);
    final sem = tester.ensureSemantics();
    st.controller!.addNode(name: 'Home', lat: 40.1, lon: -82.9, mine: true);
    await openMenu(tester, 'plan-menu-share');
    expect(find.bySemanticsLabel('Share the plan'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Share link')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Copy link')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Plan link'), skipOffstage: false), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Privacy'), skipOffstage: false), findsOneWidget);
    sem.dispose();
    await drain(tester);
  });
}
