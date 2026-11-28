// Builder B: Owner link and RF tools against the fake radio, and every B screen at large text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/app_foreground.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/msradio/ms_b_firmware_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_lua_apps_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_map_pack_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_owner_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_rf_tools_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_screen_sounds_screen.dart';
import 'package:meshsonar/ui/msradio/ms_sections.dart';

import '../fakes.dart' show Harness;
import 'ms_b_test_kit.dart';

const String _other = '5f0a11b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e';

void main() {
  group('Owner link', () {
    forBothThemes((b) {
      testWidgets('renders the fixture state and the explanation (${b.name})', (t) async {
        msBPhone(t);
        final rig = await MsBRig.paired(t);
        await msBPump(t, MsBOwnerScreen(c: rig.c, radioProofOffered: true, knownRadios: const []), b: b);
        expect(find.byKey(const Key('msb-owner')), findsOneWidget);
        expect(find.text('Not linked'), findsOneWidget);
        expect(find.byKey(const Key('msb-owner-explain')), findsOneWidget);
        expect(find.textContaining('More > Observers'), findsOneWidget);
        await msBEnd(t, rig);
      });
    });

    testWidgets('hidden, with no request, when the server does not offer radio proof', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBOwnerScreen(c: rig.c, radioProofOffered: false));
      expect(find.byKey(const Key('msb-owner-hidden')), findsOneWidget);
      expect(find.byKey(const Key('msb-owner')), findsNothing);
      expect(rig.r.requests, isEmpty);
      await msBEnd(t, rig);
    });

    testWidgets('reads the capability from the app: off by default (no site config)', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final h = Harness();
      expect(h.state.radioProofOffered, isFalse);
      await msBPump(t, AppScope(state: h.state, child: msSectionScreen(MsSection.owner, rig.c)!));
      expect(find.byKey(const Key('msb-owner-hidden')), findsOneWidget);
      expect(rig.r.requests, isEmpty);
      await msBEnd(t, rig);
    });

    testWidgets('Link lists the person\'s radios without this radio, sends POST /owner; Remove link asks and clears', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(
          t,
          MsBOwnerScreen(c: rig.c, radioProofOffered: true, knownRadios: [
            MsBKnownRadio(key: rig.r.keyHex, label: 'This radio'),
            const MsBKnownRadio(key: _other, label: 'KE4BFI Base', detail: 'Key 5f0a11b2'),
          ]));
      await msBTap(t, find.byKey(const Key('msb-owner-link')));
      expect(find.byKey(const Key('msb-owner-pick')), findsOneWidget);
      expect(find.text('This radio'), findsNothing);
      await msBTap(t, find.text('KE4BFI Base'));
      expect(rig.api, contains('POST /owner'));
      expect(rig.bodies.last, 'key=$_other&name=KE4BFI+Base');
      expect(rig.r.ownerKey, _other);
      expect(find.text('Linked to KE4BFI Base'), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-owner-clear')));
      expect(find.byKey(const Key('msb-confirm-owner-clear')), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-confirm-owner-clear-ok')));
      expect(rig.api, contains('POST /owner/clear'));
      expect(rig.r.ownerKey, isNull);
      expect(find.text('Not linked'), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('no known radios: says how to prove one', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBOwnerScreen(c: rig.c, radioProofOffered: true, knownRadios: const []));
      await msBTap(t, find.byKey(const Key('msb-owner-link')));
      expect(find.byKey(const Key('msb-owner-none')), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('the radio\'s refusal text is shown', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['POST /api/app/v1/owner'] = (400, '{"error":"That key cannot be the owner.","status":400}');
      await msBPump(t, MsBOwnerScreen(c: rig.c, radioProofOffered: true, knownRadios: const [MsBKnownRadio(key: _other, label: 'Base')]));
      await msBTap(t, find.byKey(const Key('msb-owner-link')));
      await msBTap(t, find.text('Base'));
      expect(find.text('That key cannot be the owner.'), findsOneWidget);
      await msBEnd(t, rig);
    });
  });

  group('RF tools', () {
    forBothThemes((b) {
      testWidgets('renders presets, the scan from the fixture and the probe results (${b.name})', (t) async {
        msBPhone(t);
        final rig = await MsBRig.paired(t);
        rig.overrides['GET /api/app/v1/spectrum'] = (200, '{"scanning":true,"bins_available":true,'
            '"scan":{"f0":902.000,"f1":928.000,"step":0.200,"n":131,"sweeps":4,"seq":7,"last":[-118.5,-120.0,null],"peak":[-110.0,-112.5,null]}}');
        await msBPump(t, msSectionScreen(MsSection.rfTools, rig.c)!, b: b);
        expect(find.byKey(const Key('msb-rf')), findsOneWidget);
        expect(find.text('US 902-928'), findsOneWidget);
        expect(find.text('Around the mesh frequency'), findsOneWidget);
        expect(find.text('EU 863-870'), findsOneWidget);
        expect(find.byKey(const Key('msb-rf-chart')), findsOneWidget);
        expect(find.text('Scanning: 902 to 928 MHz, 4 sweeps.'), findsOneWidget);
        expect(find.byKey(const Key('msb-rf-stop')), findsOneWidget);
        expect(find.byKey(const Key('msb-rf-pause-note')), findsOneWidget);
        // probes fixture
        expect(find.text('3 nodes'), findsOneWidget);
        expect(find.text('+9.5 dB'), findsOneWidget);
        expect(find.text('-90 dBm'), findsOneWidget);
        expect(find.textContaining('Repeater 5f0a11b2 answered in 840 ms'), findsOneWidget);
        expect(find.textContaining('Node 5f0a11b2 (repeater)'), findsOneWidget);
        await msBEnd(t, rig);
      });
    });

    testWidgets('Start sends the band, step and duration; polls while scanning; Stop', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBRfToolsScreen(c: rig.c));
      expect(find.byKey(const Key('msb-rf-chart')), findsNothing);
      await msBTap(t, find.byKey(const Key('msb-rf-start')));
      expect(rig.api, contains('POST /spectrum/start'));
      expect(rig.bodies, contains('f0=902.0&f1=928.0&step=0.2&seconds=15'));
      expect(find.byKey(const Key('msb-rf-chart')), findsOneWidget);
      final before = rig.api.where((q) => q == 'GET /spectrum').length;
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      expect(rig.api.where((q) => q == 'GET /spectrum').length, before + 1);
      await msBTap(t, find.byKey(const Key('msb-rf-stop')));
      expect(rig.api, contains('POST /spectrum/stop'));
      final after = rig.api.where((q) => q == 'GET /spectrum').length;
      await t.pump(const Duration(seconds: 6));
      expect(rig.api.where((q) => q == 'GET /spectrum').length, after, reason: 'no polling once stopped');
      await msBEnd(t, rig);
    });

    testWidgets('polling pauses while the app is in the background and comes back in front', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.r.scanning = true;
      await msBPump(t, MsBRfToolsScreen(c: rig.c));
      int polls() => rig.api.where((q) => q == 'GET /spectrum').length;
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      final n = polls();
      AppForeground.set(false);
      addTearDown(() => AppForeground.set(true));
      await t.pump(const Duration(seconds: 8));
      expect(polls(), n, reason: 'no polling in the background');
      AppForeground.set(true);
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      expect(polls(), n + 1);
      rig.r.scanning = false;
      await msBEnd(t, rig);
    });

    testWidgets('"Around the mesh frequency" scans the radio\'s frequency +-2 MHz', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBRfToolsScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-rf-band-mesh')));
      await msBTap(t, find.byKey(const Key('msb-rf-start')));
      expect(rig.bodies, contains('f0=908.525&f1=912.525&step=0.2&seconds=15'));
      await msBTap(t, find.byKey(const Key('msb-rf-stop')));
      await msBEnd(t, rig);
    });

    test('steps stay within the radio\'s 1024-step limit', () {
      expect(MsBScanLimits.stepsFor(902, 928, 0.2), 131);
      expect(MsBScanLimits.stepsFor(902, 928, 0.025) > MsBScanLimits.maxSteps, isTrue);
      expect(MsBScanLimits.stepsFor(863, 870, 0.025) <= MsBScanLimits.maxSteps, isTrue);
    });

    testWidgets('firmware without scan data says so', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['GET /api/app/v1/spectrum'] = (200, '{"scanning":false,"bins_available":false,"scan":null}');
      await msBPump(t, MsBRfToolsScreen(c: rig.c));
      expect(find.text('This firmware does not report scan data yet.'), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('Probe now, then /probes about 10 s and 20 s later', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBRfToolsScreen(c: rig.c));
      final n0 = rig.api.where((q) => q.startsWith('GET /probes')).length;
      await msBTap(t, find.byKey(const Key('msb-rf-probe')));
      expect(rig.api, contains('POST /probe/now'));
      expect(find.byKey(const Key('msb-rf-probe-note')), findsOneWidget);
      await t.pump(const Duration(seconds: 10));
      await msBSettle(t);
      expect(rig.api.where((q) => q.startsWith('GET /probes')).length, n0 + 1);
      await t.pump(const Duration(seconds: 10));
      await msBSettle(t);
      expect(rig.api.where((q) => q.startsWith('GET /probes')).length, n0 + 2);
      expect(t.widget<FilledButton>(find.byKey(const Key('msb-rf-probe'))).onPressed, isNotNull);
      await msBEnd(t, rig);
    });

    testWidgets('the radio\'s refusal text is shown (probe while scanning)', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.r.scanning = true;
      await msBPump(t, MsBRfToolsScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-rf-probe')));
      expect(find.text('The spectrum scan is on.'), findsOneWidget);
      rig.r.scanning = false;
      await msBEnd(t, rig);
    });
  });

  group('large text (2.0) and narrow phone: no overflow', () {
    final screens = <String, Widget Function(MsBRig rig)>{
      'map pack': (r) => MsBMapPackScreen(c: r.c),
      'firmware': (r) => MsBFirmwareScreen(c: r.c),
      'lua apps': (r) => MsBLuaAppsScreen(c: r.c),
      'lua upload': (r) => MsBLuaUploadScreen(c: r.c),
      'screen and sounds': (r) => MsBScreenSoundsScreen(c: r.c),
      'owner': (r) => MsBOwnerScreen(c: r.c, radioProofOffered: true, knownRadios: const []),
      'rf tools': (r) => MsBRfToolsScreen(c: r.c),
    };
    for (final e in screens.entries) {
      for (final b in Brightness.values) {
        testWidgets('${e.key} (${b.name})', (t) async {
          msBPhone(t, width: 320, height: 6000);
          final rig = await MsBRig.paired(t);
          rig.r.scanning = true; // RF tools draws the chart
          await msBPump(t, e.value(rig), b: b, textScale: 2.0);
          expect(t.takeException(), isNull);
          rig.r.scanning = false;
          await msBEnd(t, rig);
        });
      }
    }

    testWidgets('iPad width', (t) async {
      msBPhone(t, width: 1024, height: 3000);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBScreenSoundsScreen(c: rig.c), textScale: 1.5);
      expect(t.takeException(), isNull);
      await msBEnd(t, rig);
    });
  });
}
