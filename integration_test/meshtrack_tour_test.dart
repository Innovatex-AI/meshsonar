// MeshTrack screen tour (build 67), driven by scripts/verify_sim.sh:
//   FLOW_TEST=integration_test/meshtrack_tour_test.dart LOCATION=40.1258,-82.9312 scripts/verify_sim.sh <worktree> [out]
// Runs the real app on the debug-only simulated radio (lib/radio/simulator.dart): its slot 1 is the private channel
// "Saturday crew", on which two SimulatedFriends (Sam, 800 m ahead; Jo, 2.5 km behind, parks after 6 min) share MeshTrack
// positions. Prints "SCREEN <name>" lines for the script to screenshot. Every MeshTrack step runs; a miss prints
// STEPFAIL (the script fails the run) and the tour goes on with the next step so one run shows every screen it can.
//
// MT_IPAD=1 (--dart-define, or on an iPad) runs only the setup and the Group sheet side panel shot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/mqtt_contract.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart' show simulatedFriendsChannelName;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/meshtrack/meshtrack_binding.dart';
import 'package:meshsonar/ui/settings_screen.dart';

import 'screens.dart';

AppState _app(WidgetTester t) => AppScope.of(t.element(find.byType(Scaffold).first));

MeshTrackService _svc(WidgetTester t) {
  final s = _app(t).meshTrack;
  if (s == null) throw StateError('MeshTrack is off in this build');
  return s;
}

int? _groupId(WidgetTester t, String name) => _svc(t).state.groups.where((g) => g.name == name).firstOrNull?.channelId;

final List<String> _failed = [];

Never _fail(String why) => throw TourMiss(why);

class TourMiss implements Exception {
  final String why;
  TourMiss(this.why);
  @override
  String toString() => why;
}

/// Runs one tour step: a miss is printed as STEPFAIL and the tour goes on from the app's first routes.
Future<void> step(WidgetTester t, String name, Future<void> Function() body) async {
  try {
    await body();
    // ignore: avoid_print
    print('STEP $name ok');
  } catch (e) {
    _failed.add(name);
    // ignore: avoid_print
    print('STEPFAIL $name: ${e.toString().split('\n').first}');
    await popToRoots(t);
  }
}

Future<void> tapKey(WidgetTester t, String key, {Duration wait = const Duration(seconds: 10), String? why}) async {
  final f = find.byKey(Key(key));
  if (!await waitFor(t, f, timeout: wait)) _fail(why ?? 'no $key');
  await t.ensureVisible(f.first);
  await pumpFor(t, const Duration(milliseconds: 300));
  await t.tap(f.first, warnIfMissed: false);
  await pumpFor(t, const Duration(milliseconds: 800));
}

Future<void> tapText(WidgetTester t, String text, {Finder? within}) async {
  final f = within == null ? find.text(text) : find.descendant(of: within, matching: find.text(text));
  if (!await waitFor(t, f, timeout: const Duration(seconds: 8))) _fail('no "$text"');
  await t.tap(f.last, warnIfMissed: false);
  await pumpFor(t, const Duration(milliseconds: 800));
}

/// Pops the top route of the root navigator (a pushed MeshTrack page or a sheet).
Future<void> backRoot(WidgetTester t) async {
  final nav = t.state<NavigatorState>(find.byType(Navigator).first);
  await nav.maybePop();
  await pumpFor(t, const Duration(milliseconds: 900));
}

Future<void> openGroupSheet(WidgetTester t) async {
  await popToRoots(t);
  await openTab(t, 'Drive');
  await tapKey(t, 'meshtrack-chip', why: 'no MeshTrack chip on the Drive tab');
  if (!await waitFor(t, find.byKey(const Key('mt-groups')), timeout: const Duration(seconds: 5))) {
    if (find.byKey(const Key('mt-back')).evaluate().isNotEmpty) {
      await tapKey(t, 'mt-back');
    } else {
      _fail('the chip did not open the Group sheet');
    }
  }
}

String? _chipLabel(WidgetTester t) {
  final f = find.byKey(const Key('meshtrack-chip-label'));
  return f.evaluate().isEmpty ? null : t.widget<Text>(f.first).data;
}

Future<bool> _until(WidgetTester t, bool Function() cond, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (cond()) return true;
  }
  return cond();
}

const _ipad = bool.fromEnvironment('MT_IPAD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MeshTrack tour', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 2; i <= 5; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue,
        reason: 'home shell');

    // Setup from the screen tour: the first-launch disclosure, the simulated radio, the antenna sheet.
    for (final s in screens.where((s) => const ['disclosure', 'connect', 'antenna'].contains(s.name))) {
      try {
        await s.run(t);
      } catch (e) {
        // ignore: avoid_print
        print('SKIPPED ${s.name}: ${e.toString().split('\n').first}');
      }
    }
    await popToRoots(t);
    if (!_app(t).connected) _fail('the simulated radio did not connect');
    final connectedAt = DateTime.now();
    // Groups live in the Keychain and survive a reinstall (as on a phone): leave any from an earlier run, so the tour
    // starts from "No groups yet". Leave keeps the channels and their chat.
    final ops = _app(t).meshTrackGroups;
    for (final g in [..._svc(t).state.groups]) {
      await ops?.stopUsingChannel(g.channelId);
    }
    await pumpFor(t, const Duration(seconds: 1));

    final wide = MediaQuery.sizeOf(t.element(find.byType(Scaffold).first)).width >= kMtSidePanelWidthForTour;
    if (_ipad || wide) {
      await _ipadTour(t);
      // ignore: avoid_print
      print('VERIFY_DONE');
      expect(_failed, isEmpty, reason: 'failed steps: $_failed');
      return;
    }

    // ------------------------------------------------------------------ chip, empty sheet, setup screens
    await step(t, 'chip-idle', () async {
      await openTab(t, 'Drive');
      if (!await waitFor(t, find.byKey(const Key('meshtrack-chip')))) _fail('no MeshTrack chip');
      if (_chipLabel(t) != 'MeshTrack') _fail('chip says "${_chipLabel(t)}", not "MeshTrack"');
      await shot(t, 'mt-01-chip-idle');
    });

    await step(t, 'sheet-empty', () async {
      await openGroupSheet(t);
      if (!await waitFor(t, find.byKey(const Key('mt-empty')))) _fail('no empty state');
      await shot(t, 'mt-02-sheet-empty');
    });

    await step(t, 'join', () async {
      await tapKey(t, 'mt-empty-join');
      if (!await waitFor(t, find.byKey(const Key('mt-join')))) _fail('Join a group did not open the Join screen');
      await shot(t, 'mt-03-join');
      await backRoot(t);
    });

    await step(t, 'use-existing', () async {
      if (find.byKey(const Key('mt-empty-existing')).evaluate().isEmpty) await openGroupSheet(t);
      await tapKey(t, 'mt-empty-existing');
      if (!await waitFor(t, find.byKey(const Key('mt-use-existing')))) _fail('no Use a private channel screen');
      if (!await waitFor(t, find.descendant(of: find.byKey(const Key('mt-use-existing')), matching: find.text(simulatedFriendsChannelName)))) {
        _fail('"$simulatedFriendsChannelName" is not offered');
      }
      await shot(t, 'mt-04-use-existing');
      await backRoot(t);
    });

    await step(t, 'new-group', () async {
      if (find.byKey(const Key('mt-empty-new')).evaluate().isEmpty) await openGroupSheet(t);
      await tapKey(t, 'mt-empty-new');
      final field = find.byKey(const Key('mt-group-name'));
      if (!await waitFor(t, field)) _fail('no New group screen');
      await shot(t, 'mt-05-new-group');
      await tapKey(t, 'mt-create');
      final qr = find.byKey(const Key('mt-invite-qr'));
      final err = find.byWidgetPredicate((w) => w.key == const Key('mt-name-error') || w.key == const Key('mt-op-error'));
      await _until(t, () => qr.evaluate().isNotEmpty || err.evaluate().isNotEmpty, const Duration(seconds: 20));
      if (qr.evaluate().isEmpty && err.evaluate().isNotEmpty) {
        // The radio already has a channel with the default name (an earlier run left it there; channels outlive a
        // reinstall on the radio and in the Keychain): show the error, then create under another name.
        final why = find.descendant(of: err.first, matching: find.byType(Text));
        // ignore: avoid_print
        print('NOTE create refused: ${why.evaluate().isEmpty ? '?' : t.widget<Text>(why.first).data}');
        await shot(t, 'mt-05b-create-refused');
        await t.enterText(field, 'Ride crew ${DateTime.now().millisecondsSinceEpoch % 1000}');
        await pumpFor(t, const Duration(milliseconds: 400));
        await tapKey(t, 'mt-create');
      }
      if (!await waitFor(t, qr, timeout: const Duration(seconds: 20))) _fail('Create did not show the invite');
      await shot(t, 'mt-06-invite');
      await tapKey(t, 'mt-invite-done');
    });

    await step(t, 'use-saturday-crew', () async {
      await openGroupSheet(t);
      await tapKey(t, find.byKey(const Key('mt-existing')).evaluate().isNotEmpty ? 'mt-existing' : 'mt-empty-existing');
      await tapText(t, simulatedFriendsChannelName, within: find.byKey(const Key('mt-use-existing')));
      if (!await _until(t, () => _groupId(t, simulatedFriendsChannelName) != null, const Duration(seconds: 15))) {
        _fail('"$simulatedFriendsChannelName" did not become a group');
      }
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'mt-07-groups');
    });

    // ------------------------------------------------------------------ Share, intro, duration, menu, Undo
    await step(t, 'intro', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      if (find.byKey(Key('mt-share-$id')).evaluate().isEmpty) await openGroupSheet(t);
      await tapKey(t, 'mt-share-$id');
      if (!await waitFor(t, find.byKey(const Key('mt-intro')))) _fail('first Share on did not show the intro');
      await shot(t, 'mt-08-intro');
      await tapKey(t, 'mt-intro-ok');
      if (!await _until(t, () => _svc(t).state.group(id)?.config.share ?? false, const Duration(seconds: 5))) _fail('Got it did not turn Share on');
      await t.ensureVisible(find.byKey(Key('mt-duration-$id')));
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot(t, 'mt-09-groups-sharing');
    });

    await step(t, 'menu', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      await tapKey(t, 'mt-menu-$id');
      if (!await waitFor(t, find.byKey(const Key('mt-group-menu')))) _fail('no group menu');
      await shot(t, 'mt-10-group-menu');
      await backRoot(t);
    });

    await step(t, 'stop-undo', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      if (find.byKey(Key('mt-share-$id')).evaluate().isEmpty) await openGroupSheet(t);
      await tapKey(t, 'mt-share-$id');
      if (!await waitFor(t, find.textContaining('Stopped sharing with'), timeout: const Duration(seconds: 4))) _fail('no Stopped sharing toast');
      await pumpFor(t, const Duration(milliseconds: 200));
      // ignore: avoid_print
      print('SCREEN mt-11-stopped-undo');
      await pumpFor(t, const Duration(milliseconds: 1500));
      await tapText(t, 'Undo');
      if (!await _until(t, () => _svc(t).state.group(id)?.config.share ?? false, const Duration(seconds: 5))) _fail('Undo did not turn Share back on');
    });

    // ------------------------------------------------------------------ people
    await step(t, 'people', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      if (find.byKey(Key('mt-open-$id')).evaluate().isEmpty) await openGroupSheet(t);
      await tapKey(t, 'mt-open-$id');
      final ok = await _until(t, () => (_svc(t).state.group(id)?.friends.length ?? 0) >= 2, const Duration(seconds: 150));
      if (!ok) _fail('the two simulated friends were not heard (${_svc(t).state.group(id)?.friends.length ?? 0})');
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'mt-12-people');
      await tapKey(t, 'mt-ask-Sam KD8SAM');
      if (!await waitFor(t, find.text('Asked'), timeout: const Duration(seconds: 4))) _fail('no "Asked" after Where are you?');
      await shot(t, 'mt-13-people-asked');
      await tapKey(t, 'mt-meet-here');
      if (!await waitFor(t, find.byKey(const Key('mt-meet')), timeout: const Duration(seconds: 6))) _fail('Meet here made no meet-up row');
      await pumpFor(t, const Duration(seconds: 4)); // the Undo toast goes away
      await shot(t, 'mt-14-people-meet');
    });

    await step(t, 'people-empty', () async {
      final other = _svc(t).state.groups.where((g) => g.name != simulatedFriendsChannelName).firstOrNull ?? _fail('no second group');
      await openGroupSheet(t);
      await tapKey(t, 'mt-open-${other.channelId}');
      if (!await waitFor(t, find.byKey(const Key('mt-people-empty')))) _fail('no people empty state');
      await shot(t, 'mt-15-people-empty');
      await popToRoots(t);
    });

    // ------------------------------------------------------------------ drive: chip, friends layer, meet here, layers
    await step(t, 'chip-sharing', () async {
      await popToRoots(t);
      await openTab(t, 'Drive');
      final go = find.byKey(const Key('start-stop'));
      if (!await waitFor(t, go)) _fail('no Start drive');
      await t.tap(go.first);
      var sawGps = false;
      final ok = await _until(t, () {
        final l = _chipLabel(t);
        if (l == 'Waiting for GPS' && !sawGps) {
          sawGps = true;
          // ignore: avoid_print
          print('SCREEN mt-16a-chip-waiting-gps');
        }
        return l != null && l.startsWith('Sharing: ');
      }, const Duration(seconds: 30));
      if (!_app(t).driving) _fail('Start drive did not start a drive');
      if (!ok) _fail('chip says "${_chipLabel(t)}" while driving and sharing');
      if (find.byKey(const Key('meshtrack-chip-dot')).evaluate().isEmpty) _fail('no accent dot on the Sharing chip');
      // ignore: avoid_print
      print('NOTE waiting-for-gps chip seen: $sawGps');
      await shot(t, 'mt-16-chip-sharing');
    });

    await step(t, 'friends-map', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      // Jo parks 6 min after the radio connected and sends its parked position after 90 s below 3 km/h: wait for it.
      final parkAt = connectedAt.add(const Duration(minutes: 8, seconds: 20));
      while (DateTime.now().isBefore(parkAt)) {
        await pumpFor(t, const Duration(seconds: 5));
      }
      final g = _svc(t).state.group(id) ?? _fail('group gone');
      final me = _app(t).phoneFix?.fix;
      final pts = [for (final f in g.friends) LatLng(f.lat, f.lon), if (me != null) LatLng(me.lat, me.lon)];
      final c = LatLng(pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length, pts.map((p) => p.longitude).reduce((a, b) => a + b) / pts.length);
      // Centre a little east of the middle: the map buttons sit on the right edge and covered a pin there.
      final span = pts.map((p) => p.longitude).reduce((a, b) => a > b ? a : b) - pts.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
      MainMapFocus.request(LatLng(c.latitude, c.longitude + span * 0.12), 12.6);
      await pumpFor(t, const Duration(seconds: 3));
      if (find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('map-friend-')).evaluate().isEmpty) {
        _fail('no friend pins on the Drive map');
      }
      // ignore: avoid_print
      print('NOTE friends: ${g.friends.map((f) => '${f.name} ${f.staleness.name} moving=${(f.speedKmh ?? 0) > 0}').join(', ')}');
      await shot(t, 'mt-17-drive-friends');
    });

    await step(t, 'people-parked', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      await tapKey(t, 'meshtrack-chip');
      if (find.byKey(Key('mt-open-$id')).evaluate().isNotEmpty) await tapKey(t, 'mt-open-$id');
      if (!await waitFor(t, find.byKey(const Key('mt-people')))) _fail('no people page');
      await shot(t, 'mt-17b-people-later');
      final jo = find.byKey(const Key('mt-friend-Jo N8JO'));
      if (jo.evaluate().isNotEmpty) {
        await Scrollable.ensureVisible(t.element(jo.first), alignment: 0.6);
        await pumpFor(t, const Duration(milliseconds: 500));
        await shot(t, 'mt-17c-people-parked');
      }
      await popToRoots(t);
    });

    await step(t, 'meet-here-map', () async {
      final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
      final size = MediaQuery.sizeOf(t.element(find.byType(Scaffold).first));
      await t.longPressAt(Offset(size.width * 0.35, size.height * 0.38));
      await pumpFor(t, const Duration(milliseconds: 800));
      if (!await waitFor(t, find.byKey(const Key('meet-here-sheet')), timeout: const Duration(seconds: 4))) _fail('long-press did not offer Meet here');
      await shot(t, 'mt-18-meet-here-sheet');
      await tapKey(t, 'meet-here-$id');
      await pumpFor(t, const Duration(seconds: 4));
      if (find.byKey(ValueKey('map-meet-$id')).evaluate().isEmpty) _fail('no meet flag on the map');
      await shot(t, 'mt-19-meet-flag');
    });

    await step(t, 'layers', () async {
      final btn = find.byKey(const Key('drive-map-layers')).evaluate().isNotEmpty ? find.byKey(const Key('drive-map-layers')) : find.byTooltip('Map layers');
      if (!await waitFor(t, btn, timeout: const Duration(seconds: 4))) _fail('no Layers button');
      await t.tap(btn.first);
      await pumpFor(t, const Duration(seconds: 1));
      if (!await waitFor(t, find.byKey(const Key('layers-sheet')))) _fail('no Layers sheet');
      final friends = find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.text('Friends'));
      if (!await scrollToFind(t, friends, find.byKey(const Key('layers-sheet')))) _fail('no Friends layer in the Layers sheet');
      final net = find.byKey(const Key('layers-group-network'));
      if (net.evaluate().isNotEmpty) {
        await Scrollable.ensureVisible(t.element(net.first), alignment: 0.05);
        await pumpFor(t, const Duration(milliseconds: 500));
      }
      await shot(t, 'mt-20-layers');
      await popToRoots(t);
    });

    await step(t, 'stop-drive', () async {
      await openTab(t, 'Drive');
      final go = find.byKey(const Key('start-stop'));
      await t.tap(go.hitTestable().first);
      await pumpFor(t, const Duration(milliseconds: 600));
      await tapKey(t, 'stop-drive-confirm');
      if (!await _until(t, () => !_app(t).driving, const Duration(seconds: 15))) _fail('Stop did not end the drive');
      await pumpFor(t, const Duration(seconds: 2));
      await popToRoots(t);
    });

    // ------------------------------------------------------------------ chats
    await step(t, 'chats', () async {
      await popToRoots(t);
      await openShellTab(t, 'Chat');
      final seg = find.byKey(const Key('segment-chats'));
      if (seg.evaluate().isNotEmpty) await t.tap(seg.first);
      await pumpFor(t, const Duration(seconds: 1));
      if (!await waitFor(t, find.byKey(const Key('meshtrack-badge')))) _fail('no MeshTrack badge in Chats');
      await shot(t, 'mt-21-chats-badge');
      final row = find.ancestor(of: find.text(simulatedFriendsChannelName), matching: find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('conv-')));
      if (row.evaluate().isEmpty) _fail('no Saturday crew row');
      await t.tap(row.first);
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'mt-22-channel-thread');
      await tapKey(t, 'conv-menu-button');
      await tapKey(t, 'menu-info');
      final use = find.byKey(const Key('mt-use-switch'));
      // The channel page is a lazily built list: the MeshTrack section exists once scrolled near.
      if (!await scrollToFind(t, use, find.byKey(const Key('channel-detail')))) _fail('no MeshTrack section on the channel page');
      await Scrollable.ensureVisible(t.element(use.first), alignment: 0.3);
      await pumpFor(t, const Duration(milliseconds: 600));
      await shot(t, 'mt-23-channel-detail');
      await popToRoots(t);
    });

    // ------------------------------------------------------------------ settings
    await step(t, 'settings-meshtrack', () async {
      await popToRoots(t);
      await openTab(t, 'Settings');
      final row = find.byKey(const Key('meshtrack-groups'));
      if (!await scrollToFind(t, row, find.byType(SettingsScreen))) _fail('no MeshTrack section in Settings');
      await Scrollable.ensureVisible(t.element(find.byKey(const Key('section-meshtrack')).first), alignment: 0.02);
      await pumpFor(t, const Duration(milliseconds: 600));
      await shot(t, 'mt-24-settings-meshtrack');
      await popToRoots(t);
    });

    await step(t, 'observer-custom-error', () async {
      await popToRoots(t);
      await _openObserver(t);
      await tapKey(t, 'mqtt-add-feed');
      await tapKey(t, 'mqtt-preset-custom', wait: const Duration(seconds: 20));
      final host = find.byKey(const Key('mqtt-field-host'));
      if (!await waitFor(t, host)) _fail('no Host field');
      await t.enterText(host, 'mqtt.meshsonar.com');
      await pumpFor(t, const Duration(milliseconds: 400));
      await tapKey(t, 'mqtt-slot-save');
      await Scrollable.ensureVisible(t.element(host), alignment: 0.15);
      await pumpFor(t, const Duration(milliseconds: 600));
      await shot(t, 'mt-25-observer-custom-error');
      await tapKey(t, 'mqtt-slot-cancel');
      await popToRoots(t);
    });

    await step(t, 'observer-not-allowed', () async {
      final s = _app(t);
      final slots = [...s.settings.mqttSlots.where((x) => x.id != 'slot-9'), const MqttSlotSettings(id: 'slot-9', name: '', host: 'mqtt.meshsonar.com', iata: null)];
      await s.updateSettings(s.settings.copyWith(mqttSlots: slots));
      await popToRoots(t);
      await _openObserver(t);
      final tile = find.byKey(const Key('mqtt-slot-slot-9-status'));
      if (!await waitFor(t, tile)) _fail('no saved slot row');
      await Scrollable.ensureVisible(t.element(tile.first), alignment: 0.5);
      await pumpFor(t, const Duration(milliseconds: 600));
      if (!(t.widget<Text>(tile.first).data ?? '').startsWith('Not allowed')) _fail('saved slot says "${t.widget<Text>(tile.first).data}"');
      await shot(t, 'mt-26-observer-not-allowed');
      await s.updateSettings(s.settings.copyWith(mqttSlots: [...s.settings.mqttSlots.where((x) => x.id != 'slot-9')]));
      await popToRoots(t);
    });

    // ignore: avoid_print
    print('VERIFY_DONE');
    expect(_failed, isEmpty, reason: 'failed steps: $_failed');
  }, timeout: const Timeout(Duration(minutes: 25)));
}

/// Same as the screen tour's Observer step: More > Observer.
Future<void> _openObserver(WidgetTester t) async {
  await openShellTab(t, 'More');
  final row = find.byKey(const Key('more-observer'));
  if (row.hitTestable().evaluate().isEmpty) {
    await t.scrollUntilVisible(row, -200, scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);
  }
  await t.ensureVisible(row);
  await pumpFor(t, const Duration(milliseconds: 500));
  await t.tap(row);
  await pumpFor(t, const Duration(seconds: 1));
  final add = find.byKey(const Key('mqtt-add-feed'));
  if (!await waitFor(t, add)) _fail('no Observer feeds');
  await t.ensureVisible(add);
  await pumpFor(t, const Duration(milliseconds: 400));
}

/// iPad: the Group sheet as a side panel, with the friends' group and its people.
Future<void> _ipadTour(WidgetTester t) async {
  await step(t, 'ipad-side-panel', () async {
    await openGroupSheet(t);
    if (!await waitFor(t, find.byKey(const Key('mt-side-panel')))) _fail('no side panel at this width');
    if (_groupId(t, simulatedFriendsChannelName) == null) {
      await tapKey(t, 'mt-empty-existing');
      await tapText(t, simulatedFriendsChannelName, within: find.byKey(const Key('mt-use-existing')));
      await _until(t, () => _groupId(t, simulatedFriendsChannelName) != null, const Duration(seconds: 15));
    }
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'mt-ipad-01-side-panel-groups');
    final id = _groupId(t, simulatedFriendsChannelName) ?? _fail('no group');
    await tapKey(t, 'mt-open-$id');
    await _until(t, () => (_svc(t).state.group(id)?.friends.length ?? 0) >= 2, const Duration(seconds: 150));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'mt-ipad-02-side-panel-people');
  });
}

const double kMtSidePanelWidthForTour = 700;
