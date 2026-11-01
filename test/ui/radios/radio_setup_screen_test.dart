// Radio setup: guard rails, the loud confirm, read-back, undo, the drive guard. Real tools over the simulated radio.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/radio_presets.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/radio_setup.dart';
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/ui/radios/radio_setup/radio_setup_screen.dart';

import '../../support/tools_rig.dart';
import '../../support/tools_ui_rig.dart';

class _Community implements CommunityPresetSource {
  int fetches = 0;
  @override
  Future<List<CommunityPreset>> fetch() async {
    fetches++;
    return const [
      CommunityPreset(title: 'Elsewhere 250', freqMhz: 915.8, bwKhz: 250, sf: 10, cr: 5),
      CommunityPreset(title: 'Here 62.5', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5),
    ];
  }
}

/// Scrolls the lazy list until [f] is built and on screen (down first, then up).
Future<void> reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    final scrollable = find.descendant(of: find.byKey(const Key('setup-list')), matching: find.byType(Scrollable)).first;
    for (final delta in [400.0, -400.0]) {
      try {
        await tester.scrollUntilVisible(f, delta, scrollable: scrollable, maxScrolls: 40);
        break;
      } catch (_) {}
    }
  }
  await tester.ensureVisible(f);
  await tester.pump();
}

/// Real time for a chain of radio commands (command, read-back) to finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await settleReal(tester, real: const Duration(milliseconds: 150));
  }
}

Future<void> tapAndWait(WidgetTester tester, Finder f) async {
  await reveal(tester, f);
  await tester.tap(f);
  await settle(tester);
}

Future<void> openScreen(WidgetTester tester, FakeToolsHost host, {CommunityPresetSource? source, Device device = Device.ipad}) async {
  await pumpTool(tester, RadioSetupScreen(communitySource: source), host, device: device);
  await settle(tester);
}

int count(ToolsRig rig, int code) => rig.radio.sentFrames.where((f) => f[0] == code).length;

void main() {
  testWidgets('no radio: the gate, nothing else', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pumpTool(tester, const RadioSetupScreen(), host);
    expect(find.byKey(const Key('tool-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('setup-name')), findsNothing);
  });

  testWidgets('shows the radio\'s real settings and whether they match the region preset', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await openScreen(tester, host);
    expect(tester.widget<TextField>(find.byKey(const Key('setup-name-field'))).controller!.text, 'MeshSonar Sim');
    expect(find.text('No position is stored on this radio.'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('setup-params-current')));
    expect(tester.widget<Text>(find.byKey(const Key('setup-params-current'))).data, '910.525 MHz, 62.5 kHz, SF7, CR5');
    expect(find.textContaining('Matches the Columbus preset: MeshCore US Recommended.'), findsOneWidget);
    expect(find.textContaining('hardware limit is 22 dBm'), findsOneWidget);
    expect(count(rig, Cmd.appStart), greaterThanOrEqualTo(2), reason: 'the screen read the radio itself');
  });

  testWidgets('a radio on other settings is called different, in words, and nothing is applied by itself', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await tester.runAsync(() => rig.tools.setup.applyRadioParams(const RadioParams(915800, 250000, 10, 5)));
    final before = count(rig, ToolCmd.setRadioParams);
    await openScreen(tester, host);
    await reveal(tester, find.byKey(const Key('setup-preset-status')));
    expect(find.textContaining('Differs from the Columbus preset (MeshCore US Recommended) in:'), findsOneWidget);
    await settleReal(tester, real: const Duration(milliseconds: 600));
    expect(count(rig, ToolCmd.setRadioParams), before, reason: 'looking never writes');
  });

  group('name', () {
    testWidgets('a good name is written and read back; a colon is refused before anything is sent', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      await tester.enterText(find.byKey(const Key('setup-name-field')), 'Ann: truck');
      await tester.pump();
      expect(find.textContaining('cannot contain a colon'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-name-save'))).onPressed, isNull);
      expect(count(rig, ToolCmd.setAdvertName), 0);
      await tester.enterText(find.byKey(const Key('setup-name-field')), 'KE4BFI Mobile');
      await tester.pump();
      expect(find.text('13 of 31 bytes'), findsOneWidget);
      await tapAndWait(tester, find.byKey(const Key('setup-name-save')));
      expect(rig.radio.advertName, 'KE4BFI Mobile');
      expect(find.textContaining('Saved: the radio reports the new name.'), findsOneWidget);
      expect(find.byKey(const Key('setup-undo')), findsOneWidget);
    });

    testWidgets('undo puts the old name back', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      await tester.enterText(find.byKey(const Key('setup-name-field')), 'Other');
      await tester.pump();
      await tapAndWait(tester, find.byKey(const Key('setup-name-save')));
      expect(rig.radio.advertName, 'Other');
      await tapAndWait(tester, find.byKey(const Key('setup-undo')));
      expect(rig.radio.advertName, 'MeshSonar Sim');
      expect(find.byKey(const Key('setup-undo')), findsNothing);
    });
  });

  group('position', () {
    testWidgets('phone location needs a confirm, only fills the boxes, and saves only on Save position', (tester) async {
      final (rig, host) = await connectedRig(tester);
      host.phone = (lat: 39.9612, lon: -82.9988);
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-position-phone')));
      expect(find.byKey(const Key('setup-phone-location-confirm')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const Key('setup-lat-field'))).controller!.text, '');
      await tapAndWait(tester, find.byKey(const Key('setup-position-phone')));
      await tester.tap(find.byKey(const Key('setup-phone-location-ok')));
      await settle(tester);
      expect(tester.widget<TextField>(find.byKey(const Key('setup-lat-field'))).controller!.text, '39.96120');
      expect(count(rig, ToolCmd.setAdvertLatLon), 0, reason: 'copying into the boxes sends nothing');
      await tapAndWait(tester, find.byKey(const Key('setup-position-save')));
      expect(rig.radio.advertPosition.lat, closeTo(39.9612, 1e-6));
      expect(find.textContaining('Stored on the radio: 39.96120, -82.99880'), findsOneWidget);
    });

    testWidgets('typed positions are checked: out of range and 0,0 are explained, Save stays off', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      await tester.enterText(find.byKey(const Key('setup-lat-field')), '95');
      await tester.enterText(find.byKey(const Key('setup-lon-field')), '10');
      await tester.pump();
      expect(find.textContaining('Latitude must be between'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-position-save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('setup-lat-field')), '0');
      await tester.enterText(find.byKey(const Key('setup-lon-field')), '0');
      await tester.pump();
      expect(find.textContaining('means "no position"'), findsOneWidget);
      expect(count(rig, ToolCmd.setAdvertLatLon), 0);
    });

    testWidgets('phone says no: a plain sentence, boxes unchanged', (tester) async {
      final (rig, host) = await connectedRig(tester);
      host.phone = null;
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-position-phone')));
      await tester.tap(find.byKey(const Key('setup-phone-location-ok')));
      await settle(tester);
      await reveal(tester, find.byKey(const Key('setup-result')));
      expect(find.textContaining('Your phone did not give a position'), findsOneWidget);
      expect(count(rig, ToolCmd.setAdvertLatLon), 0);
    });

    testWidgets('advert position policy: turning it on asks first, off does not', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-advert-position')));
      expect(find.byKey(const Key('setup-advert-position-confirm')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(count(rig, Cmd.setOtherParams), 0);
      await tapAndWait(tester, find.byKey(const Key('setup-advert-position')));
      await tester.tap(find.byKey(const Key('setup-advert-position-ok')));
      await settle(tester);
      expect(rig.session.tools!.setup.config!.advertLocPolicy, 1);
      await tapAndWait(tester, find.byKey(const Key('setup-advert-position')));
      expect(find.byKey(const Key('setup-advert-position-confirm')), findsNothing);
      expect(rig.session.tools!.setup.config!.advertLocPolicy, 0);
    });
  });

  group('behaviour and power', () {
    testWidgets('manual add and extra acknowledgements write and read back', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-manual-add')));
      expect(rig.session.tools!.setup.config!.manualAdd, isTrue);
      await tapAndWait(tester, find.byKey(const Key('setup-multi-acks')));
      expect(rig.session.tools!.setup.config!.multiAcks, 1);
      final f = rig.radio.sentFrames.lastWhere((f) => f[0] == Cmd.setOtherParams);
      expect(f.sublist(1), [1, 0, 0, 1]);
    });

    testWidgets('TX power is limited by the radio\'s own maximum and saved when changed', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      final slider = tester.widget<Slider>(find.byKey(const Key('setup-tx-slider')));
      expect(slider.max, 22);
      expect(slider.min, -9);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-tx-save'))).onPressed, isNull, reason: 'unchanged');
      slider.onChanged!(14);
      await tester.pump();
      expect(find.text('14 dBm'), findsWidgets);
      await tapAndWait(tester, find.byKey(const Key('setup-tx-save')));
      expect(rig.radio.txPowerDbm, 14);
    });
  });

  group('radio parameters: the loud confirm', () {
    testWidgets('region preset: Apply asks, says what it does, needs "I understand", Cancel changes nothing', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await tester.runAsync(() => rig.tools.setup.applyRadioParams(const RadioParams(915800, 250000, 10, 5)));
      await openScreen(tester, host);
      final before = count(rig, ToolCmd.setRadioParams);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNotNull);
      expect(find.byKey(const Key('setup-compare')), findsOneWidget);
      await tapAndWait(tester, find.byKey(const Key('setup-apply')));
      expect(find.byKey(const Key('setup-confirm')), findsOneWidget);
      expect(find.textContaining('changes which radios can hear yours'), findsOneWidget);
      expect(find.textContaining('disconnect you from other devices'), findsOneWidget);
      expect(find.byKey(const Key('setup-confirm-from')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('setup-confirm-to'))).data, 'To:  910.525 MHz, 62.5 kHz, SF7, CR5');
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-confirm-apply'))).onPressed, isNull, reason: 'locked until understood');
      await tester.tap(find.byKey(const Key('setup-confirm-cancel')));
      await tester.pumpAndSettle();
      expect(count(rig, ToolCmd.setRadioParams), before);
      expect(rig.radio.radioParams.sf, 10);
    });

    testWidgets('confirmed: applied, read back, shown as done; Undo puts the exact old values back', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await tester.runAsync(() => rig.tools.setup.applyRadioParams(const RadioParams(915800, 250000, 10, 5)));
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-apply')));
      await tester.tap(find.byKey(const Key('setup-confirm-understood')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('setup-confirm-apply')));
      await settle(tester);
      expect(rig.radio.radioParams, (freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5));
      expect(find.textContaining('Saved: the radio reports the new radio parameters.'), findsOneWidget);
      expect(find.textContaining('Matches the Columbus preset'), findsOneWidget);
      expect(find.textContaining('Undo: radio parameters (915.800 MHz, 250 kHz, SF10, CR5)'), findsOneWidget);
      await tapAndWait(tester, find.byKey(const Key('setup-undo')));
      expect(rig.radio.radioParams, (freqKhz: 915800, bwHz: 250000, sf: 10, cr: 5));
    });

    testWidgets('community presets load only when asked; one can be applied through the same confirm', (tester) async {
      final (rig, host) = await connectedRig(tester);
      final src = _Community();
      await openScreen(tester, host, source: src);
      await tapAndWait(tester, find.byKey(const Key('setup-choice-community')));
      expect(src.fetches, 0, reason: 'nothing is fetched until the button');
      await tapAndWait(tester, find.byKey(const Key('setup-community-load')));
      expect(src.fetches, 1);
      await tapAndWait(tester, find.byKey(const Key('setup-community-Elsewhere 250')));
      await tapAndWait(tester, find.byKey(const Key('setup-apply')));
      await tester.tap(find.byKey(const Key('setup-confirm-understood')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('setup-confirm-apply')));
      await settle(tester);
      expect(rig.radio.radioParams, (freqKhz: 915800, bwHz: 250000, sf: 10, cr: 5));
    });

    testWidgets('by hand: out-of-range values are explained and cannot be applied; the radio already on them says so', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-choice-custom')));
      expect(find.byKey(const Key('setup-params-same')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('setup-freq-field')), '99');
      await tester.pump();
      expect(find.textContaining('Frequency must be between 150 and 2500 MHz.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('setup-freq-field')), '868.1');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNotNull);
      expect(count(rig, ToolCmd.setRadioParams), 0);
    });

    testWidgets('no region preset: the chooser says so and offers the other two ways', (tester) async {
      final (rig, host) = await connectedRig(tester);
      host.regionPreset = null;
      await openScreen(tester, host);
      expect(find.byKey(const Key('setup-preset-none')), findsOneWidget);
      expect(find.text('Not available for this region.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNull);
      expect(rig.radio.sentFrames.where((f) => f[0] == ToolCmd.setRadioParams), isEmpty);
    });
  });

  group('drive guard', () {
    testWidgets('while a drive records, parameters and TX power are blocked until the drive stops or the person confirms', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await tester.runAsync(() => rig.tools.setup.applyRadioParams(const RadioParams(915800, 250000, 10, 5)));
      host.driveRecording = true;
      await openScreen(tester, host);
      // the name is not part of the survey: still editable
      await tester.enterText(find.byKey(const Key('setup-name-field')), 'Still fine');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-name-save'))).onPressed, isNotNull);
      await reveal(tester, find.byKey(const Key('setup-apply')));
      expect(find.text('Drive in progress'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNull);
      final slider = tester.widget<Slider>(find.byKey(const Key('setup-tx-slider')));
      slider.onChanged!(10);
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-tx-save'))).onPressed, isNull);
      // confirming unlocks, and the confirm dialog repeats the warning
      await tapAndWait(tester, find.byKey(const Key('setup-drive-ok')));
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNotNull);
      await tapAndWait(tester, find.byKey(const Key('setup-apply')));
      expect(find.textContaining('A drive is recording: it will contain both settings.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('setup-confirm-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('Stop the drive first stops it and unblocks', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await tester.runAsync(() => rig.tools.setup.applyRadioParams(const RadioParams(915800, 250000, 10, 5)));
      host.driveRecording = true;
      await openScreen(tester, host);
      await tapAndWait(tester, find.byKey(const Key('setup-stop-drive')));
      expect(host.stopDriveCalls, 1);
      expect(find.text('Drive in progress'), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const Key('setup-apply'))).onPressed, isNotNull);
    });
  });

  group('honesty', () {
    testWidgets('a radio that says OK and reads back different is shown as not changed, with the field named', (tester) async {
      final fake = FakeToolsRadio()
        ..selfInfo = SelfInfoFrame(
            advType: 1, txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: Uint8List(32), advLat: 0, advLon: 0, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'Liar');
      final host = FakeToolsHost()..toolsValue = RadioTools(fake, testArbiter());
      await openScreen(tester, host);
      await tester.enterText(find.byKey(const Key('setup-name-field')), 'New name');
      await tester.pump();
      await tapAndWait(tester, find.byKey(const Key('setup-name-save')));
      expect(find.textContaining('reads back differently: name'), findsOneWidget);
      expect(find.text('Not changed as asked'), findsOneWidget);
      expect(find.byKey(const Key('setup-undo')), findsNothing);
    });

    testWidgets('a radio that will not report its settings: a clear problem and a retry, no half screen', (tester) async {
      final fake = FakeToolsRadio();
      final host = FakeToolsHost()..toolsValue = RadioTools(fake, testArbiter());
      await openScreen(tester, host);
      expect(find.text('Could not read the radio'), findsOneWidget);
      expect(find.byKey(const Key('setup-name')), findsNothing);
      fake.selfInfo = SelfInfoFrame(advType: 1, txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: Uint8List(32), advLat: 0, advLon: 0, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'Back');
      await tapAndWait(tester, find.byKey(const Key('setup-retry')));
      expect(find.byKey(const Key('setup-name')), findsOneWidget);
    });
  });

  group('looks', () {
    testWidgets('phone, small phone at 2.5x, tablet, light and dark: no overflow, tap targets 48 px', (tester) async {
      final (rig, host) = await connectedRig(tester);
      await tester.runAsync(() => rig.tools.setup.applyRadioParams(const RadioParams(915800, 250000, 10, 5)));
      host.driveRecording = true;
      await forEachLook(tester, () => const RadioSetupScreen(), () => host, (tester) async {
        await settle(tester);
        expect(find.byKey(const Key('setup-list')), findsOneWidget);
        // walk the whole list a page at a time so every card is laid out and checked
        final list = find.byKey(const Key('setup-list'));
        for (var i = 0; i < 14; i++) {
          expectTapTargets(tester);
          await tester.drag(list, const Offset(0, -350));
          await tester.pump();
        }
      });
    });

    testWidgets('screen reader: sections are headings, switches and the apply button have words', (tester) async {
      final (rig, host) = await connectedRig(tester);
      final sem = tester.ensureSemantics();
      await openScreen(tester, host);
      expect(find.bySemanticsLabel('Name'), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Include the position in adverts')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Apply radio parameters')), findsWidgets);
      expect(rig.radio.sentFrames, isNotEmpty);
      sem.dispose();
    });
  });
}
