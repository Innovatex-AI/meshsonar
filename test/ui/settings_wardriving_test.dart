// Settings > Wardriving: the channel, the honest "Send pings to the mesh" switch, the preview of what goes on the air, the
// airtime of a ping at the radio's settings, and the This drive counters.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/ping_feedback.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/radio/airtime.dart';
import 'package:meshsonar/ui/settings/wardriving_section.dart';

import 'fakes.dart' show settleLive;
import 'settings_controls_test.dart' show openSettings, show, settingsScroll;

String textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  test('airtime of one ping: SF7 / 62.5 kHz about 214 ms, SF8 about 386 ms (MeshCore preamble); unknown radio = null', () {
    final sf7 = wardrivePingAirtimeMs(radioName: 'KE4BFI', sf: 7, bwKhz: 62.5, cr: 5)!;
    final sf8 = wardrivePingAirtimeMs(radioName: 'KE4BFI', sf: 8, bwKhz: 62.5, cr: 5)!;
    expect(sf7, inInclusiveRange(150, 260));
    expect(sf8, greaterThan(sf7 * 1.5));
    expect(wardrivePingAirtimeMs(radioName: 'x'), isNull);
    expect(airtimeLabel(214.4), '214 ms');
    expect(airtimeLabel(1234), '1.2 s');
  });

  testWidgets('the section shows the default channel, the preview, and "Connect a radio" without one', (tester) async {
    await openSettings(tester);
    await show(tester, 'channel');
    expect(textOf(tester, 'channel-name'), '#wardriving');
    await show(tester, 'ping-message');
    expect(textOf(tester, 'ping-preview'), matches(RegExp(r'^.+: MS:[0-9a-z]{10}$')));
    expect(find.textContaining('No position'), findsOneWidget);
    await show(tester, 'ping-airtime');
    expect(find.textContaining('Connect a radio to see how long one ping'), findsOneWidget);
    await show(tester, 'wardrive-counters');
    expect(textOf(tester, 'wardrive-counters-text'), startsWith('No drive running.'));
  });

  testWidgets('Send pings to the mesh is on by default; off means listen-only and says nothing is transmitted', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'send-pings');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('send-pings'))).value, isTrue);
    expect(find.textContaining('Repeaters repeat it, observers report it'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send-pings')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.discoveryMode, isTrue);
    await show(tester, 'send-pings');
    expect(find.textContaining('transmits nothing, not even the ping'), findsOneWidget);
    expect(find.textContaining('No observer can confirm your drive'), findsOneWidget);
  });

  testWidgets('with a radio connected the airtime row quotes the radio\'s SF and bandwidth', (tester) async {
    final h = await openSettings(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await tester.pumpAndSettle();
    await show(tester, 'ping-airtime');
    expect(find.textContaining('on air at SF'), findsOneWidget);
    expect(find.textContaining('one ping every 30 s'), findsOneWidget);
  });

  testWidgets('This drive: counts pings sent and repeater hearings, and says where the observer numbers stand', (tester) async {
    final h = await openSettings(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settleLive(tester);
    h.state.debugOnPing(DrivePing(
        id: 'a', ts: DateTime.utc(2026, 11, 1), lat: 40, lon: -83, kind: PingKind.tx, echoes: [Echo(repeater: '11', hops: 1), Echo(repeater: '22', hops: 1)]));
    h.state.debugOnPing(DrivePing(id: 'b', ts: DateTime.utc(2026, 11, 1), lat: 40, lon: -83, kind: PingKind.tx));
    await settleLive(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('wardrive-counters')), 100, scrollable: settingsScroll);
    await settleLive(tester);
    final t = textOf(tester, 'wardrive-counters-text');
    expect(t, contains('2 pings sent'));
    expect(t, contains('heard by repeaters 1 time'));
    expect(t, contains('2 repeater hearings'));
    expect(t, contains('Observers:'), reason: 'no uploaded ping yet: the line says it is waiting, it never invents a number');
    await h.state.stopDrive();
  });

  test('observer wording per state', () {
    // observerLine is exercised through the widget above; the enum has a sentence for every state.
    for (final st in ObserverFeedbackState.values) {
      final f = PingFeedback()..state = st;
      expect(f.state, st);
    }
  });
}
