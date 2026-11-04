// More and Network (WP11): the radio tools and the repeaters list moved from More to Chat > Network. More keeps one row that
// leads there, no duplicates, and nothing that was reachable before is unreachable now (the reachability test below walks every
// entry the old More list had).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import '../chat/chat_kit.dart';
import '../fakes.dart';

class _Sink extends SwitchableSink {
  @override
  bool get canSend => true;
}

/// Every entry the More list had before WP11 (keys `more-<name>`; Report a problem and Privacy policy have their own keys).
const oldMoreEntries = <String>[
  'radio', 'myRadios', 'devices', 'leaderboard', 'myReports', 'repeaters', 'trace', 'discover', 'adverts', 'rxLog', 'noiseFloor', 'telemetry',
  'radioSetup', 'observerJoin', 'wardriving', 'notifications', 'settings', 'legend', 'howItWorks', 'method', 'privacy', 'report', 'about', 'privacy-policy',
];

/// Where each moved entry is reachable now: the tool id its screen shows, via Chat > Network > Tools.
const movedToNetworkTools = <String, (String toolsKey, String screenKey)>{
  'trace': ('tools-trace', 'tool-trace'),
  'discover': ('tools-discover', 'tool-discover'),
  'adverts': ('tools-adverts', 'tool-adverts'),
  'rxLog': ('tools-rxlog', 'tool-rx-log'),
};

void main() {
  late ChatKit kit;
  late ChatTabProviderImpl provider;
  late Harness h;

  setUp(() {
    kit = ChatKit();
    h = Harness();
    RedesignedChatTabState.resetSession();
    appTipStore = MemoryTipStore();
    final controller = ChatController(
      store: kit.store,
      service: kit.service,
      sink: _Sink(),
      wardriveChannelName: () => '#wardriving',
      now: () => DateTime.fromMillisecondsSinceEpoch(kit.clockMs),
    );
    ChatWiring.controller.value = controller;
    provider = ChatTabProviderImpl(controller);
    ChatTabHost.provider.value = provider;
  });
  tearDown(() {
    ChatTabHost.provider.value = null;
    ChatWiring.controller.value = null;
    provider.dispose();
    kit.dispose();
    dismissAppToast();
  });

  Future<void> openMore(WidgetTester tester) async {
    useTallScreen(tester);
    await h.pumpApp(tester);
    await tapShellTab(tester, 'More');
  }

  /// Whether the More list has the row [key] (the list is lazy: from the top, scroll down looking for it). Leaves the list at the row.
  Future<bool> inMore(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    final list = find.byKey(const Key('more-list'));
    final pos = tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first).position;
    pos.jumpTo(0);
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      if (f.evaluate().isNotEmpty) return true;
      pos.jumpTo((pos.pixels + 150).clamp(0, pos.maxScrollExtent));
      await tester.pump();
      if (pos.pixels >= pos.maxScrollExtent && f.evaluate().isEmpty) return false;
    }
    return f.evaluate().isNotEmpty;
  }

  testWidgets('More has one row to Network and tools, and no duplicates of what moved', (tester) async {
    await openMore(tester);
    expect(find.text('Radios and tools'), findsOneWidget);
    expect(await inMore(tester, 'more-network'), isTrue);
    for (final moved in ['more-repeaters', 'more-trace', 'more-discover', 'more-adverts', 'more-rxLog']) {
      expect(await inMore(tester, moved), isFalse, reason: '$moved is not duplicated in More');
    }
    // The tools that were not moved stay.
    for (final k in ['more-noiseFloor', 'more-telemetry', 'more-radioSetup']) {
      expect(await inMore(tester, k), isTrue, reason: k);
    }
  });

  testWidgets('the More row deep-links to the Network segment of the Chat tab', (tester) async {
    await openMore(tester);
    expect(await inMore(tester, 'more-network'), isTrue);
    final row = find.byKey(const Key('more-network'));
    await Scrollable.ensureVisible(tester.element(row), alignment: 0.3);
    await tester.pump();
    await tester.tap(row);
    await settleLive(tester);
    expect(find.byKey(const Key('network-subtitle')), findsOneWidget);
    expect(find.byKey(const Key('network-radio-card')), findsOneWidget);
  });

  testWidgets('reachability: every entry the old More list had is still reachable', (tester) async {
    await openMore(tester);
    final stayed = <String>[];
    for (final name in oldMoreEntries) {
      final key = name == 'report' || name == 'privacy-policy' ? 'more-$name' : 'more-$name';
      if (await inMore(tester, key)) stayed.add(name);
    }
    final moved = oldMoreEntries.where((n) => !stayed.contains(n)).toSet();
    expect(moved, {'repeaters', ...movedToNetworkTools.keys}, reason: 'only the repeaters list and the four radio tools moved');

    // They now open from Chat > Network: the repeaters list is the segment itself, the tools are in its Tools menu.
    final row = find.byKey(const Key('more-network'));
    expect(await inMore(tester, 'more-network'), isTrue);
    await Scrollable.ensureVisible(tester.element(row), alignment: 0.3);
    await tester.pump();
    await tester.tap(row);
    await settleLive(tester);
    expect(find.byKey(const Key('network-radio-card')), findsOneWidget);
    for (final e in movedToNetworkTools.entries) {
      await tester.tap(find.byKey(const Key('network-tools')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key(e.value.$1)), findsOneWidget, reason: '${e.key} is in the Tools menu');
      await tester.tap(find.byKey(Key(e.value.$1)));
      await tester.pumpAndSettle();
      expect(find.byKey(Key(e.value.$2)), findsOneWidget, reason: '${e.key} opens its screen');
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });
}
