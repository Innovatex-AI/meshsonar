// More and the radio's network (WP11, then build 71): the repeaters list and the radio tools live at More > Radio (they were
// Chat > Radio between WP11 and build 71). More has one Radio row, no duplicates, and nothing that was reachable before is
// unreachable now (the reachability test below walks every entry the old More list had).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/info/method_screens.dart';
import 'package:meshsonar/ui/settings_screen.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

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

/// Where each moved entry is reachable now: the tool id its screen shows, via More > Radio > Tools.
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

  testWidgets('More has one Radio row, and no duplicates of what lives inside it', (tester) async {
    await openMore(tester);
    expect(find.text('Radios and tools'), findsNothing, reason: 'build 71: no group headers');
    expect(await inMore(tester, 'more-radio'), isTrue);
    for (final moved in ['more-network', 'more-repeaters', 'more-trace', 'more-discover', 'more-adverts', 'more-rxLog', 'more-noiseFloor', 'more-telemetry', 'more-radioSetup']) {
      expect(await inMore(tester, moved), isFalse, reason: '$moved is not a row of More');
    }
  });

  testWidgets('More > Radio shows the radio card and its lists (it was Chat > Radio until build 71)', (tester) async {
    await openMore(tester);
    await tester.tap(find.byKey(const Key('more-radio')));
    await settleLive(tester);
    expect(find.byKey(const Key('more-radio-screen')), findsOneWidget);
    expect(find.byKey(const Key('network-subtitle')), findsOneWidget);
    expect(find.byKey(const Key('network-radio-card')), findsOneWidget);
    // Build 76: set-up and the region check sit above the radio card and the repeaters, not under them.
    expect(tester.getTopLeft(find.byKey(const Key('more-radioSetup'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('network-radio-card'))).dy));
    final list = find.descendant(of: find.byKey(const Key('more-radio-list')), matching: find.byType(Scrollable)).first;
    for (final k in ['more-radioSettings', 'more-radioSetup', 'more-noiseFloor', 'more-telemetry']) {
      await tester.scrollUntilVisible(find.byKey(Key(k)), 200, scrollable: list);
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    // Chat has no Radio segment any more.
    await tapShellTab(tester, 'Chat');
    await settleLive(tester);
    expect(find.byKey(const Key('segment-radio')), findsNothing);
    expect(find.byKey(const Key('segment-channels')), findsOneWidget);
  });

  testWidgets('reachability: every entry the old More list had is still reachable', (tester) async {
    await openMore(tester);
    final shell = ShellController.active!;
    final stayed = <String>[];
    for (final name in oldMoreEntries) {
      if (await inMore(tester, 'more-$name')) stayed.add(name);
    }
    expect(stayed.toSet(), {'radio', 'devices', 'leaderboard', 'observerJoin', 'settings', 'about'});

    Future<void> back() async {
      shell.select(AppTab.more); // tapping More again returns to its list
      await settleLive(tester);
    }

    // Under Help.
    await tester.tap(find.byKey(const Key('more-help')));
    await tester.pumpAndSettle();
    for (final k in ['more-myReports', 'more-legend', 'more-howItWorks', 'more-method', 'more-report', 'more-privacy-policy']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: '$k is under Help');
    }
    await tester.tap(find.byKey(const Key('more-method')));
    await tester.pumpAndSettle();
    expect(find.byType(MethodScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-help-list')), findsOneWidget, reason: 'Back returns to Help');
    await back();

    // In Settings (the rows that only jumped there): the MoreItem still opens the section for code that asks.
    for (final item in [MoreItem.myRadios, MoreItem.wardriving, MoreItem.notifications, MoreItem.privacy, MoreItem.observer]) {
      shell.openMore(item);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget, reason: item.name);
      await back();
    }

    // Under Radio: the lists (the old "repeaters" row), the four radio tools in its Tools menu, and the rest as rows.
    shell.openMore(MoreItem.repeaters);
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
    final list = find.descendant(of: find.byKey(const Key('more-radio-list')), matching: find.byType(Scrollable)).first;
    for (final k in ['more-radioSettings', 'more-radioSetup', 'more-noiseFloor', 'more-telemetry']) {
      await tester.scrollUntilVisible(find.byKey(Key(k)), 200, scrollable: list);
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
  });
}
