// Visual check for ID steps 2 and 3 (radio proof at connect, More > Devices, More > Account), drawn by the real screens over
// the test fakes (the server flag is OFF on production, so the live app cannot show them yet). Prints "SCREEN <name>" lines for
// scripts/verify_sim.sh to screenshot:
//   HARNESS=1 FLOW_TEST=integration_test/id_visual_test.dart scripts/verify_sim.sh <worktree> <out>
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/person_identity.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/account/devices_screen.dart';
import 'package:meshsonar/ui/app.dart';

import '../test/support/proof_fakes.dart';
import '../test/ui/claims_ui_test.dart' show ScriptedLink, k;
import '../test/ui/fakes.dart';
import 'screens.dart';

class _H extends Harness {
  _H() : super(antennaProfile: true) {
    selfInfo = SelfInfo(
        publicKey: k('A'), name: 'Truck Radio', radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22), firmware: 'v1.9.0');
    linkMaker = (info) => ScriptedLink(info);
  }
  @override
  FakeCmatClient newClient(Uri u) => FakeProofClient(u)..verifySignature = false;
  FakeProofClient get proof => client as FakeProofClient;
}

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');

Future<_H> _open(WidgetTester t, {required bool flag}) async {
  final h = _H();
  h.settings.saved = Settings(driverKey: 'ms_${'A' * 43}', keyStatus: DriverKeyStatus.approved, display: 'KE4BFI');
  await h.state.init();
  h.client.siteConfigResult = SiteConfig(region: _region, capabilities: {'nodeClaims', if (flag) 'radioProof'});
  await h.state.refreshSiteConfig();
  await h.state.refreshUploadSiteConfig(force: true);
  await t.pumpWidget(MeshSonarApp(state: h.state));
  await pumpFor(t, const Duration(seconds: 2));
  return h;
}

Future<void> _push(WidgetTester t, Widget w) async {
  t.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => w));
  await pumpFor(t, const Duration(seconds: 2));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ID steps 2 and 3 screens', (t) async {
    // ---- flag OFF (production today): the old screens ----
    var h = await _open(t, flag: false);
    await _push(t, const DevicesScreen());
    await shot(t, 'id-off-devices-old');
    await popToRoots(t);
    await openTab(t, 'Settings');
    await t.scrollUntilVisible(find.byKey(const Key('masked-key')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first);
    await shot(t, 'id-off-account');

    // ---- flag ON ----
    h = await _open(t, flag: true);
    h.proof.notices = [
      PersonNotice(id: 'n1', kind: 'join_request', createdAt: DateTime.now().subtract(const Duration(minutes: 3)), pubkey: k('a'), nodeName: 'Truck Radio', deviceName: 'iPad'),
      PersonNotice(id: 'n2', kind: 'device_joined', createdAt: DateTime.now().subtract(const Duration(days: 1)), read: true, deviceName: 'Old iPhone'),
    ];
    h.proof.devices = [
      PersonDevice(id: 'd1', name: 'iPhone', model: 'iPhone17,1', appBuild: '73', os: 'iOS 27.2', current: true, lastSeenAt: DateTime.now()),
      PersonDevice(id: 'd2', name: 'Kitchen iPad', nameSet: true, model: 'iPad16,3', appBuild: '72', os: 'iPadOS 27.2', lastSeenAt: DateTime.now().subtract(const Duration(days: 2))),
      PersonDevice(id: 'd3', name: 'MeshMapper import', kind: 'meshmapper', lastSeenAt: DateTime.now().subtract(const Duration(days: 9))),
    ];
    await popToRoots(t);
    await openTab(t, 'Settings');
    await t.scrollUntilVisible(find.byKey(const Key('add-to-account')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first);
    await shot(t, 'id-on-account');
    await popToRoots(t);
    await _push(t, const DevicesScreen());
    await shot(t, 'id-on-devices');
    await t.drag(find.byKey(const Key('person-devices-screen')), const Offset(0, -500));
    await shot(t, 'id-on-devices-scrolled');
    await popToRoots(t);

    // radio proof: the question, then a device that cannot join
    h.proof
      ..answer = ProofKind.ownedByOther
      ..askFirst = true;
    await h.state.connectSimulator();
    expect(h.state.radioKind, RadioKind.simulator);
    expect(await waitFor(t, find.byKey(const Key('radio-proof-sheet'))), isTrue);
    await shot(t, 'id-on-is-that-you');
    await t.tap(find.byKey(const Key('radio-proof-later')));
    await pumpFor(t, const Duration(seconds: 1));
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
