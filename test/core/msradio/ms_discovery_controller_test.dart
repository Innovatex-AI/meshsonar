// Discovery order, the /info key check, the controller (the stock gate, connect, 401, forget) and redaction of tokens.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/msradio/msradio.dart';
import 'package:meshsonar/core/redact.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/radio/protocol.dart';

const String keyA = MsTestVector.key;
final String keyB = 'b0' * 32;

String infoFor(String key) => jsonEncode({'key': key.toUpperCase(), 'fw': '0.1.0', 'name': 'R'});

/// A network of addresses -> the radio key answering there (missing = no route).
class Net {
  final Map<String, String> at;
  final List<String> hosts = [];
  Net(this.at);
  late final http.Client client = MockClient((r) async {
    final h = r.url.hasPort && r.url.port != 80 ? '${r.url.host}:${r.url.port}' : r.url.host;
    hosts.add(h);
    final k = at[h];
    if (k == null) throw http.ClientException('No route to host', r.url);
    return http.Response(infoFor(k), 200);
  });
}

class Browser implements MsServiceBrowser {
  final List<MsFoundService> found;
  int calls = 0;
  Browser(this.found);
  @override
  Future<List<MsFoundService>> browse(String type, {Duration timeout = Duration.zero}) async {
    calls++;
    return found;
  }
}

RadioCaps capsFor(String ver) => RadioCaps.fromDeviceInfo(DeviceInfoFrame(firmwareVerCode: 10, firmwareVersion: ver, manufacturer: 'Heltec V4 TFT'));

void main() {
  group('MsRadioDiscovery order', () {
    test('1. the last good address wins and is checked with /info', () async {
      final net = Net({'10.0.0.5': keyA, 'meshsonar-03a107bf.local': keyA});
      final store = InMemoryMsAddressStore()..values[keyA] = '10.0.0.5';
      final b = Browser([]);
      final r = await MsRadioDiscovery(client: net.client, browser: b, addresses: store).find(keyA);
      expect(r.found, isTrue);
      expect(r.source, MsAddressSource.lastGood);
      expect(r.address, '10.0.0.5');
      expect(net.hosts, ['10.0.0.5']);
      expect(b.calls, 0);
    });

    test('2. then the mDNS host built from the Bluetooth key (lower case); it is remembered', () async {
      final net = Net({'meshsonar-03a107bf.local': keyA});
      final store = InMemoryMsAddressStore()..values[keyA] = '10.0.0.9';
      final r = await MsRadioDiscovery(client: net.client, addresses: store).find(keyA.toUpperCase());
      expect(r.source, MsAddressSource.mdnsHost);
      expect(net.hosts, ['10.0.0.9', 'meshsonar-03a107bf.local']);
      expect(store.values[keyA], 'meshsonar-03a107bf.local');
      expect(msMdnsHostFor(keyA.toUpperCase()), 'meshsonar-03a107bf.local');
    });

    test('3. then DNS-SD, only services whose TXT pk matches, IPv4 first', () async {
      final net = Net({'192.168.1.80': keyA, '192.168.1.81': keyB});
      final b = Browser([
        MsFoundService(name: 'meshsonar-b0b0b0b0', addresses: ['192.168.1.81'], txt: {'pk': 'b0b0b0b0'}),
        const MsFoundService(name: 'meshsonar-03a107bf', addresses: ['fd00::7', '192.168.1.80'], txt: {'pk': '03A107BF'}),
      ]);
      final r = await MsRadioDiscovery(client: net.client, browser: b).find(keyA);
      expect(r.found, isTrue);
      expect(r.source, MsAddressSource.browse);
      expect(r.address, '192.168.1.80');
      expect(net.hosts, isNot(contains('192.168.1.81')), reason: 'another radio\'s service is not even tried');
    });

    test('4. the typed address last', () async {
      final net = Net({'172.20.10.4': keyA});
      final r = await MsRadioDiscovery(client: net.client, browser: Browser([])).find(keyA, typed: '172.20.10.4');
      expect(r.source, MsAddressSource.typed);
      expect(net.hosts, ['meshsonar-03a107bf.local', '172.20.10.4']);
    });

    test('nothing answers: notOnWifi', () async {
      final r = await MsRadioDiscovery(client: Net({}).client).find(keyA);
      expect(r.outcome, MsDiscoveryOutcome.notOnWifi);
    });

    test('wrong radio: an address with another key is never used; a stale last-good address is forgotten', () async {
      final net = Net({'10.0.0.5': keyB});
      final store = InMemoryMsAddressStore()..values[keyA] = '10.0.0.5';
      final r = await MsRadioDiscovery(client: net.client, addresses: store).find(keyA);
      expect(r.outcome, MsDiscoveryOutcome.wrongRadio);
      expect(r.otherKey, keyB);
      expect(store.values.containsKey(keyA), isFalse);
    });

    test('wrong radio on the typed address (acceptance test 3), and the right radio found anyway first', () async {
      final net = Net({'192.168.1.20': keyB, 'meshsonar-03a107bf.local': keyA});
      final d = MsRadioDiscovery(client: net.client);
      final typed = await d.check(keyA, '192.168.1.20');
      expect(typed.outcome, MsDiscoveryOutcome.wrongRadio);
      final r = await d.find(keyA, typed: '192.168.1.20');
      expect(r.found, isTrue);
      expect(r.address, 'meshsonar-03a107bf.local');
    });

    test('a /info without a key is not this radio', () async {
      final c = MockClient((r) async => http.Response('{"fw":"0.1.0"}', 200));
      final r = await MsRadioDiscovery(client: c).check(keyA, '10.0.0.1');
      expect(r.outcome, MsDiscoveryOutcome.wrongRadio);
    });
  });

  group('MsRadioController', () {
    test('THE stock gate: a stock radio gets no controller and the network is never touched', () async {
      var requests = 0;
      final c = MockClient((r) async {
        requests++;
        return http.Response('{}', 200);
      });
      final browser = Browser([]);
      for (final ver in ['v1.18.0', 'v1.17.1-observer-x', 'v1.18.0-sim', '', null]) {
        final caps = RadioCaps.fromDeviceInfo(DeviceInfoFrame(firmwareVerCode: 10, firmwareVersion: ver));
        expect(caps.isMeshSonar, isFalse, reason: '$ver');
        expect(MsRadioController.forCaps(caps, radioKey: keyA, secrets: InMemoryMsSecretKv(), client: c, browser: browser), isNull, reason: '$ver');
      }
      expect(MsRadioController.forCaps(RadioCaps.baseline, radioKey: keyA, secrets: InMemoryMsSecretKv(), client: c, browser: browser), isNull);
      expect(requests, 0);
      expect(browser.calls, 0);
    });

    test('no controller without a usable Bluetooth key', () {
      final caps = capsFor('v1.18.0-ms0.1.0');
      expect(MsRadioController.forCaps(caps, radioKey: null, secrets: InMemoryMsSecretKv()), isNull);
      expect(MsRadioController.forCaps(caps, radioKey: 'abc', secrets: InMemoryMsSecretKv()), isNull);
    });

    test('connect -> notPaired, pairSigned -> paired, a stored token survives a new controller, forget', () async {
      final radio = FakeMsRadio();
      final kv = InMemoryMsSecretKv();
      MsRadioController make() => MsRadioController.forCaps(capsFor('v1.18.0-ms0.1.0'),
          radioKey: radio.keyHex.toUpperCase(), secrets: kv, client: radio.client, browser: radio.browser, sign: radio.sign, wait: (_) async {})!;

      final c = make();
      expect(c.fw.msVersion, '0.1.0');
      final steps = <MsLinkStep>[];
      c.states.listen((s) => steps.add(s.step));
      var s = await c.connect();
      expect(s.step, MsLinkStep.notPaired);
      expect(s.chip, 'Not paired');
      expect(s.address, 'meshsonar-03a107bf.local');
      expect(s.source, MsAddressSource.mdnsHost);
      final p = await c.pairSigned();
      expect(p.paired, isTrue, reason: p.message);
      expect(c.state.step, MsLinkStep.paired);
      expect(c.state.chip, 'Paired');
      expect((await c.api!.status()).device!.name, 'KE4BFI Mobile');
      expect(steps, containsAllInOrder([MsLinkStep.finding, MsLinkStep.notPaired, MsLinkStep.paired]));
      c.dispose();

      // a new session: the token and the last good address come back from storage
      final c2 = make();
      radio.requests.clear();
      s = await c2.connect();
      expect(s.step, MsLinkStep.paired);
      expect(s.source, MsAddressSource.lastGood);
      expect(kv.values.keys.where((k) => k.startsWith('token.')), hasLength(1));

      await c2.forget();
      expect(c2.state.step, MsLinkStep.notPaired);
      expect(kv.values.keys.where((k) => k.startsWith('token.')), isEmpty);
      expect(radio.issuedTokens, isEmpty, reason: 'unpair dropped it on the radio too');
      c2.dispose();
    });

    test('a 401 from any call drops the token and asks to pair again (acceptance test 14)', () async {
      final radio = FakeMsRadio();
      final kv = InMemoryMsSecretKv();
      await MsTokenStore(kv).save(radio.keyHex, radio.issueToken());
      final c = MsRadioController.forCaps(capsFor('v1.18.0-ms0.1.0'),
          radioKey: radio.keyHex, secrets: kv, client: radio.client, browser: radio.browser, wait: (_) async {})!;
      expect((await c.connect()).step, MsLinkStep.paired);
      radio.revokeAll();
      await expectLater(c.api!.settings(), throwsA(isA<MsRadioError>().having((e) => e.needsPairing, 'pair', isTrue)));
      await Future<void>.delayed(Duration.zero);
      expect(c.state.step, MsLinkStep.notPaired);
      expect(c.state.message, 'Pair again.');
      expect(await MsTokenStore(kv).read(radio.keyHex), isNull);
      // pairing works again (approval this time: no Bluetooth signer given)
      final p = await c.pairByApproval();
      expect(p.paired, isTrue);
      expect(c.state.step, MsLinkStep.paired);
      c.dispose();
    });

    test('a stored token the radio no longer knows: notPaired at connect, token dropped', () async {
      final radio = FakeMsRadio();
      final kv = InMemoryMsSecretKv();
      await MsTokenStore(kv).save(radio.keyHex, 'ee' * 16);
      final c = MsRadioController.forCaps(capsFor('v1.18.0-ms0.1.0'), radioKey: radio.keyHex, secrets: kv, client: radio.client, browser: radio.browser)!;
      expect((await c.connect()).step, MsLinkStep.notPaired);
      expect(await MsTokenStore(kv).read(radio.keyHex), isNull);
    });

    test('not on Wi-Fi, and Enter address on another radio', () async {
      final radio = FakeMsRadio()..offline = true;
      final c = MsRadioController.forCaps(capsFor('v1.18.0-ms0.1.0'), radioKey: radio.keyHex, secrets: InMemoryMsSecretKv(), client: radio.client, browser: radio.browser)!;
      final s = await c.connect();
      expect(s.step, MsLinkStep.notOnWifi);
      expect(s.chip, 'Not on Wi-Fi');
      expect(c.api, isNull);

      final other = FakeMsRadio()..infoKeyOverride = keyB;
      final c2 = MsRadioController.forCaps(capsFor('v1.18.0-ms0.1.0'), radioKey: keyA, secrets: InMemoryMsSecretKv(), client: other.client)!;
      final w = await c2.useAddress('192.168.1.50');
      expect(w.step, MsLinkStep.wrongRadio);
      expect(w.message, 'This is not the radio you are connected to.');
      expect(c2.api, isNull);
    });
  });

  group('token store', () {
    test('per radio key, case-insensitive, only 32 hex', () async {
      final kv = InMemoryMsSecretKv();
      final t = MsTokenStore(kv);
      await t.save(keyA.toUpperCase(), 'AB' * 16);
      expect(await t.read(keyA), 'ab' * 16);
      expect(await t.read(keyB), isNull);
      expect(() => t.save(keyA, 'short'), throwsArgumentError);
      expect(() => t.save('nope', 'ab' * 16), throwsArgumentError);
      await t.drop(keyA);
      expect(await t.read(keyA), isNull);
    });
  });

  group('redaction (lib/core/redact.dart)', () {
    test('a radio token after Bearer and in token fields is redacted', () {
      const t = '0123456789abcdef0123456789abcdef';
      expect(redactText('Authorization: Bearer $t').text, 'Authorization: Bearer [redacted]');
      expect(redactText('{"token":"$t","via":"sign"}').text, '{"token":"[redacted]","via":"sign"}');
      expect(redactText('{"state":"yes","token": "$t"}').text, isNot(contains(t)));
      expect(redactText('token=$t&x=1').text, 'token=[redacted]&x=1');
      expect(redactText('curl -H "Authorization: Bearer $t" http://meshsonar-a1b2c3d4.local/api/app/v1/status').text, isNot(contains(t)));
    });
  });
}
