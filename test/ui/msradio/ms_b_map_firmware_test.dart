// Builder B: Map pack and Firmware screens against the fake radio (fixture JSON from APP-INTEGRATION.md).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/msradio/msradio.dart';
import 'package:meshsonar/platform/file_pick.dart';
import 'package:meshsonar/ui/msradio/ms_b_firmware_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_map_pack_screen.dart';
import 'package:meshsonar/ui/msradio/ms_sections.dart';

import 'ms_b_test_kit.dart';

void main() {
  group('Map pack', () {
    forBothThemes((b) {
      testWidgets('renders the pack from the fixture (${b.name})', (t) async {
        msBPhone(t);
        final rig = await MsBRig.paired(t);
        await msBPump(t, msSectionScreen(MsSection.mapPack, rig.c)!, b: b);
        expect(find.byKey(const Key('msb-maps')), findsOneWidget);
        expect(find.byKey(const Key('msb-maps-pack')), findsOneWidget);
        expect(find.text('Columbus'), findsOneWidget);
        expect(find.text('8 to 14 (opens at 12)'), findsOneWidget);
        expect(find.text('5321'), findsOneWidget);
        expect(find.text('3.9 MB'), findsOneWidget);
        expect(find.text('8.4 MB'), findsOneWidget); // 8192 KB free
        expect(rig.api, contains('GET /maps'));
        await msBEnd(t, rig);
      });
    });

    testWidgets('empty state when the partition has no pack', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['GET /api/app/v1/maps'] = (200, '{"partition":true,"space_kb":8192,"busy":false,"progress":0,"last_result":"","pack":null}');
      await msBPump(t, MsBMapPackScreen(c: rig.c));
      expect(find.byKey(const Key('msb-maps-empty')), findsOneWidget);
      expect(find.byKey(const Key('msb-maps-pack')), findsNothing);
      expect(find.byKey(const Key('msb-maps-send')), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('Send a map pack: picks .msmp, uploads to POST /maps?size=, shows the result', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final pick = FakeFilePick(file: FakeFilePick.bytes('cmh.msmp', [0x4d, 0x53, 0x4d, 0x50, ...List.filled(2044, 7)]));
      await msBPump(t, MsBMapPackScreen(c: rig.c, pick: pick));
      await msBTap(t, find.byKey(const Key('msb-maps-send')));
      expect(pick.lastExtensions, ['msmp']);
      expect(rig.r.requests, contains('POST /maps?size=2048'));
      expect(rig.r.uploadedBytes['/maps'], greaterThan(2048));
      expect(rig.api, contains('GET /status')); // follows status.maps
      expect(find.text('Done: 2 KB written.'), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('a wrong file type shows the picker\'s words; nothing is sent', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final pick = FakeFilePick(refuse: const FilePickRefused('Pick a .msmp file.'));
      await msBPump(t, MsBMapPackScreen(c: rig.c, pick: pick));
      await msBTap(t, find.byKey(const Key('msb-maps-send')));
      expect(find.text('Pick a .msmp file.'), findsOneWidget);
      expect(rig.r.uploadedBytes, isEmpty);
      await msBEnd(t, rig);
    });

    testWidgets('the radio\'s refusal text is shown', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['POST /maps'] = (400, '{"error":"Not a map pack (no MSMP header).","status":400}');
      final pick = FakeFilePick(file: FakeFilePick.bytes('x.msmp', [1, 2, 3]));
      await msBPump(t, MsBMapPackScreen(c: rig.c, pick: pick));
      await msBTap(t, find.byKey(const Key('msb-maps-send')));
      expect(find.text('Not a map pack (no MSMP header).'), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('polls status every 2 s while the radio writes, stops when done and on dispose', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['GET /api/app/v1/maps'] = (200, '{"partition":true,"space_kb":8192,"busy":true,"progress":40,"last_result":"","pack":null}');
      await msBPump(t, MsBMapPackScreen(c: rig.c));
      expect(find.byKey(const Key('msb-maps-writing')), findsOneWidget);
      rig.overrides['GET /api/app/v1/status'] = (200, '{"maps":{"busy":true,"progress":70}}');
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      expect(rig.api.where((q) => q == 'GET /status').length, 1);
      expect(find.text('The radio is writing the map pack: 70%'), findsOneWidget);
      rig.overrides['GET /api/app/v1/status'] = (200, '{"maps":{"busy":false,"progress":100}}');
      rig.overrides['GET /api/app/v1/maps'] = (200, '{"partition":true,"space_kb":4000,"busy":false,"progress":0,"last_result":"Done: 3819 KB written.","pack":{"name":"Columbus"}}');
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      expect(find.text('Done: 3819 KB written.'), findsOneWidget);
      final n = rig.r.requests.length;
      await t.pump(const Duration(seconds: 6));
      expect(rig.r.requests.length, n, reason: 'no polling once the radio is done');
      await msBEnd(t, rig);
    });
  });

  group('Firmware', () {
    forBothThemes((b) {
      testWidgets('renders version, board, slot and the offer (${b.name})', (t) async {
        msBPhone(t);
        final rig = await MsBRig.paired(t);
        await msBPump(t, msSectionScreen(MsSection.firmware, rig.c)!, b: b);
        expect(find.byKey(const Key('msb-firmware')), findsOneWidget);
        expect(find.text('0.1.0'), findsWidgets);
        expect(find.text('heltec_v4_touch'), findsOneWidget);
        expect(find.text('app0'), findsOneWidget);
        expect(find.byKey(const Key('msb-fw-offer')), findsOneWidget);
        expect(find.text('0.2.0 (build 12)'), findsOneWidget);
        expect(find.text('2.8 MB'), findsOneWidget);
        expect(find.text('Stable'), findsOneWidget);
        expect(find.text('Updated to MeshSonar 0.1.0.'), findsOneWidget);
        await msBEnd(t, rig);
      });
    });

    testWidgets('Check, Install, Beta and Daily check call the right routes', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBFirmwareScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-fw-check')));
      expect(rig.api, contains('POST /ota/check'));
      await msBTap(t, find.byKey(const Key('msb-fw-install')));
      expect(rig.api, contains('POST /ota/install'));
      await msBTap(t, find.byKey(const Key('msb-fw-beta')));
      expect(rig.api, contains('POST /ota/channel'));
      expect(rig.bodies, contains('beta=true'));
      expect(rig.r.beta, isTrue);
      await msBTap(t, find.byKey(const Key('msb-fw-auto')));
      expect(rig.api, contains('POST /ota/auto'));
      expect(rig.bodies, contains('on=false'));
      await t.pump(const Duration(seconds: 8)); // the grace polls after an action end
      await msBEnd(t, rig);
    });

    testWidgets('Restart asks first; Cancel sends nothing, Restart sends confirm=yes', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBFirmwareScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-fw-restart')));
      expect(find.byKey(const Key('msb-confirm-restart')), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-confirm-restart-cancel')));
      expect(rig.api, isNot(contains('POST /ota/restart')));
      await msBTap(t, find.byKey(const Key('msb-fw-restart')));
      await msBTap(t, find.byKey(const Key('msb-confirm-restart-ok')));
      expect(rig.api, contains('POST /ota/restart'));
      expect(rig.bodies, contains('confirm=yes'));
      await msBEnd(t, rig);
    });

    testWidgets('pending verify: "kept after 1 minute of running" with the seconds left; busy shows the radio\'s state text', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['GET /api/app/v1/ota'] = (
        200,
        '{"state":"downloading","state_text":"Downloading 0.2.0","busy":true,"progress":35,"fw":"0.2.0","board":"heltec_v4_touch",'
            '"slot":"app1","pending_verify":true,"valid_in_s":42,"offer":null}'
      );
      await msBPump(t, MsBFirmwareScreen(c: rig.c));
      expect(find.textContaining('kept after 1 minute of running'), findsOneWidget);
      expect(find.textContaining('42 s to go'), findsOneWidget);
      expect(find.text('Downloading 0.2.0: 35%'), findsOneWidget);
      expect(find.byKey(const Key('msb-fw-no-offer')), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      expect(rig.api.where((q) => q == 'GET /ota').length, greaterThanOrEqualTo(2), reason: 'polled while busy');
      await msBEnd(t, rig);
    });

    testWidgets('an offer that is not allowed says why and cannot be installed', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['GET /api/app/v1/ota'] = (
        200,
        '{"state":"idle","fw":"0.0.9","offer":{"newer":true,"allowed":false,"channel":"stable","version":"0.2.0","size":100,"min_version":"0.1.0"}}'
      );
      await msBPump(t, MsBFirmwareScreen(c: rig.c));
      expect(find.byKey(const Key('msb-fw-not-allowed')), findsOneWidget);
      expect(find.textContaining('needs version 0.1.0 or newer'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byKey(const Key('msb-fw-install'))).onPressed, isNull);
      await msBEnd(t, rig);
    });

    testWidgets('the radio\'s refusal text is shown', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['POST /api/app/v1/ota/check'] = (409, '{"error":"No internet on the radio\'s Wi-Fi.","status":409}');
      await msBPump(t, MsBFirmwareScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-fw-check')));
      expect(find.text('No internet on the radio\'s Wi-Fi.'), findsOneWidget);
      await t.pump(const Duration(seconds: 8));
      await msBEnd(t, rig);
    });

    testWidgets('Send a firmware file: picks .bin, asks, uploads to POST /update', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final pick = FakeFilePick(file: FakeFilePick.bytes('meshsonar-heltec-v4-touch-0.2.0.bin', List.filled(4096, 1)));
      await msBPump(t, MsBFirmwareScreen(c: rig.c, pick: pick));
      await msBTap(t, find.byKey(const Key('msb-fw-send')));
      expect(pick.lastExtensions, ['bin']);
      expect(find.byKey(const Key('msb-confirm-send-firmware')), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-confirm-send-firmware-ok')));
      expect(rig.r.requests, contains('POST /update'));
      expect(rig.r.uploadedBytes['/update'], greaterThan(4096));
      await t.pump(const Duration(seconds: 8));
      await msBEnd(t, rig);
    });
  });

  testWidgets('Not on Wi-Fi: the screens show the state with a retry instead of rows', (t) async {
    msBPhone(t);
    final rig = await MsBRig.paired(t);
    rig.r.offline = true;
    await rig.c.connect();
    await msBPump(t, MsBFirmwareScreen(c: rig.c));
    expect(find.byKey(const Key('msb-not-ready')), findsOneWidget);
    expect(find.text('Not on Wi-Fi'), findsOneWidget);
    expect(find.byKey(const Key('msb-retry')), findsOneWidget);
    await msBEnd(t, rig);
  });

  testWidgets('a 401 moves the screen to Pair again', (t) async {
    msBPhone(t);
    final rig = await MsBRig.paired(t);
    rig.r.revokeAll();
    await msBPump(t, MsBMapPackScreen(c: rig.c));
    expect(rig.c.state.step, MsLinkStep.notPaired);
    expect(find.text('Pair again'), findsOneWidget);
    await msBEnd(t, rig);
  });
}
