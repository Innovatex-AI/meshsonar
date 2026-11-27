// More > Observers (ID step 5): offers (accept / decline / owned), a phone's "show my radio's name" switch, a fixed observer's
// rename and position (through the claim PATCH), release with a confirm, the 404 / error / empty states, light and dark,
// phone and iPad widths, large text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/person_observers.dart';
import 'package:meshsonar/ui/account/person_observers_screen.dart';
import 'package:meshsonar/ui/widgets.dart' show ErrorBanner;

import 'radio_proof_app_test.dart' as rp show open, openScreen, settle, ProofHarness;

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _on = SiteConfig(region: _region, capabilities: {'nodeClaims', 'radioProof'});
final _fixedKey = 'ab' * 32, _phoneKey = 'cd' * 32, _offerKey = 'ef' * 32, _noRadioKey = '12' * 32;

FixedObserver _fixed({String? publicName = 'Hilltop North', ObserverPosition pos = ObserverPosition.rounded1km, bool? positionPublic = true}) => FixedObserver(
      key: _fixedKey,
      name: 'Hilltop North',
      publicName: publicName,
      nodeName: 'HT1',
      method: ClaimMethod.signature,
      iata: 'CMH',
      lastHeardAt: DateTime.utc(2026, 11, 22, 9),
      positionPublic: positionPublic,
      position: pos,
      health: const ObserverHealth(state: 'deaf', batteryMv: 3630, batteryLow: true, batteryTrend: 'falling'),
    );

PhoneObserver _phone({bool show = false, bool once = true, String? radioName = 'Truck Radio', String? key}) => PhoneObserver(
      key: key ?? _phoneKey,
      name: 'MeshSonar phone 212DE2',
      deviceId: 'd1',
      deviceName: 'iPhone',
      installs: 2,
      lastHeardAt: DateTime.utc(2026, 11, 22, 9, 5),
      mode: 'drive',
      radioKey: radioName == null ? null : 'aa' * 32,
      radioName: radioName,
      feeds: const ['phone', 'broker'],
      showRadioName: show,
      countedOnce: once,
    );

ObserverOffer get _offer => ObserverOffer(
    key: _offerKey, name: 'Barn Observer', iata: 'CMH', offeredByKey: 'aa' * 32, offeredByName: 'Hilltop', firstSeenAt: DateTime.utc(2026, 11, 10, 10), lastSeenAt: DateTime.utc(2026, 11, 22));

Future<rp.ProofHarness> _open(WidgetTester tester, {PersonObservers? data, Object? error}) async {
  final h = await rp.open(tester, caps: _on, connect: false);
  if (data != null) h.proof.observerList = data;
  h.proof.observersError = error;
  await rp.openScreen(tester, const PersonObserversScreen());
  await rp.settle(tester, () => h.proof.wire.contains('person-observers'));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  group('lists', () {
    testWidgets('offers, a fixed observer and a phone are shown in the site\'s words', (tester) async {
      await _open(tester, data: PersonObservers([_fixed(), _phone()], [_offer]));
      expect(find.text('Needs your answer'), findsOneWidget);
      expect(
          find.text('Is Barn Observer (CMH) yours?'), findsOneWidget, reason: 'the question comes first, alone on its line');
      expect(find.textContaining('Its login names your radio Hilltop as its owner, since Nov 10, 2026'), findsOneWidget);
      expect(find.byKey(Key('offer-accept-$_offerKey')), findsOneWidget);
      expect(find.byKey(Key('offer-decline-$_offerKey')), findsOneWidget);

      expect(find.text('Hilltop North'), findsOneWidget);
      expect(find.textContaining("Proof: Proved with the radio's own key"), findsOneWidget);
      expect(find.text('Area CMH'), findsOneWidget);
      expect(find.textContaining('Last heard Nov 22, 2026'), findsNWidgets(2));
      expect(find.text('It calls itself "HT1".'), findsOneWidget);
      expect(find.textContaining('Deaf'), findsOneWidget);
      expect(find.textContaining('Battery 3.63 V (low), falling'), findsOneWidget);
      expect(find.text('Its position is shown rounded to about 1 km.'), findsOneWidget);

      expect(find.text('MeshSonar phone 212DE2'), findsOneWidget);
      expect(find.text('On iPhone'), findsOneWidget);
      expect(find.text('Mode: Drive'), findsOneWidget);
      expect(find.textContaining('installed 2 times. It also publishes through its radio. It counts as one observer.'), findsOneWidget);
      expect(find.text('Reports through the app and its radio (MQTT)'), findsOneWidget, reason: 'plain words, not "the MQTT broker through its radio"');
      expect(find.text('Off: listed as "MeshSonar phone 212DE2".'), findsOneWidget);
      expect(find.textContaining('Show my radio\'s name in public (Truck Radio)'), findsOneWidget);
      // the long privacy text is folded behind one line; a tap opens it
      expect(find.textContaining('A phone is listed under a pseudonym'), findsNothing);
      expect(find.text('Never your name. Never a phone\'s exact position.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('person-observers-public-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('person-observers-public-toggle')));
      await tester.pumpAndSettle();
      expect(find.textContaining('A phone is listed under a pseudonym'), findsOneWidget);
    });

    testWidgets('countedOnce false shows no "counts as one" note; a login claim that named its owner says so', (tester) async {
      await _open(tester, data: PersonObservers([
        _phone(once: false),
        FixedObserver(key: _fixedKey, name: 'Barn', method: ClaimMethod.login, named: true, positionPublic: false, position: ObserverPosition.hidden),
      ], const []));
      expect(find.textContaining('It counts as one observer'), findsNothing);
      expect(find.text('It named you as its owner and you agreed'), findsOneWidget);
      expect(find.text('No area yet'), findsOneWidget);
      expect(find.text('Not heard yet'), findsOneWidget);
      expect(find.text('Its position is not shown anywhere.'), findsOneWidget);
    });

    testWidgets('empty: no observers', (tester) async {
      await _open(tester, data: PersonObservers.empty);
      expect(find.byKey(const Key('person-observers-empty')), findsOneWidget);
      expect(find.text('Needs your answer'), findsNothing);
    });

    testWidgets('no key or email is shown', (tester) async {
      await _open(tester, data: PersonObservers([_fixed(), _phone()], [_offer]));
      expect(find.textContaining('x-driver-key'), findsNothing);
      expect(find.textContaining('ms_'), findsNothing);
    });
  });

  group('offers', () {
    testWidgets('accept sends the call and the offer goes away', (tester) async {
      final h = await _open(tester, data: PersonObservers(const [], [_offer]));
      await tester.tap(find.byKey(Key('offer-accept-$_offerKey')));
      await rp.settle(tester, () => h.proof.wire.contains('offer $_offerKey accept'));
      expect(find.byKey(Key('offer-$_offerKey')), findsNothing);
    });

    testWidgets('decline sends the call', (tester) async {
      final h = await _open(tester, data: PersonObservers(const [], [_offer]));
      await tester.tap(find.byKey(Key('offer-decline-$_offerKey')));
      await rp.settle(tester, () => h.proof.wire.contains('offer $_offerKey decline'));
      expect(find.byKey(Key('offer-$_offerKey')), findsNothing);
    });

    testWidgets('409 owned: someone else already owns it, in words', (tester) async {
      final h = await _open(tester, data: PersonObservers(const [], [_offer]));
      h.proof.offerError = const CmatException('Another owner already holds this observer. MeshSonar never takes one over.', status: 409, code: 'owned');
      await tester.tap(find.byKey(Key('offer-accept-$_offerKey')));
      await rp.settle(tester, () => h.proof.wire.contains('offer $_offerKey accept'));
      expect(find.text('Another owner already holds this observer, so it cannot be added.'), findsOneWidget);
      expect(find.byKey(Key('offer-$_offerKey')), findsOneWidget);
    });

    testWidgets('404 not_found on an offer is said in words', (tester) async {
      final h = await _open(tester, data: PersonObservers(const [], [_offer]));
      h.proof.offerError = const CmatException('There is no such offer for you', status: 404, code: 'not_found');
      await tester.tap(find.byKey(Key('offer-decline-$_offerKey')));
      await rp.settle(tester, () => h.proof.wire.contains('offer $_offerKey decline'));
      expect(find.text('There is no such offer for you'), findsOneWidget);
    });
  });

  group('phone switch', () {
    testWidgets('turning it on sends the pref and the switch stays on', (tester) async {
      final h = await _open(tester, data: PersonObservers([_phone()], const []));
      await tester.tap(find.byKey(Key('phone-show-name-$_phoneKey')));
      await rp.settle(tester, () => h.proof.wire.contains('pref $_phoneKey true'));
      expect(tester.widget<SwitchListTile>(find.byKey(Key('phone-show-name-$_phoneKey'))).value, isTrue);
    });

    testWidgets('a failure puts the switch back and says why', (tester) async {
      final h = await _open(tester, data: PersonObservers([_phone()], const []));
      h.proof.prefError = const CmatException('No such phone observer', status: 404, code: 'not_found');
      await tester.tap(find.byKey(Key('phone-show-name-$_phoneKey')));
      await rp.settle(tester, () => h.proof.wire.contains('pref $_phoneKey true'));
      expect(tester.widget<SwitchListTile>(find.byKey(Key('phone-show-name-$_phoneKey'))).value, isFalse);
      expect(find.text('No such phone observer'), findsOneWidget);
    });

    testWidgets('no radio known: the switch is off and disabled, with the hint', (tester) async {
      final h = await _open(tester, data: PersonObservers([_phone(radioName: null, key: _noRadioKey)], const []));
      final sw = tester.widget<SwitchListTile>(find.byKey(Key('phone-show-name-$_noRadioKey')));
      expect(sw.onChanged, isNull);
      expect(find.textContaining('Connect your radio in the app once'), findsOneWidget);
      expect(h.proof.wire.where((w) => w.startsWith('pref')), isEmpty);
    });
  });

  group('fixed observer', () {
    testWidgets('rename and hide the position: only the changed keys go to the claim PATCH', (tester) async {
      final h = await _open(tester, data: PersonObservers([_fixed()], const []));
      await tester.tap(find.byKey(Key('observer-edit-$_fixedKey')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const Key('observer-edit-name'))).controller!.text, 'Hilltop North');
      await tester.enterText(find.byKey(const Key('observer-edit-name')), 'Hilltop East');
      await tester.tap(find.byKey(const Key('observer-edit-position')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('observer-edit-save')));
      await rp.settle(tester, () => h.proof.wire.any((w) => w.startsWith('claim-update')));
      expect(h.proof.wire, contains('claim-update $_fixedKey displayName=Hilltop East,positionPublic=false'));
    });

    testWidgets('clearing the name sends null (the radio\'s own name)', (tester) async {
      final h = await _open(tester, data: PersonObservers([_fixed()], const []));
      await tester.tap(find.byKey(Key('observer-edit-$_fixedKey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('observer-edit-name')), '  ');
      await tester.tap(find.byKey(const Key('observer-edit-save')));
      await rp.settle(tester, () => h.proof.wire.any((w) => w.startsWith('claim-update')));
      expect(h.proof.wire, contains('claim-update $_fixedKey displayName=null'));
    });

    testWidgets('saving without a change makes no call', (tester) async {
      final h = await _open(tester, data: PersonObservers([_fixed()], const []));
      await tester.tap(find.byKey(Key('observer-edit-$_fixedKey')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('observer-edit-save')));
      await rp.settle(tester, () => false);
      expect(h.proof.wire.where((w) => w.startsWith('claim-')), isEmpty);
    });

    testWidgets('release asks first: cancel does nothing, confirm releases and the card goes', (tester) async {
      final h = await _open(tester, data: PersonObservers([_fixed()], const []));
      await tester.tap(find.byKey(Key('observer-release-$_fixedKey')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('observer-release-sheet')), findsOneWidget);
      expect(find.textContaining('It keeps feeding data exactly as before'), findsOneWidget);
      await tester.tap(find.byKey(const Key('observer-release-cancel')));
      await tester.pumpAndSettle();
      expect(h.proof.wire.where((w) => w.startsWith('claim-release')), isEmpty);
      await tester.tap(find.byKey(Key('observer-release-$_fixedKey')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('observer-release-confirm')));
      await rp.settle(tester, () => h.proof.wire.contains('claim-release $_fixedKey'));
      expect(find.byKey(Key('observer-$_fixedKey')), findsNothing);
    });

    testWidgets('a failed save is said in words', (tester) async {
      final h = await _open(tester, data: PersonObservers([_fixed()], const []));
      h.proof.claimError = const CmatException('slow', status: 429);
      await tester.tap(find.byKey(Key('observer-edit-$_fixedKey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('observer-edit-name')), 'X');
      await tester.tap(find.byKey(const Key('observer-edit-save')));
      await rp.settle(tester, () => h.proof.wire.any((w) => w.startsWith('claim-update')));
      expect(find.byType(ErrorBanner), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('404: the server does not offer the list, with Try again', (tester) async {
      final h = await _open(tester, error: const CmatException('not found', status: 404));
      expect(find.text('The server does not offer the observer list right now.'), findsOneWidget);
      expect(find.byKey(const Key('person-observers-empty')), findsNothing);
      h.proof.observersError = null;
      h.proof.observerList = PersonObservers([_phone()], const []);
      await tester.tap(find.byKey(const Key('person-observers-retry')));
      await rp.settle(tester, () => h.proof.wire.where((w) => w == 'person-observers').length > 1);
      expect(find.text('The server does not offer the observer list right now.'), findsNothing);
      expect(find.text('MeshSonar phone 212DE2'), findsOneWidget);
    });

    testWidgets('offline: a plain error and no empty state', (tester) async {
      await _open(tester, error: const CmatException('network error: down'));
      expect(find.textContaining('Could not load your observers'), findsOneWidget);
      expect(find.byKey(const Key('person-observers-empty')), findsNothing);
    });

    testWidgets('loading shows a spinner before the first answer', (tester) async {
      final h = await rp.open(tester, caps: _on, connect: false);
      await rp.openScreen(tester, const PersonObserversScreen());
      expect(h.state.personObservers.loadedOnce || find.byType(CircularProgressIndicator).evaluate().isNotEmpty, isTrue);
      await rp.settle(tester, () => h.state.personObservers.loadedOnce);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('looks', () {
    for (final dark in [false, true]) {
      for (final size in [const Size(390, 844), const Size(1024, 1366)]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${size.width.toInt()} dp, ${scale}x text, ${dark ? 'dark' : 'light'}: lays out with no overflow', (tester) async {
            tester.view.physicalSize = size * 2;
            tester.view.devicePixelRatio = 2;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
            await _open(tester, data: PersonObservers([_fixed(), _phone()], [_offer]));
            expect(tester.takeException(), isNull);
            expect(Theme.of(tester.element(find.byKey(const Key('person-observers-screen')))).brightness, dark ? Brightness.dark : Brightness.light);
            await tester.scrollUntilVisible(find.byKey(const Key('person-observers-website')), 300, scrollable: find.byType(Scrollable).first);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
