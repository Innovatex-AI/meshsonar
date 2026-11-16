// Finding MeshTrack outside the Drive panel (build 69): the card at the top of Chat > Channels (and the empty Channels
// list) that opens the Group sheet, "New MeshTrack group" in the New chat sheet, and Settings > MeshTrack placed right
// after the driving sections with a one-line description, found by search for friends / share location / meshtrack /
// track.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';
import 'package:meshsonar/ui/settings/meshtrack_section.dart' show meshTrackHelp;
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings_screen.dart' show settingsSectionHelp;
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/theme.dart';

import '../chat/chat_kit.dart';
import '../fakes.dart' show Harness;
import 'mt_kit.dart';

void main() {
  group('Chat tab', () {
    late ChatKit kit;
    late Harness h;
    late ChatTabProviderImpl provider;
    setUp(() {
      kit = ChatKit();
      h = Harness();
      RedesignedChatTabState.resetSession();
      appTipStore = MemoryTipStore();
      ChatWiring.controller.value = kit.controller;
      provider = ChatTabProviderImpl(kit.controller);
      ChatTabHost.provider.value = provider;
    });
    tearDown(() {
      ChatTabHost.provider.value = null;
      ChatWiring.controller.value = null;
      provider.dispose();
      kit.dispose();
      dismissAppToast();
    });

    Future<void> pumpTab(WidgetTester tester, MtRig rig, {Size size = const Size(402, 874), double scale = 1}) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await h.state.init();
      await tester.pumpWidget(MeshTrackScope(
        binding: rig.binding,
        child: AppScope(
          state: h.state,
          child: MaterialApp(
            theme: meshSonarTheme(Brightness.dark).copyWith(platform: TargetPlatform.iOS),
            builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
            home: const Scaffold(body: ChatTab()),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (final (w, h) in [(375.0, 667.0), (402.0, 874.0)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('Channels: the MeshTrack card is first and opens the Group sheet ($w wide, ${scale}x)', (tester) async {
          final rig = MtRig();
          await kit.channel(0, 'Public', kind: ChannelKind.public);
          await kit.channel(2, '#alpha', kind: ChannelKind.hashtag);
          await pumpTab(tester, rig, size: Size(w, h), scale: scale);
          await tester.tap(find.byKey(const Key('segment-channels')));
          await tester.pumpAndSettle();
          final card = find.byKey(const Key('mt-chat-card-hit'));
          expect(card, findsOneWidget);
          expect(find.text('MeshTrack'), findsWidgets);
          expect(tester.widget<Text>(find.byKey(const Key('mt-chat-card-line'))).data, 'See friends on the map. Make a group or join one.');
          // At 2x on an SE the channel rows start below the fold (the list builds lazily): then the card alone is on screen.
          if (find.text('Public').evaluate().isNotEmpty) {
            expect(tester.getTopLeft(card).dy, lessThan(tester.getTopLeft(find.text('Public').first).dy), reason: 'above the channels');
          }
          expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
          await tester.tap(card);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('mt-empty')), findsOneWidget);
          if (scale == 1) {
            expect(find.byKey(const Key('mt-empty-new')), findsOneWidget);
            expect(find.byKey(const Key('mt-empty-join')), findsOneWidget);
          }
          await rig.done(tester);
        });
      }
    }

    testWidgets('Channels with no channels yet: the card sits above the empty state; with groups it names them', (tester) async {
      final rig = MtRig();
      await pumpTab(tester, rig);
      await tester.tap(find.byKey(const Key('segment-channels')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-chat-card-hit')), findsWidgets);
      rig.svc.addGroup(5, 'Family');
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('mt-chat-card-line')).first).data, 'Family. See them on the Drive map.');
      await rig.done(tester);
    });

    testWidgets('New chat sheet: "New MeshTrack group" opens the New group screen', (tester) async {
      final rig = MtRig();
      await pumpTab(tester, rig, size: const Size(402, 1700));
      await tester.tap(find.byKey(const Key('chat-new')));
      await tester.pumpAndSettle();
      final entry = find.byKey(const Key('add-meshtrack'));
      await tester.scrollUntilVisible(entry, 120, scrollable: find.byType(Scrollable).last);
      expect(find.text('New MeshTrack group'), findsOneWidget);
      // Next to the other ways to start a channel.
      expect(tester.getTopLeft(entry).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('add-create'))).dy));
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mt-group-name')), findsOneWidget);
      await rig.done(tester);
    });
  });

  group('Settings', () {
    test('MeshTrack comes right after the driving sections (Wardriving, Radio, Claimed radios), high in the list', () {
      final ids = settingsSections.map((s) => s.id).toList();
      expect(ids.indexOf('meshtrack'), ids.indexOf('my-radios-section') + 1);
      expect(ids.indexOf('wardriving'), lessThan(ids.indexOf('meshtrack')));
      expect(ids.indexOf('radio'), lessThan(ids.indexOf('meshtrack')));
      expect(ids.indexOf('meshtrack'), lessThan(ids.indexOf('display')));
      expect(ids.indexOf('meshtrack'), lessThan(ids.length ~/ 2), reason: 'not buried at the bottom');
    });

    test('the section header is one plain line', () {
      expect(settingsSectionHelp('meshtrack'), meshTrackHelp);
      expect(meshTrackHelp.length, lessThan(120));
      expect(meshTrackHelp, startsWith('See friends on the map'));
    });

    for (final q in ['friends', 'share location', 'meshtrack', 'MeshTrack', 'track']) {
      test('search "$q" finds MeshTrack > Groups', () {
        final hits = searchSettings(q);
        expect(hits.map((e) => e.id), contains('meshtrack-groups'), reason: q);
        // "friends" also matches "Position friends see" by its title; every other word puts Groups first.
        if (q != 'friends') expect(hits.firstWhere((e) => e.section == 'meshtrack').id, 'meshtrack-groups');
      });
    }
  });
}
