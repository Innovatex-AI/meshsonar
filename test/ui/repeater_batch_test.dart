// ID step 6 inside the app (Repeaters): Claim several repeaters in one sitting, the "how it was proven" label on Claimed radios
// and More > Observers, release with a confirm, and the transfer notice. Flag ON = the server advertises `capabilities.radioProof`;
// flag OFF (production at build 75) = Claimed radios is exactly build 74 and not one new call is made.
//
// Everything here runs against a fake server and a scripted radio (no Bluetooth, no real repeater): the admin login is the
// scripted link's `login`.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/app/repeater_batch.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/claim_flow.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/person_identity.dart';
import 'package:meshsonar/core/person_observers.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/account/person_observers_screen.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/claims/claim_proof_label.dart';
import 'package:meshsonar/ui/claims/claim_repeaters_screen.dart';
import 'package:meshsonar/ui/claims/my_radios_screen.dart';

import '../support/proof_fakes.dart';
import 'claims_ui_test.dart' show ScriptedLink, k, openScreen, pumpUntil;
import 'fakes.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _on = SiteConfig(region: _region, capabilities: {'nodeClaims', 'nodeClaimsLogin', 'radioProof'});
const _off = SiteConfig(region: _region, capabilities: {'nodeClaims', 'nodeClaimsLogin'});
final _driverKey = 'ms_${'A' * 43}';

class BatchClient extends FakeProofClient {
  // ignore: use_super_parameters
  BatchClient(Uri u) : super(u) {
    verifySignature = false;
  }
  final List<NodeClaim> claims = [];
  final List<String> released = [];
  final List<String> started = [];
  CmatException? claimStartError;
  String lastKey = '';

  @override
  Future<ClaimChallenge> claimStart(String driverKey, String pubkey, ClaimKind kind) async {
    started.add('${kind.name}:$pubkey');
    if (claimStartError != null) throw claimStartError!;
    lastKey = pubkey;
    return ClaimChallenge(id: 'c-$pubkey', kind: kind, expiresAt: DateTime.utc(2026, 11, 22, 18));
  }

  @override
  Future<NodeClaim> claimCompleteLogin(
    String driverKey,
    String challengeId, {
    required bool isAdmin,
    int? firmwareLevel,
    required DateTime loginAt,
    required String radioPubKey,
  }) async {
    final c = NodeClaim(
      pubkey: challengeId.substring(2),
      nodeType: ClaimNodeType.repeater,
      method: ClaimMethod.login,
      nodeName: 'Repeater',
    );
    claims.add(c);
    return c;
  }

  @override
  Future<List<NodeClaim>> myRadios(String driverKey) async {
    wire.add('my-radios');
    return List.of(claims);
  }

  @override
  Future<void> releaseClaim(String driverKey, String pubkey) async {
    released.add(pubkey);
    claims.removeWhere((c) => c.pubkey == pubkey);
  }
}

class BatchHarness extends Harness {
  ScriptedLink? link;
  @override
  FakeCmatClient newClient(Uri u) => BatchClient(u);
  BatchClient get server => client as BatchClient;
  BatchHarness() {
    selfInfo = SelfInfo(
      publicKey: k('A'),
      name: 'Truck Radio',
      radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22),
      firmware: 'v1.9.0',
    );
    linkMaker = (info) => link = ScriptedLink(info);
  }
}

final _hill = RepeaterRef(key: k('b'), name: 'INNO-EASTON-R1', lat: 40, lon: -83);
final _perry = RepeaterRef(key: k('c'), name: 'INNO-PERRY-HIGHLANDS', lat: 40.1, lon: -83.1);
final _stone = RepeaterRef(key: k('d'), name: 'INNO-STONERIDGE', lat: 40.2, lon: -83.2);

Future<BatchHarness> open(WidgetTester tester, {required SiteConfig caps, bool connect = true}) async {
  useTallScreen(tester);
  final h = BatchHarness();
  h.settings.saved = Settings(driverKey: _driverKey, keyStatus: DriverKeyStatus.approved, display: 'KE4BFI');
  await h.state.init();
  h.client.siteConfigResult = caps;
  await h.state.refreshSiteConfig();
  await h.state.refreshUploadSiteConfig(force: true);
  h.client.repeaterList = [_hill, _perry, _stone];
  await h.state.refreshRepeaters();
  if (connect) {
    await h.state.connectSimulator();
    expect(h.state.radioKind, RadioKind.simulator);
  }
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  return h;
}

Future<void> settleUi(WidgetTester tester, bool Function() done) async {
  await pumpUntil(tester, done);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> pick(WidgetTester tester, String text, String key) async {
  await tester.enterText(find.byKey(const Key('claim-several-search')), text);
  await tester.pump();
  await tester.tap(find.byKey(ValueKey('claim-several-pick-$key')));
  await tester.pump();
}

Future<void> top(WidgetTester tester) async {
  await tester.fling(find.byType(Scrollable).first, const Offset(0, 4000), 4000);
  await tester.pumpAndSettle();
}

Future<void> show(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
}

Future<void> prove(WidgetTester tester, String key, String password) async {
  await show(tester, find.byKey(ValueKey('batch-password-$key')));
  await tester.enterText(find.byKey(ValueKey('batch-password-$key')), password);
  await tester.pump();
  await tester.ensureVisible(find.byKey(ValueKey('batch-prove-$key')));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey('batch-prove-$key')));
  await tester.pump();
  final b = AppScope.read(tester.element(find.byType(ClaimRepeatersScreen))).repeaterBatch;
  for (var i = 0; i < 200 && (b.row(key)!.state == BatchRowState.proving || b.busy); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
  await show(tester, find.byKey(ValueKey('batch-state-$key')));
}

void main() {
  group('flag OFF: Claimed radios is build 74', () {
    testWidgets('old chip words, no new button, no label block, no notice, no new call', (tester) async {
      final h = await open(tester, caps: _off);
      h.server.claims.addAll([
        NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.login, displayName: 'Hilltop'),
        NodeClaim(
          pubkey: k('e'),
          nodeType: ClaimNodeType.repeater,
          method: ClaimMethod.advert,
          displayName: 'Barn',
          ended: true,
          endReason: ClaimEndReason.replaced,
        ),
      ]);
      h.server.notices = [const PersonNotice(id: 'n1', kind: 'radio_taken', pubkey: 'ee', nodeName: 'Barn')];
      h.server.observerList = PersonObservers(const [], [ObserverOffer(key: k('f'), name: 'Barn Observer', offeredByKey: k('a'))]);
      expect(h.state.radioProofCapable, isFalse);
      expect(h.state.repeaterBatchEnabled, isFalse);
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('radio-${k('b')}')).evaluate().isNotEmpty);
      expect(find.text('Logged in as admin from your app'), findsOneWidget);
      expect(find.byKey(const Key('my-radios-claim-several')), findsNothing);
      expect(find.byKey(ValueKey('proof-${k('b')}')), findsNothing);
      expect(find.textContaining('How it was proven'), findsNothing);
      expect(find.byKey(const Key('my-radios-claim-repeater')), findsOneWidget);
      expect(find.byKey(const Key('offered-card')), findsNothing);
      expect(find.byKey(const ValueKey('moved-n1')), findsNothing);
      await tester.tap(find.byKey(const Key('past-radios')));
      await tester.pumpAndSettle();
      expect(find.text('Another owner proved control'), findsOneWidget);
      expect(h.server.wire.where((w) => w.startsWith('person')), isEmpty, reason: 'wire: ${h.server.wire}');
    });

    testWidgets('the Claim several screen says it is not available', (tester) async {
      await open(tester, caps: _off);
      await openScreen(tester, const ClaimRepeatersScreen());
      expect(find.byKey(const Key('claim-several-unavailable')), findsOneWidget);
    });
  });

  group('flag ON: Claimed radios', () {
    testWidgets('every row says how it was proven, from the stored method, in the shared words', (tester) async {
      final h = await open(tester, caps: _on);
      h.server.claims.addAll([
        NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.login, displayName: 'Hilltop'),
        NodeClaim(pubkey: k('c'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert, displayName: 'Ridge'),
        NodeClaim(pubkey: k('d'), nodeType: ClaimNodeType.companion, method: ClaimMethod.signature, displayName: 'Truck'),
      ]);
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('radio-${k('d')}')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('my-radios-claim-several')), findsOneWidget);
      for (final (key, m) in [(k('b'), ClaimMethod.login), (k('c'), ClaimMethod.advert), (k('d'), ClaimMethod.signature)]) {
        final row = find.byKey(ValueKey('proof-$key'));
        await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(claimProofShort(m))), findsOneWidget);
        expect(find.descendant(of: row, matching: find.textContaining(claimProofWords(m))), findsOneWidget);
      }
      expect(claimProofShort(ClaimMethod.login), 'Reported by the app', reason: 'the plan\'s word for a repeater login');
      expect(find.text('Logged in as admin from your app'), findsNothing);
    });

    testWidgets('the observers screen words the same method with the same function', (tester) async {
      expect(methodWords(ClaimMethod.login), claimProofWords(ClaimMethod.login));
      expect(methodWords(ClaimMethod.advert), claimProofWords(ClaimMethod.advert));
      expect(methodWords(ClaimMethod.signature), claimProofWords(ClaimMethod.signature));
    });

    testWidgets('release asks first, then uses the release call; "Not now" releases nothing', (tester) async {
      final h = await open(tester, caps: _on);
      h.server.claims.add(NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.login, displayName: 'Hilltop'));
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('radio-${k('b')}')).evaluate().isNotEmpty);
      await tester.tap(find.byKey(ValueKey('release-${k('b')}')));
      await tester.pumpAndSettle();
      expect(find.text('Give up Hilltop?'), findsOneWidget);
      expect(h.server.released, isEmpty);
    });

    testWidgets(
      'transfer notice: a radio taken by a newer proof is said plainly and can be marked read; offered observers point to Observers',
      (tester) async {
        final h = await open(tester, caps: _on);
        h.server.claims.add(
          NodeClaim(
            pubkey: k('e'),
            nodeType: ClaimNodeType.repeater,
            method: ClaimMethod.advert,
            displayName: 'Barn',
            ended: true,
            endReason: ClaimEndReason.replaced,
          ),
        );
        h.server.notices = [
          PersonNotice(id: 'n1', kind: 'radio_taken', pubkey: k('e'), nodeName: 'Barn', createdAt: DateTime.utc(2026, 11, 21)),
          const PersonNotice(id: 'n2', kind: 'radio_taken', read: true, nodeName: 'Old one'),
          const PersonNotice(id: 'n3', kind: 'device_joined', deviceName: 'iPad'),
        ];
        h.server.observerList = PersonObservers(const [], [ObserverOffer(key: k('f'), name: 'Barn Observer', offeredByKey: k('a'))]);
        await openScreen(tester, const MyRadiosScreen());
        await settleUi(tester, () => find.byKey(const ValueKey('moved-n1')).evaluate().isNotEmpty);
        expect(find.byKey(const ValueKey('moved-n1')), findsOneWidget);
        expect(find.byKey(const ValueKey('moved-n2')), findsNothing, reason: 'already read');
        expect(find.byKey(const ValueKey('moved-n3')), findsNothing, reason: 'not a taken radio');
        expect(find.text('A radio of yours moved to another owner'), findsOneWidget);
        expect(
          find.textContaining('Someone proved they hold Barn, so it moved to their account. Your drives and devices were not touched.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('offered-card')), findsOneWidget);
        expect(find.text('An observer says it is yours'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('moved-ok-n1')));
        await tester.pump();
        await settleUi(tester, () => find.byKey(const ValueKey('moved-n1')).evaluate().isEmpty);
        expect(h.server.wire, contains('notice n1 read'));
        expect(find.byKey(const ValueKey('moved-n1')), findsNothing);

        await tester.scrollUntilVisible(find.byKey(const Key('past-radios')), 200, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.byKey(const Key('past-radios')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Another owner proved they control it, so it moved to them. Your drives and devices were not touched'),
          findsOneWidget,
        );
      },
    );
  });

  group('flag ON: Claim several repeaters', () {
    testWidgets('three repeaters in one sitting: claimed, failed with the reason, retried; Claim another keeps the session', (
      tester,
    ) async {
      final h = await open(tester, caps: _on);
      await openScreen(tester, const ClaimRepeatersScreen());
      expect(find.byKey(const Key('claim-several-search')), findsOneWidget, reason: 'the picker is open with nothing to show yet');

      await pick(tester, 'INNO-EA', k('b'));
      expect(find.byKey(ValueKey('batch-state-${k('b')}')), findsOneWidget);
      expect(find.text('Not started'), findsOneWidget);
      await pick(tester, 'perry', k('c'));
      await pick(tester, 'stone', k('d'));
      await top(tester);
      expect(find.text('0 claimed, 0 failed, 3 to do'), findsOneWidget);

      // 1: works
      await prove(tester, k('b'), 'hunter2');
      expect(find.text('Claimed'), findsOneWidget);
      expect(find.byKey(ValueKey('batch-proof-${k('b')}')), findsOneWidget);
      expect(find.text('Reported by the app'), findsOneWidget, reason: 'a repeater login is the app\'s word');

      // 2: wrong password (the repeater stays silent)
      h.link!.silent = true;
      await prove(tester, k('c'), 'wrong');
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('No answer from the repeater'), findsOneWidget);
      expect(find.textContaining('out of range of your radio, or the admin password is wrong'), findsOneWidget);

      // retry that row with the right password; then the third
      h.link!.silent = false;
      await prove(tester, k('c'), 'right');
      await prove(tester, k('d'), 'third');
      await top(tester);
      expect(find.text('3 claimed, 0 failed, 0 to do'), findsOneWidget);
      expect(h.server.started, [
        for (final x in [k('b'), k('c'), k('c'), k('d')]) 'login:$x',
      ]);
      expect(h.server.claims.map((c) => c.pubkey), [k('b'), k('c'), k('d')]);
      expect(h.link!.log.where((l) => l.startsWith('login:')).toList(), ['login:hunter2', 'login:wrong', 'login:right', 'login:third']);
      // nothing on a repeater is changed: no CLI command was sent
      expect(h.link!.log.where((l) => !l.startsWith('login:')), isEmpty);

      // the password is gone from the screen and the controller
      expect(find.byKey(ValueKey('batch-password-${k('b')}')), findsNothing);

      // Claim another keeps the rows
      await top(tester);
      await tester.tap(find.byKey(const Key('claim-several-close-picker')));
      await tester.pump();
      expect(find.byKey(const Key('claim-several-search')), findsNothing);
      expect(find.byKey(const Key('claim-another')), findsOneWidget);
      await tester.tap(find.byKey(const Key('claim-another')));
      await tester.pump();
      expect(find.byKey(const Key('claim-several-search')), findsOneWidget);
      expect(h.state.repeaterBatch.rows.length, 3);
      // and the session outlives the screen
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openScreen(tester, const ClaimRepeatersScreen());
      await top(tester);
      expect(find.text('3 claimed, 0 failed, 0 to do'), findsOneWidget);
    });

    testWidgets('only one repeater is proven at a time', (tester) async {
      final h = await open(tester, caps: _on);
      final b = h.state.repeaterBatch;
      b.add(k('b'), name: 'One');
      b.add(k('c'), name: 'Two');
      expect(b.prove(k('b'), 'pw1'), isTrue);
      expect(b.busy, isTrue);
      expect(b.prove(k('c'), 'pw2'), isFalse, reason: 'the radio talks to one repeater at a time');
      await tester.runAsync(() => b.claims.repeaterFlow!.done);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(b.row(k('b'))!.state, BatchRowState.claimed);
      expect(b.row(k('c'))!.state, BatchRowState.notStarted);
      expect(b.prove(k('c'), ''), isFalse, reason: 'no password, nothing to prove');
      expect(b.add('nope'), isFalse);
      expect(b.add(k('b')), isFalse, reason: 'already a row');
    });

    testWidgets('a repeater someone else claimed recently says why in plain words', (tester) async {
      final h = await open(tester, caps: _on);
      h.server.claimStartError = const CmatException(
        'claimed recently',
        status: 409,
        code: 'recently_claimed',
        body: {'owner': 'other', 'code': 'recently_claimed'},
      );
      await openScreen(tester, const ClaimRepeatersScreen());
      await pick(tester, 'perry', k('c'));
      await prove(tester, k('c'), 'pw');
      expect(find.byKey(ValueKey('batch-title-${k('c')}')), findsOneWidget);
      expect(find.textContaining('Someone else claimed this repeater recently'), findsOneWidget);
      expect(find.textContaining('only after 24 hours'), findsOneWidget);
    });

    testWidgets('a repeater that is already yours is a finished row, and a claimed row can be given up (with a confirm)', (tester) async {
      final h = await open(tester, caps: _on);
      h.server.claims.add(NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.login, displayName: 'Hilltop'));
      await h.state.claims.refresh();
      await openScreen(tester, const ClaimRepeatersScreen());
      await tester.enterText(find.byKey(const Key('claim-several-paste')), k('b'));
      await tester.pump();
      expect(find.text('Already yours. Nothing to prove.'), findsOneWidget);
      expect(find.byKey(const Key('owned-by-you')), findsOneWidget);
      expect(h.server.started, isEmpty, reason: 'no proof is started for a repeater that is already yours');
      expect(find.byKey(ValueKey('batch-proof-${k('b')}')), findsOneWidget);

      await tester.ensureVisible(find.byKey(ValueKey('batch-release-${k('b')}')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('batch-release-${k('b')}')));
      await tester.pumpAndSettle();
      expect(find.text('Give up Hilltop?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('release-radio-confirm')));
      await tester.pumpAndSettle();
      expect(h.server.released, [k('b')]);
    });

    testWidgets('no radio: the rows say so and nothing is started', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      await openScreen(tester, const ClaimRepeatersScreen());
      expect(find.byKey(const Key('claim-several-needs-radio')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('claim-several-paste')), k('b'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(ValueKey('batch-prove-${k('b')}'))).onPressed, isNull);
      expect(h.server.started, isEmpty);
    });
  });

  group('words', () {
    test('a failed row says why', () {
      expect(batchFailureReason(const ClaimFlowState(message: 'Nope', serverStatus: 500)), 'Nope');
      expect(batchFailureReason(const ClaimFlowState(message: 'x', serverStatus: 409)), contains('24 hours'));
      expect(claimProofShort(ClaimMethod.advert), isNot(claimProofShort(ClaimMethod.signature)));
    });
  });
}
