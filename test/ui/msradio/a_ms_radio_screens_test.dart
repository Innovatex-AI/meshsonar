// Build 78 (builder A): More > Radio's MeshSonar row (stock radio: no row, no request), the MeshSonar radio page, the
// pairing sheet, and builder A's sections (pairing, overview, sharing, log, paired apps) from fixture JSON in light and dark,
// and at large text.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/app_foreground.dart';
import 'package:meshsonar/core/msradio/msradio.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;
import 'package:meshsonar/ui/msradio/ms_log_screen.dart';
import 'package:meshsonar/ui/msradio/ms_overview_screen.dart';
import 'package:meshsonar/ui/msradio/ms_paired_apps_screen.dart';
import 'package:meshsonar/ui/msradio/ms_pairing_screen.dart';
import 'package:meshsonar/ui/msradio/ms_radio_host.dart';
import 'package:meshsonar/ui/msradio/ms_radio_page.dart';
import 'package:meshsonar/ui/msradio/ms_sharing_screen.dart';
import 'package:meshsonar/ui/shell/more_radio_screen.dart';
import 'package:meshsonar/ui/theme.dart';
import 'package:meshsonar/ui/tools/tool_kit.dart' show ToolMap;

import '../fakes.dart' show Harness;

RadioCaps capsFor(String ver) => RadioCaps.fromDeviceInfo(DeviceInfoFrame(firmwareVerCode: 10, firmwareVersion: ver, manufacturer: 'Heltec V4 TFT'));
final RadioCaps msCaps = capsFor('v1.18.0-ms0.1.0');
final RadioCaps stockCaps = capsFor('v1.18.0');
const Size phone = Size(393, 852);
const Size se = Size(375, 667);

/// The fake radio, but /status, /tokens and /log/records answer with the contract's example JSON (with this radio's key).
http.Client fixtureClient(FakeMsRadio r) => MockClient((req) async {
      final authed = (req.headers['Authorization'] ?? '').startsWith('Bearer ') && r.issuedTokens.contains(req.headers['Authorization']!.substring(7));
      final p = req.url.path;
      if (authed && req.method == 'GET') {
        final fixture = switch (p) {
          '/api/app/v1/status' => MsContractExamples.status.replaceAll('"A1B2..."', '"${r.keyHex.toUpperCase()}"'),
          '/api/app/v1/tokens' => MsContractExamples.tokens,
          '/api/app/v1/log/records' => MsContractExamples.logRecords.replaceAll('"end":false', '"end":true'),
          _ => null,
        };
        if (fixture != null) r.requests.add('GET $p (fixture)');
        if (fixture != null) return http.Response(fixture, 200, headers: {'content-type': 'application/json'});
      }
      return r.handle(req);
    });

/// Runs [f] to the end inside the test's fake clock (the controller's queue lives there: a real-async runAsync would never see
/// its microtasks).
Future<T> settle<T>(WidgetTester tester, Future<T> f) async {
  var done = false;
  late T v;
  Object? err;
  f.then((x) {
    v = x;
    done = true;
  }, onError: (Object e) {
    err = e;
    done = true;
  });
  for (var i = 0; i < 400 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (err != null) throw err!;
  expect(done, isTrue, reason: 'did not finish');
  return v;
}

/// Taps [f] and pumps until [until] finds something (or a while passes).
Future<void> tapUntil(WidgetTester tester, Finder f, Finder until, {Duration step = const Duration(milliseconds: 100)}) async {
  await reveal(tester, f);
  await tester.tap(f);
  for (var i = 0; i < 200 && until.evaluate().isEmpty; i++) {
    await tester.pump(step);
  }
  await tester.pumpAndSettle();
}

/// Scrolls the first list until [f] is built and fully on screen.
Future<void> reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 100, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

class Rig {
  final FakeMsRadio radio = FakeMsRadio();
  final InMemoryMsSecretKv secrets = InMemoryMsSecretKv();
  late final http.Client client = fixtureClient(radio);
  MsRadioController make({RadioCaps? caps, bool withSign = true}) => MsRadioController.forCaps(caps ?? msCaps,
      radioKey: radio.keyHex, sign: withSign ? radio.sign : null, client: client, browser: radio.browser, secrets: secrets)!;

  /// A controller that is already paired (token stored, connected).
  Future<MsRadioController> paired(WidgetTester tester) async {
    final t = radio.issueToken();
    await settle(tester, MsTokenStore(secrets).save(radio.keyHex, t));
    final c = make();
    await settle(tester, c.connect());
    expect(c.state.step, MsLinkStep.paired);
    return c;
  }
}

Future<void> pumpHome(WidgetTester tester, Widget home,
    {Brightness brightness = Brightness.light, Size size = phone, double scale = 1.0, Harness? h}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: meshSonarTheme(brightness).copyWith(platform: TargetPlatform.iOS),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: home,
  );
  if (h != null) {
    await h.state.init();
    await tester.pumpWidget(AppScope(state: h.state, child: app));
  } else {
    await tester.pumpWidget(app);
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    AppForeground.debugReset();
    ToolMap.tilesEnabled = false;
  });
  tearDown(() {
    MsRadioHost.instance.debugReset();
    MsLogScreen.debugDocs = null;
    MsLogScreen.debugShare = null;
    ToolMap.tilesEnabled = true;
    dismissAppToast();
  });

  group('More > Radio entry', () {
    testWidgets('stock radio: no MeshSonar row, no controller, no request to any local address', (tester) async {
      final rig = Rig();
      MsRadioHost.debugLink = (_) => MsRadioLink(caps: stockCaps, key: rig.radio.keyHex, sign: rig.radio.sign);
      MsRadioHost.debugMake = (l) => rig.make(caps: l.caps);
      await pumpHome(tester, MoreRadioScreen(onOpen: (_) {}), h: Harness());
      expect(find.byKey(const Key('more-radio-screen')), findsOneWidget);
      expect(find.byKey(const Key('more-meshsonar-radio')), findsNothing);
      expect(find.text('MeshSonar radio'), findsNothing);
      expect(MsRadioHost.instance.made, 0);
      expect(rig.radio.requests, isEmpty);
    });

    testWidgets('the app\'s own link (no MeshSonar radio connected): no row, nothing made', (tester) async {
      await pumpHome(tester, MoreRadioScreen(onOpen: (_) {}), h: Harness());
      expect(find.byKey(const Key('more-meshsonar-radio')), findsNothing);
      expect(MsRadioHost.instance.made, 0);
    });

    testWidgets('MeshSonar radio: the row with the version and the chip (one quiet connect)', (tester) async {
      final rig = Rig();
      MsRadioHost.debugLink = (_) => MsRadioLink(caps: msCaps, key: rig.radio.keyHex, sign: rig.radio.sign);
      MsRadioHost.debugMake = (l) => rig.make(caps: l.caps);
      await pumpHome(tester, MoreRadioScreen(onOpen: (_) {}), h: Harness());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('more-meshsonar-radio')), findsOneWidget);
      expect(find.text('MeshSonar radio'), findsOneWidget);
      expect(find.text('MeshSonar 0.1.0'), findsOneWidget);
      expect(find.byKey(const Key('ms-chip')), findsOneWidget);
      expect(find.text('Not paired'), findsOneWidget);
      expect(MsRadioHost.instance.made, 1);
      expect(rig.radio.requests.where((r) => r.startsWith('GET /api/app/v1/info')).length, 1);
      // opening the page
      await tester.tap(find.byKey(const Key('more-meshsonar-radio')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ms-radio-page')), findsOneWidget);
    });

    testWidgets('chip: Paired with a stored token, Not on Wi-Fi when the radio cannot be reached', (tester) async {
      final rig = Rig();
      final c = await rig.paired(tester);
      MsRadioHost.debugLink = (_) => MsRadioLink(caps: msCaps, key: rig.radio.keyHex);
      MsRadioHost.debugMake = (_) => c;
      await pumpHome(tester, MoreRadioScreen(onOpen: (_) {}), h: Harness());
      expect(find.text('Paired'), findsOneWidget);
      rig.radio.offline = true;
      await settle(tester, c.connect());
      await tester.pumpAndSettle();
      expect(find.text('Not on Wi-Fi'), findsOneWidget);
    });
  });

  group('MeshSonar radio page', () {
    testWidgets('lists the sections in order; Owner link only with radio proof; before pairing only Pairing opens', (tester) async {
      final rig = Rig();
      final c = rig.make();
      await settle(tester, c.connect());
      // no AppScope: the server's radio proof is not offered, so no Owner link row
      await pumpHome(tester, MsRadioPage(controller: c));
      expect(find.byKey(const Key('ms-radio-name')), findsOneWidget);
      expect(find.text('KE4BFI Mobile'), findsOneWidget);
      expect(find.text('Not paired'), findsOneWidget);
      final keys = ['pairing', 'overview', 'sharing', 'log', 'mapPack', 'firmware', 'luaApps', 'screenSounds', 'rfTools', 'pairedApps'];
      final list = find.byType(Scrollable).first;
      for (final k in keys) {
        final f = find.byKey(Key('ms-section-$k'));
        await tester.scrollUntilVisible(f, 100, scrollable: list);
        expect(f, findsOneWidget);
        expect(find.descendant(of: f, matching: find.text('Pair first')), k == 'pairing' ? findsNothing : findsOneWidget, reason: k);
        // the row above it is the one before it in MsSection order
        final i = keys.indexOf(k);
        if (i > 0) {
          final prev = find.byKey(Key('ms-section-${keys[i - 1]}'));
          if (prev.evaluate().isNotEmpty) expect(tester.getTopLeft(prev).dy, lessThan(tester.getTopLeft(f).dy), reason: k);
        }
      }
      expect(find.byKey(const Key('ms-section-owner')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const Key('ms-section-overview')), -100, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const Key('ms-section-overview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ms-overview-screen')), findsNothing);
      await tester.tap(find.byKey(const Key('ms-section-pairing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ms-pairing-screen')), findsOneWidget);
    });

    testWidgets('paired: every section opens; titles are plain', (tester) async {
      final rig = Rig();
      final c = await rig.paired(tester);
      await pumpHome(tester, MsRadioPage(controller: c));
      expect(find.text('Pair first'), findsNothing);
      for (final t in ['Pairing', 'Overview', 'Sharing and wardrive', 'Log and backlog']) {
        expect(find.text(t), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('ms-section-overview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ms-overview-screen')), findsOneWidget);
    });

    testWidgets('Not on Wi-Fi: a clear state with Retry that looks again', (tester) async {
      final rig = Rig();
      rig.radio.offline = true;
      final c = rig.make();
      await settle(tester, c.connect());
      await pumpHome(tester, MsRadioPage(controller: c));
      expect(find.byKey(const Key('ms-not-on-wifi')), findsOneWidget);
      expect(find.text('Not on Wi-Fi'), findsWidgets);
      rig.radio.offline = false;
      await tester.tap(find.byKey(const Key('ms-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ms-not-on-wifi')), findsNothing);
      expect(c.state.step, MsLinkStep.notPaired);
    });
  });

  group('pairing sheet', () {
    Future<void> openSheet(WidgetTester tester, MsRadioController c, String button) async {
      await pumpHome(tester, MsPairingScreen(c));
      await tapUntil(tester, find.byKey(Key(button)), find.byKey(const Key('ms-pair-end-title')));
    }

    testWidgets('signed pairing: progress steps all done, Paired, and the page state is Paired', (tester) async {
      final rig = Rig();
      final c = rig.make();
      await settle(tester, c.connect());
      await openSheet(tester, c, 'ms-pair-signed');
      expect(find.byKey(const Key('ms-pairing-sheet')), findsOneWidget);
      expect(find.text('Pair over Wi-Fi'), findsWidgets);
      expect(find.text('Checking it is the radio you are connected to'), findsOneWidget);
      expect(find.text('Signing over Bluetooth'), findsOneWidget);
      expect(find.byKey(const Key('ms-pair-end-title')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('ms-pair-end-title'))).data, 'Paired');
      expect(c.state.step, MsLinkStep.paired);
      expect(rig.radio.issuedTokens, hasLength(1));
      await tester.tap(find.byKey(const Key('ms-pairing-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ms-pairing-sheet')), findsNothing);
      expect(find.text('Paired'), findsOneWidget); // the State row
    });

    testWidgets('wrong radio: "This is not the radio you are connected to", nothing signed', (tester) async {
      final rig = Rig();
      final c = rig.make();
      await settle(tester, c.connect());
      rig.radio.badRadioSig = true;
      await openSheet(tester, c, 'ms-pair-signed');
      expect(tester.widget<Text>(find.byKey(const Key('ms-pair-end-title'))).data, 'This is not the radio you are connected to');
      expect(rig.radio.lastFinishText, isNull);
      expect(rig.radio.issuedTokens, isEmpty);
      expect(find.byKey(const Key('ms-pairing-retry')), findsNothing);
    });

    testWidgets('wrong radio at the address: the key from /info is another radio', (tester) async {
      final rig = Rig();
      rig.radio.infoKeyOverride = 'b0' * 32;
      final c = rig.make();
      await openSheet(tester, c, 'ms-pair-signed');
      expect(tester.widget<Text>(find.byKey(const Key('ms-pair-end-title'))).data, 'This is not the radio you are connected to');
    });

    testWidgets('ask on the radio: the person says No -> The radio refused, with Try again', (tester) async {
      final rig = Rig();
      rig.radio.askAnswer = FakeAskAnswer.no;
      final c = rig.make(withSign: false);
      await settle(tester, c.connect());
      await pumpHome(tester, MsPairingScreen(c));
      await tapUntil(tester, find.byKey(const Key('ms-pair-ask')), find.byKey(const Key('ms-pair-end-title')), step: const Duration(milliseconds: 500));
      expect(find.text('Waiting for Allow on the radio'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('ms-pair-end-title'))).data, 'The radio refused');
      expect(find.byKey(const Key('ms-pairing-retry')), findsOneWidget);
    });

    testWidgets('no Bluetooth: signed pairing says the radio could not sign', (tester) async {
      final rig = Rig();
      final c = rig.make(withSign: false);
      await settle(tester, c.connect());
      await openSheet(tester, c, 'ms-pair-signed');
      expect(tester.widget<Text>(find.byKey(const Key('ms-pair-end-title'))).data, 'The radio could not sign over Bluetooth');
    });
  });

  group('sections from fixture JSON', () {
    for (final b in Brightness.values) {
      testWidgets('overview (${b.name})', (tester) async {
        final rig = Rig();
        final c = await rig.paired(tester);
        await pumpHome(tester, MsOverviewScreen(c), brightness: b);
        expect(find.text('84 % · 4.01 V'), findsOneWidget);
        expect(find.text('1 h 0 min'), findsOneWidget);
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Strong (-58 dBm)'), findsOneWidget);
        expect(find.text('Connected to MeshSonar (CMH)'), findsOneWidget);
        expect(find.text('heltec_v4_touch'), findsNothing); // the model "..." is shown, not the id
        expect(find.textContaining('(from GPS)'), findsOneWidget);
        // memory only in the Details fold
        expect(find.text('Free memory'), findsNothing);
        await tester.scrollUntilVisible(find.byKey(const Key('ms-overview-details')), 100, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.byKey(const Key('ms-overview-details')));
        await tester.pumpAndSettle();
        expect(find.text('Free memory'), findsOneWidget);
        expect(find.text('910.525 MHz'), findsOneWidget);
        expect(rig.radio.requests, contains('GET /api/app/v1/status (fixture)'));
      });

      testWidgets('sharing and wardrive (${b.name}): switches change the radio', (tester) async {
        final rig = Rig();
        final c = await rig.paired(tester);
        await pumpHome(tester, MsSharingScreen(c), brightness: b);
        expect(find.text('Log what the radio hears'), findsOneWidget);
        expect(find.text('Share with MeshSonar'), findsOneWidget);
        expect(find.text('Wardrive GPS points'), findsOneWidget);
        expect(find.text('Connected to MeshSonar (CMH)'), findsOneWidget);
        expect(rig.radio.wardrive, isFalse);
        await tester.tap(find.byKey(const Key('ms-wardrive')));
        await tester.pumpAndSettle();
        expect(rig.radio.wardrive, isTrue);
        // logging off: wardrive needs it
        await tester.tap(find.byKey(const Key('ms-capture')));
        await tester.pumpAndSettle();
        expect(rig.radio.capture, isFalse);
        expect(find.text('Needs Log what the radio hears.'), findsOneWidget);
        final iata = find.byKey(const Key('ms-iata'));
        await tester.scrollUntilVisible(iata, 100, scrollable: find.byType(Scrollable).first);
        expect(find.descendant(of: iata, matching: find.text('CMH')), findsOneWidget);
      });

      testWidgets('log and backlog (${b.name}): counters, chart, files, save, map', (tester) async {
        final rig = Rig();
        final c = await rig.paired(tester);
        final tmp = Directory.systemTemp.createTempSync('ms-log-test');
        addTearDown(() => tmp.deleteSync(recursive: true));
        List<File>? shared;
        MsLogScreen.debugDocs = () async => tmp;
        MsLogScreen.debugShare = (f) async => shared = f;
        await pumpHome(tester, MsLogScreen(c), brightness: b);
        expect(find.text('Waiting to upload'), findsOneWidget);
        expect(find.text('Sent from backlog'), findsOneWidget);
        expect(find.byKey(const Key('chart-ms-log-hourly')), findsOneWidget);
        await tester.scrollUntilVisible(find.byKey(const Key('ms-log-save')), 200, scrollable: find.byType(Scrollable).first);
        expect(find.byKey(const Key('ms-log-file-old')), findsOneWidget);
        expect(find.byKey(const Key('ms-log-file-current')), findsOneWidget);
        await tester.tap(find.byKey(const Key('ms-log-save')));
        // the files are written for real: give real time between the pumps
        for (var i = 0; i < 100 && shared == null; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(shared, hasLength(2));
        expect(shared!.first.path, endsWith('-old.mslog'));
        expect(shared!.last.path, endsWith('-current.mslog'));
        expect(shared!.last.lengthSync(), 5 * 24);
        expect(rig.radio.requests.where((r) => r.contains('/log/file')), hasLength(2));
        await tester.scrollUntilVisible(find.byKey(const Key('ms-log-map')), 100, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.byKey(const Key('ms-log-map')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ms-log-map-screen')), findsOneWidget);
        expect(find.textContaining('GPS points and'), findsOneWidget);
        expect(find.byKey(const Key('ms-probe-0')), findsOneWidget);
        expect(find.textContaining('3 answered'), findsWidgets);
        // nothing went anywhere but the radio
        expect(rig.radio.requests.every((r) => r.contains('/api/app/v1/')), isTrue);
      });

      testWidgets('apps paired with this radio (${b.name})', (tester) async {
        final rig = Rig();
        final c = await rig.paired(tester);
        await pumpHome(tester, MsPairedAppsScreen(c), brightness: b);
        expect(find.text('MeshSonar iOS'), findsOneWidget);
        expect(find.text('This app'), findsOneWidget);
        expect(find.textContaining('Paired over Wi-Fi with Bluetooth'), findsOneWidget);
        expect(find.byKey(const Key('ms-revoke-0')), findsOneWidget);
        expect(find.byKey(const Key('ms-revoke-all')), findsOneWidget);
      });

      testWidgets('pairing (${b.name})', (tester) async {
        final rig = Rig();
        final c = await rig.paired(tester);
        await pumpHome(tester, MsPairingScreen(c), brightness: b);
        expect(find.text('Paired'), findsOneWidget);
        expect(find.text('03A107BF'), findsOneWidget);
        expect(find.text('192.168.1.77'), findsWidgets);
        expect(find.text('meshsonar-03a107bf.local'), findsOneWidget);
        await reveal(tester, find.byKey(const Key('ms-pair-signed')));
        expect(find.text('Pair again over Wi-Fi'), findsOneWidget);
        await reveal(tester, find.byKey(const Key('ms-enter-address')));
        expect(find.text('Ask on the radio'), findsOneWidget);
        expect(find.text('Enter address'), findsOneWidget);
        await tester.scrollUntilVisible(find.byKey(const Key('ms-forget')), 100, scrollable: find.byType(Scrollable).first);
        expect(find.text('Forget this radio'), findsOneWidget);
      });
    }

    testWidgets('an action the radio refuses shows the radio\'s own text', (tester) async {
      final rig = Rig();
      final c = await rig.paired(tester);
      await pumpHome(tester, MsSharingScreen(c));
      await tester.enterText(find.byKey(const Key('ms-iata')), 'C');
      await tester.tap(find.byKey(const Key('ms-iata-save')));
      await tester.pump();
      expect(find.text('The code is 3 letters or digits.'), findsOneWidget);
      dismissAppToast();
      await tester.pumpAndSettle();
      // wardrive with logging off: the fake radio answers 409 "Wardrive needs logging on."
      rig.radio.capture = false;
      final e = await settle<MsRadioError?>(tester, () async {
        try {
          await c.api!.setUplink(wardrive: true);
        } on MsRadioError catch (e) {
          return e;
        }
        return null;
      }());
      expect(msErrorText(e!), 'Wardrive needs logging on.');
    });

    testWidgets('forget this radio: unpair and the token is gone', (tester) async {
      final rig = Rig();
      final c = await rig.paired(tester);
      await pumpHome(tester, MsPairingScreen(c));
      await reveal(tester, find.byKey(const Key('ms-forget')));
      await tester.tap(find.byKey(const Key('ms-forget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ms-forget-confirm')));
      await tester.pumpAndSettle();
      expect(c.state.step, MsLinkStep.notPaired);
      expect(rig.radio.issuedTokens, isEmpty);
      expect(await settle(tester, MsTokenStore(rig.secrets).read(rig.radio.keyHex)), isNull);
      dismissAppToast();
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('large text (2.0) on a small phone: no overflow', () {
    Future<void> check(WidgetTester tester, Widget Function(MsRadioController c) screen, {bool paired = true}) async {
      final rig = Rig();
      final c = paired ? await rig.paired(tester) : rig.make();
      if (!paired) await settle(tester, c.connect());
      await pumpHome(tester, screen(c), size: se, scale: 2.0);
      expect(tester.takeException(), isNull);
      // scroll to the end too
      final s = find.byType(Scrollable);
      if (s.evaluate().isNotEmpty) {
        await tester.drag(s.first, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }

    testWidgets('page', (tester) => check(tester, (c) => MsRadioPage(controller: c)));
    testWidgets('page, not paired', (tester) => check(tester, (c) => MsRadioPage(controller: c), paired: false));
    testWidgets('pairing', (tester) => check(tester, (c) => MsPairingScreen(c)));
    testWidgets('overview', (tester) => check(tester, (c) => MsOverviewScreen(c)));
    testWidgets('sharing', (tester) => check(tester, (c) => MsSharingScreen(c)));
    testWidgets('log', (tester) => check(tester, (c) => MsLogScreen(c)));
    testWidgets('log map', (tester) => check(tester, (c) => MsLogMapScreen(c)));
    testWidgets('paired apps', (tester) => check(tester, (c) => MsPairedAppsScreen(c)));
    testWidgets('pairing sheet, finished', (tester) async {
      final rig = Rig();
      final c = rig.make();
      await settle(tester, c.connect());
      rig.radio.badRadioSig = true;
      await pumpHome(tester, MsPairingScreen(c), size: se, scale: 2.0);
      await tapUntil(tester, find.byKey(const Key('ms-pair-signed')), find.byKey(const Key('ms-pairing-done')));
      expect(find.byKey(const Key('ms-pairing-done')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('ms-pair-end-title')), 100,
          scrollable: find.descendant(of: find.byKey(const Key('ms-pairing-sheet')), matching: find.byType(Scrollable)).first);
      expect(find.byKey(const Key('ms-pair-end-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('entry row on More > Radio', (tester) async {
      final rig = Rig();
      final c = await rig.paired(tester);
      MsRadioHost.debugLink = (_) => MsRadioLink(caps: msCaps, key: rig.radio.keyHex);
      MsRadioHost.debugMake = (_) => c;
      await pumpHome(tester, MoreRadioScreen(onOpen: (_) {}), h: Harness(), size: se, scale: 2.0);
      await reveal(tester, find.byKey(const Key('more-meshsonar-radio')));
      expect(find.byKey(const Key('more-meshsonar-radio')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
