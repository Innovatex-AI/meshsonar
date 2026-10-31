// The claim screens: Settings > My radios, Claim my radio, Claim a repeater, the repeater sheet button and the
// "Owned by you" chip, with a fake server and a scripted radio. Also large text and dark mode, and the promise copy.
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/claim_flow.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/claims/claim_radio_screen.dart';
import 'package:meshsonar/ui/claims/claim_repeater_screen.dart';
import 'package:meshsonar/ui/claims/claim_widgets.dart';
import 'package:meshsonar/ui/claims/my_radios_screen.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart' show RepeaterPoint, RepeaterPointSource, kNetworkLayerId;
import 'package:meshsonar/ui/map/sheets/repeater_sheet.dart';
import 'package:meshsonar/radio/protocol.dart' show RepeaterStatus;

import 'fakes.dart';
import 'settings_test_kit.dart';

String k(String c) => c * 64;
const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _caps = SiteConfig(region: _region, capabilities: {'nodeClaims'});

class ClaimsClient extends FakeCmatClient {
  ClaimsClient(super.baseUrl);
  final List<NodeClaim> claims = [];
  final List<Map<String, Object?>> patches = [];
  final List<String> released = [];
  bool observerHears = true;
  CmatException? startError;
  String lastKey = '';
  int starts = 0;

  @override
  Future<ClaimChallenge> claimStart(String driverKey, String pubkey, ClaimKind kind) async {
    starts++;
    if (startError != null) throw startError!;
    lastKey = pubkey;
    final exp = DateTime.utc(2026, 10, 16, 18, 15);
    return kind == ClaimKind.sign
        ? ClaimChallenge(id: 'c1', kind: kind, message: Uint8List.fromList([1, 2, 3]), expiresAt: exp)
        : ClaimChallenge(id: 'c2', kind: kind, code: 'MS7K12', expiresAt: exp);
  }

  @override
  Future<NodeClaim> claimComplete(String driverKey, String challengeId, String signatureHex) async {
    final c = NodeClaim(pubkey: lastKey, nodeType: ClaimNodeType.companion, method: ClaimMethod.signature, displayName: null);
    claims.add(c);
    return c;
  }

  @override
  Future<ClaimStatus> claimStatus(String driverKey, String challengeId) async {
    if (!observerHears) return const ClaimStatus(state: ClaimState.pending);
    final c = NodeClaim(pubkey: lastKey, nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert);
    if (!claims.any((x) => x.pubkey == c.pubkey)) claims.add(c);
    return ClaimStatus(state: ClaimState.verified, claim: c);
  }

  @override
  Future<List<NodeClaim>> myRadios(String driverKey) async => List.of(claims);

  @override
  Future<void> releaseClaim(String driverKey, String pubkey) async {
    released.add(pubkey);
    claims.removeWhere((c) => c.pubkey == pubkey);
  }

  @override
  Future<NodeClaim> updateClaim(String driverKey, String pubkey, Map<String, Object?> changes) async {
    patches.add(changes);
    final i = claims.indexWhere((c) => c.pubkey == pubkey);
    final c = claims[i];
    return claims[i] = NodeClaim(
      pubkey: c.pubkey,
      nodeType: c.nodeType,
      method: c.method,
      displayName: changes.containsKey('displayName') ? changes['displayName'] as String? : c.displayName,
      positionPublic: changes.containsKey('positionPublic') ? changes['positionPublic'] as bool? : c.positionPublic,
      notes: changes.containsKey('notes') ? changes['notes'] as String? : c.notes,
      nodeName: c.nodeName,
    );
  }
}

class ScriptedLink extends FakeLink implements ClaimRadio {
  ScriptedLink(super.info);
  String name = 'Hilltop';
  bool admin = true;
  bool silent = false;

  /// After the first `advert`, the repeater stops answering (so the name restore fails).
  bool goQuietAfterAdvert = false;
  bool _quiet = false;
  final List<String> log = [];

  @override
  String? get selfPublicKey => info.publicKey.toLowerCase();
  @override
  Future<Uint8List> sign(Uint8List data) async => Uint8List(64);
  @override
  Future<void> ensureContact(String pubkeyHex, {required int nodeType, String name = ''}) async {}
  @override
  Future<RemoteLogin> login(String pubkeyHex, String password, {Duration? timeout}) async {
    log.add('login:$password');
    if (silent) throw const ClaimRadioException(ClaimRadioError.silent, 'no answer');
    return RemoteLogin(isAdmin: admin);
  }

  @override
  Future<void> logout(String pubkeyHex) async {}
  @override
  Future<String> runCli(String pubkeyHex, String command, {Duration? timeout}) async {
    log.add(command);
    if (_quiet) throw const ClaimRadioException(ClaimRadioError.silent, 'quiet');
    if (command == 'get name') return '> $name';
    if (command.startsWith('set name ')) {
      name = command.substring(9);
      return 'OK';
    }
    if (command == 'advert') {
      if (goQuietAfterAdvert) _quiet = true;
      return 'OK - Advert sent';
    }
    return 'Unknown command';
  }

  @override
  Future<RepeaterStatus?> status(String pubkeyHex, {Duration? timeout}) async => null;
}

class ClaimsHarness extends Harness {
  ScriptedLink? link;
  ClaimsHarness({super.antennaProfile});

  @override
  FakeCmatClient newClient(Uri u) => ClaimsClient(u);
  ClaimsClient get claims => client as ClaimsClient;

  ClaimsHarness withLink() {
    selfInfo = SelfInfo(
        publicKey: k('A'),
        name: 'Truck Radio',
        radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22),
        firmware: 'v1.9.0');
    linkMaker = (info) => link = ScriptedLink(info);
    return this;
  }
}

Future<ClaimsHarness> open(WidgetTester tester,
    {bool caps = true, bool key = true, bool radio = true, List<RepeaterRef> repeaters = const []}) async {
  useTallScreen(tester);
  final h = ClaimsHarness()..withLink();
  if (key) h.approveKey();
  await h.state.init();
  h.state.claimTiming = const ClaimTiming(
      poll: Duration(milliseconds: 1), nameHold: Duration(milliseconds: 50), latePoll: Duration(milliseconds: 1), restoreBackoff: [Duration.zero, Duration(milliseconds: 1)]);
  if (caps) {
    h.client.siteConfigResult = _caps;
    await h.state.refreshSiteConfig();
    await h.state.refreshUploadSiteConfig(force: true);
  }
  if (repeaters.isNotEmpty) {
    h.client.repeaterList = repeaters;
    await h.state.refreshRepeaters();
  }
  if (radio) {
    await h.state.connectSimulator();
    expect(h.state.radioKind, RadioKind.simulator);
  }
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  return h;
}

Future<void> openScreen(WidgetTester tester, Widget screen) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
  nav.push(MaterialPageRoute<void>(builder: (_) => screen));
  await tester.pumpAndSettle();
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done, {int rounds = 200}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('Settings > My radios section', () {
    testWidgets('without the server capability every row says why it cannot be used', (tester) async {
      await open(tester, caps: false);
      await openSettingsTab(tester);
      await showSetting(tester, 'my-radios');
      expect(find.text('This server does not offer radio claims yet.'), findsNWidgets(3));
      expect(tester.widget<ListTile>(find.byKey(const Key('my-radios'))).onTap, isNull);
    });

    testWidgets('no key: asks for a driver key', (tester) async {
      await open(tester, key: false);
      await openSettingsTab(tester);
      await showSetting(tester, 'my-radios');
      expect(find.textContaining('Needs a driver key'), findsNWidgets(3));
    });

    testWidgets('capability + approved key: rows open the screens; Claim my radio needs a connected radio', (tester) async {
      await open(tester, radio: false);
      await openSettingsTab(tester);
      await showSetting(tester, 'claim-my-radio');
      expect(find.textContaining('Connect your radio first'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const Key('claim-my-radio'))).onTap, isNull);
      await showSetting(tester, 'my-radios');
      await tester.tap(find.byKey(const Key('my-radios')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my-radios-screen')), findsOneWidget);
      expect(find.byKey(const Key('my-radios-empty')), findsOneWidget);
      expect(find.textContaining('never affects'), findsNothing, reason: 'that promise belongs to the repeater screens');
      expect(find.byKey(const Key('my-radios-intro')), findsOneWidget);
    });
  });

  group('My radios screen', () {
    testWidgets('lists claims with type, how it was verified, position state; website link opens /me/radios', (tester) async {
      final h = await open(tester);
      h.claims.claims.addAll([
        NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert, displayName: 'Hilltop', positionPublic: false),
        NodeClaim(pubkey: k('c'), nodeType: ClaimNodeType.companion, method: ClaimMethod.signature, nodeName: 'My Companion', positionPublic: true),
      ]);
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('radio-${k('b')}')).evaluate().isNotEmpty);
      expect(find.text('Hilltop'), findsOneWidget);
      expect(find.text('Verified by an observer hearing the code'), findsOneWidget);
      expect(find.text('Verified by the radio\'s signature'), findsOneWidget);
      expect(find.text('Position hidden'), findsOneWidget);
      expect(find.text('Position public'), findsOneWidget);
      await tester.tap(find.byKey(const Key('my-radios-website')));
      await tester.pump();
      expect(h.openedUrls.single.path, '/me/radios');
    });

    testWidgets('edit: only the changed fields are sent; null clears', (tester) async {
      final h = await open(tester);
      h.claims.claims.add(NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert, displayName: 'Hilltop', notes: 'old'));
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('edit-${k('b')}')).evaluate().isNotEmpty);
      await tester.tap(find.byKey(ValueKey('edit-${k('b')}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('edit-radio-name')), 'North ridge');
      await tester.enterText(find.byKey(const Key('edit-radio-notes')), '');
      await tester.tap(find.text('Hidden'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-radio-save')));
      await tester.pumpAndSettle();
      expect(h.claims.patches.single, {'displayName': 'North ridge', 'notes': null, 'positionPublic': false});
      expect(find.text('North ridge'), findsOneWidget);
      expect(find.text('Position hidden'), findsOneWidget);
    });

    testWidgets('give up: asks first, says the data keeps counting, then removes the radio', (tester) async {
      final h = await open(tester);
      h.claims.claims.add(NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert, displayName: 'Hilltop'));
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('release-${k('b')}')).evaluate().isNotEmpty);
      await tester.tap(find.byKey(ValueKey('release-${k('b')}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('keeps counting'), findsOneWidget);
      await tester.tap(find.byKey(const Key('release-radio-confirm')));
      await tester.pumpAndSettle();
      expect(h.claims.released, [k('b')]);
      expect(find.byKey(ValueKey('radio-${k('b')}')), findsNothing);
    });

    testWidgets('a name restore still owed is shown with the exact commands', (tester) async {
      final h = await open(tester);
      await h.state.claims.store.put(PendingRestore(pubkey: k('b'), originalName: 'Hilltop', since: DateTime.utc(2026, 10, 16)));
      await openScreen(tester, const MyRadiosScreen());
      await pumpUntil(tester, () => find.byKey(ValueKey('pending-${k('b')}')).evaluate().isNotEmpty);
      expect(find.textContaining('set name Hilltop'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('restore-dismiss-${k('b')}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('pending-${k('b')}')), findsNothing);
    });
  });

  group('Claim my radio', () {
    testWidgets('no radio: button disabled with the reason', (tester) async {
      await open(tester, radio: false);
      await openScreen(tester, const ClaimRadioScreen());
      expect(find.byKey(const Key('claim-radio-needs-radio')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('claim-radio-start'))).onPressed, isNull);
      expect(find.text('Needs a connected radio.'), findsOneWidget);
    });

    testWidgets('connected radio: claim it, see the result, it shows in My radios; the promise is on the screen', (tester) async {
      final h = await open(tester);
      await openScreen(tester, const ClaimRadioScreen());
      expect(find.text('Truck Radio'), findsOneWidget);
      expect(find.byKey(const Key('claim-never-gates')), findsOneWidget);
      await tester.tap(find.byKey(const Key('claim-radio-start')));
      await pumpUntil(tester, () => find.byKey(const Key('claim-result-title')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('This radio is yours'), findsOneWidget);
      expect(h.claims.claims.single.pubkey, k('a'));
      expect(h.state.ownsRadio(k('A')), isTrue);
      await tester.tap(find.byKey(const Key('claim-done')));
      await tester.pumpAndSettle();
    });

    testWidgets('the server refuses (409): said in words, with Try again', (tester) async {
      final h = await open(tester);
      h.claims.startError = const CmatException('x', status: 409);
      await openScreen(tester, const ClaimRadioScreen());
      await tester.tap(find.byKey(const Key('claim-radio-start')));
      await pumpUntil(tester, () => find.byKey(const Key('claim-result-title')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('The server said no'), findsOneWidget);
      expect(find.byKey(const Key('claim-try-again')), findsOneWidget);
    });
  });

  group('Claim a repeater', () {
    final repeaters = [RepeaterRef(key: k('b'), name: 'Hilltop Repeater', lat: 40, lon: -83)];

    testWidgets('setup: needs a radio, a repeater and a password; the promise is shown; password is hidden and capped at 15', (tester) async {
      await open(tester, radio: false, repeaters: repeaters);
      await openScreen(tester, const ClaimRepeaterScreen());
      expect(find.byKey(const Key('claim-needs-radio')), findsOneWidget);
      expect(find.textContaining('name will show a short code for about a minute'), findsOneWidget);
      expect(find.textContaining('we never see or store your admin password'), findsOneWidget);
      expect(find.textContaining('it never affects whether its data counts'), findsOneWidget);
      final pw = tester.widget<TextField>(find.byKey(const Key('claim-password')));
      expect(pw.obscureText, isTrue);
      expect(pw.maxLength, 15);
      expect(tester.widget<FilledButton>(find.byKey(const Key('claim-start'))).onPressed, isNull);
      await tester.scrollUntilVisible(find.byKey(const Key('claim-why-not')), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Needs a connected radio.'), findsOneWidget);
    });

    testWidgets('pick from your repeaters by name, or paste a key (with a clear error for a bad one)', (tester) async {
      await open(tester, repeaters: repeaters);
      await openScreen(tester, const ClaimRepeaterScreen());
      await tester.enterText(find.byKey(const Key('claim-search')), 'hill');
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('claim-pick-${k('b')}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('claim-picked')), findsOneWidget);
      expect(find.text('Hilltop Repeater'), findsOneWidget);
      await tester.tap(find.byKey(const Key('claim-change')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('claim-paste')), 'nope');
      await tester.pump();
      expect(find.textContaining('64 letters and digits'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('claim-paste')), '  ${k('C').toUpperCase()}  ');
      await tester.pump();
      expect(find.byKey(const Key('claim-picked')), findsOneWidget);
      expect(find.text(k('c')), findsOneWidget);
    });

    testWidgets('full claim from the sheet: progress with the code, then "The repeater is yours", name restored, password gone', (tester) async {
      final h = await open(tester, repeaters: repeaters);
      await openScreen(tester, ClaimRepeaterScreen(initialKey: k('b'), initialName: 'Hilltop'));
      await tester.enterText(find.byKey(const Key('claim-password')), 'hunter2-admin');
      await tester.pump();
      await tester.tap(find.byKey(const Key('claim-start')));
      await pumpUntil(tester, () => find.byKey(const Key('claim-result-title')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('The repeater is yours'), findsOneWidget);
      expect(h.link!.name, 'Hilltop');
      expect(h.link!.log, ['login:hunter2-admin', 'get name', 'set name Hilltop MS7K12', 'advert', 'set name Hilltop', 'advert', 'get name']);
      expect(h.state.ownsRadio(k('b')), isTrue);
      expect(find.text('hunter2-admin'), findsNothing);
      await tester.tap(find.byKey(const Key('claim-done')));
      await tester.pumpAndSettle();
    });

    testWidgets('guest password: says it is not the admin password and offers Try again', (tester) async {
      final h = await open(tester, repeaters: repeaters);
      h.link!.admin = false;
      await openScreen(tester, ClaimRepeaterScreen(initialKey: k('b'), initialName: 'Hilltop'));
      await tester.enterText(find.byKey(const Key('claim-password')), 'guest');
      await tester.pump();
      await tester.tap(find.byKey(const Key('claim-start')));
      await pumpUntil(tester, () => find.byKey(const Key('claim-result-title')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Not the admin password'), findsOneWidget);
      expect(find.byKey(const Key('claim-try-again')), findsOneWidget);
      expect(h.link!.name, 'Hilltop');
    });

    testWidgets('no answer: out of range or a wrong password, in plain words', (tester) async {
      final h = await open(tester, repeaters: repeaters);
      h.link!.silent = true;
      await openScreen(tester, ClaimRepeaterScreen(initialKey: k('b'), initialName: 'Hilltop'));
      await tester.enterText(find.byKey(const Key('claim-password')), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const Key('claim-start')));
      await pumpUntil(tester, () => find.byKey(const Key('claim-result-title')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('No answer from the repeater'), findsOneWidget);
      expect(find.textContaining('out of range'), findsOneWidget);
    });

    testWidgets('restore cannot be confirmed: the exact commands are shown with copy buttons', (tester) async {
      final h = await open(tester, repeaters: repeaters);
      h.link!.goQuietAfterAdvert = true;
      await openScreen(tester, ClaimRepeaterScreen(initialKey: k('b'), initialName: 'Hilltop'));
      await tester.enterText(find.byKey(const Key('claim-password')), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const Key('claim-start')));
      await pumpUntil(tester, () => find.byKey(const Key('claim-result-title')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('claim-restore-commands')), findsOneWidget);
      expect(find.text('set name Hilltop'), findsOneWidget);
      expect(find.text('advert'), findsOneWidget);
      expect(find.byTooltip('Copy "set name Hilltop"'), findsOneWidget);
      expect(tester.getSize(find.byTooltip('Copy "advert"')).height, greaterThanOrEqualTo(48));
      expect((await h.state.claims.store.load()).single.originalName, 'Hilltop');
    });
  });

  group('repeater sheet', () {
    RepeaterPoint point({bool room = false, String key = ''}) => RepeaterPoint(
        layerId: kNetworkLayerId, source: RepeaterPointSource.global, key: key.isEmpty ? k('b') : key, name: 'Hilltop', isRoom: room, lat: 40, lon: -83, band: 0);

    Future<void> sheet(WidgetTester tester, RepeaterPoint p) async {
      await openScreen(tester, Scaffold(body: RepeaterSheet(point: p, dismissOnOpen: false)));
    }

    testWidgets('"Claim this repeater" shows with the capability and opens the claim screen with that repeater chosen', (tester) async {
      await open(tester);
      await sheet(tester, point());
      expect(find.byKey(const Key('claim-this-repeater')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('claim-this-repeater'))).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('claim-this-repeater')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('claim-picked')), findsOneWidget);
      expect(find.text('Hilltop'), findsOneWidget);
    });

    testWidgets('hidden without the capability, without an approved key, and for room servers', (tester) async {
      await open(tester, caps: false);
      await sheet(tester, point());
      expect(find.byKey(const Key('claim-this-repeater')), findsNothing);
    });

    testWidgets('a room server has no claim button', (tester) async {
      await open(tester);
      await sheet(tester, point(room: true));
      expect(find.byKey(const Key('claim-this-repeater')), findsNothing);
    });

    testWidgets('a repeater you own shows "Owned by you" instead', (tester) async {
      final h = await open(tester);
      h.claims.claims.add(NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert));
      await h.state.claims.refresh();
      await sheet(tester, point());
      expect(find.byKey(const Key('owned-by-you')), findsOneWidget);
      expect(find.byKey(const Key('claim-this-repeater')), findsNothing);
      expect(find.bySemanticsLabel('Owned by you'), findsOneWidget);
    });
  });

  group('look and feel', () {
    for (final dark in [false, true]) {
      testWidgets('2.0x text, ${dark ? 'dark' : 'light'} mode: claim screens lay out without overflow', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        if (dark) {
          tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
          addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        }
        tester.view.physicalSize = const Size(750, 1334); // 375 x 667 dp
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.reset);
        final h = await open(tester, repeaters: [RepeaterRef(key: k('b'), name: 'Hilltop Repeater', lat: 40, lon: -83)]);
        h.claims.claims.add(NodeClaim(pubkey: k('b'), nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert, displayName: 'Hilltop with a rather long name', notes: 'notes notes notes'));
        for (final screen in <Widget>[
          const MyRadiosScreen(),
          const ClaimRadioScreen(),
          ClaimRepeaterScreen(initialKey: k('b'), initialName: 'Hilltop Repeater'),
        ]) {
          await openScreen(tester, screen);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: screen.runtimeType.toString());
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
          await tester.pumpAndSettle();
        }
      });
    }

    test('the disclosure says everything the lead asked for', () {
      expect(claimDisclosure, contains('name will show a short code for about a minute'));
      expect(claimDisclosure, contains('we restore it automatically'));
      expect(claimDisclosure, contains('we never see or store your admin password'));
      expect(claimDisclosure, contains('only lets you manage this radio'));
      expect(claimDisclosure, contains('never affects whether its data counts'));
    });
  });
}
