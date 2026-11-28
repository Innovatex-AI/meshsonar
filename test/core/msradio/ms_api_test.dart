// MsRadioApi: transport rules (X-MS, Bearer, 4 s, serial queue, 503 retry), error mapping, uploads, downloads, and every
// endpoint against the fake radio.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/msradio/msradio.dart';

final Uri base = Uri.parse('http://192.168.1.77');

MsRadioApi apiOn(http.Client c, {String? token, List<Duration>? waits, Duration timeout = const Duration(seconds: 4)}) => MsRadioApi(
      baseUrl: base,
      token: token,
      client: c,
      timeout: timeout,
      wait: (d) async => waits?.add(d),
    );

void main() {
  group('baseFor', () {
    test('addresses the person or discovery gives', () {
      expect(MsRadioApi.baseFor('192.168.1.77').toString(), 'http://192.168.1.77');
      expect(MsRadioApi.baseFor(' 192.168.1.77:8080 ').toString(), 'http://192.168.1.77:8080');
      expect(MsRadioApi.baseFor('http://meshsonar-a1b2c3d4.local/').toString(), 'http://meshsonar-a1b2c3d4.local');
      expect(MsRadioApi.baseFor('fe80::1')!.host, 'fe80::1');
      expect(MsRadioApi.baseFor('[fd00::5]:81')!.port, 81);
      expect(MsRadioApi.baseFor(''), isNull);
      expect(MsRadioApi.baseFor('a/b'), isNull);
      expect(MsRadioApi.baseFor('user@host'), isNull);
    });
  });

  group('transport', () {
    test('POST carries X-MS: 1 and form fields; authorised calls carry the Bearer token; GET has no X-MS', () async {
      final seen = <http.Request>[];
      final c = MockClient((r) async {
        seen.add(r);
        return http.Response('{"uplink":{"capture":true,"share":false,"wardrive":true}}', 200);
      });
      final api = apiOn(c, token: 'ab' * 16);
      final u = await api.setUplink(capture: true, wardrive: true, iata: 'cmh');
      expect(u.uplink!.wardrive, isTrue);
      await api.uplink();
      final post = seen[0], get = seen[1];
      expect(post.method, 'POST');
      expect(post.url.path, '/api/app/v1/uplink');
      expect(post.headers['X-MS'], '1');
      expect(post.headers['Authorization'], 'Bearer ${'ab' * 16}');
      expect(post.bodyFields, {'capture': 'true', 'wardrive': 'true', 'iata': 'CMH'});
      expect(get.headers.containsKey('X-MS'), isFalse);
      expect(get.headers['Authorization'], 'Bearer ${'ab' * 16}');
    });

    test('open pairing calls send no token', () async {
      final seen = <http.Request>[];
      final c = MockClient((r) async {
        seen.add(r);
        return http.Response('{"n":"0011223344556677","expires_in":60}', 200);
      });
      await apiOn(c, token: 'ab' * 16).pairAsk(app: 'MeshSonar iOS');
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
      expect(seen.single.headers['X-MS'], '1');
    });

    test('a 503 is retried once after 1 s', () async {
      var n = 0;
      final waits = <Duration>[];
      final c = MockClient((r) async => ++n == 1 ? http.Response('{"error":"busy","status":503}', 503) : http.Response('{"linked":false}', 200));
      final o = await apiOn(c, token: 'ab' * 16, waits: waits).owner();
      expect(o.linked, isFalse);
      expect(n, 2);
      expect(waits, [const Duration(seconds: 1)]);
    });

    test('a second 503 is the busy error, with the radio\'s text', () async {
      var n = 0;
      final c = MockClient((r) async {
        n++;
        return http.Response('{"error":"Radio busy","status":503}', 503);
      });
      await expectLater(
          apiOn(c, token: 'ab' * 16).status(), throwsA(isA<MsRadioError>().having((e) => e.kind, 'kind', MsErrorKind.busy).having((e) => e.message, 'm', 'Radio busy')));
      expect(n, 2);
    });

    test('one request at a time per radio, in order', () async {
      final radio = FakeMsRadio()..latency = const Duration(milliseconds: 5);
      final api = MsRadioApi(baseUrl: base, client: radio.client, token: radio.issueToken());
      final order = <String>[];
      await Future.wait([
        api.status().then((_) => order.add('status')),
        api.settings().then((_) => order.add('settings')),
        api.owner().then((_) => order.add('owner')),
        api.tokens().then((_) => order.add('tokens')),
      ]);
      expect(radio.maxInFlight, 1);
      expect(order, ['status', 'settings', 'owner', 'tokens']);
    });

    test('a failed call does not block the queue', () async {
      final q = MsSerialQueue();
      final a = q.run<int>(() async => throw StateError('x'));
      final b = q.run<int>(() async => 2);
      await expectLater(a, throwsStateError);
      expect(await b, 2);
      expect(q.pending, 0);
    });

    test('no answer in time: timeout', () async {
      final radio = FakeMsRadio()..hang = true;
      final api = apiOn(radio.client, timeout: const Duration(milliseconds: 50));
      await expectLater(api.info(), throwsA(isA<MsRadioError>().having((e) => e.kind, 'kind', MsErrorKind.timeout).having((e) => e.unreachable, 'unreachable', isTrue)));
    });

    test('no route: notOnWifi', () async {
      final radio = FakeMsRadio()..offline = true;
      await expectLater(apiOn(radio.client).info(), throwsA(isA<MsRadioError>().having((e) => e.kind, 'kind', MsErrorKind.notOnWifi)));
    });

    test('a reply that is not a JSON object: badReply', () async {
      for (final body in ['<html>', '[1,2]', '']) {
        final c = MockClient((r) async => http.Response(body, 200));
        await expectLater(apiOn(c).info(), throwsA(isA<MsRadioError>().having((e) => e.kind, 'kind', MsErrorKind.badReply)), reason: body);
      }
    });

    test('a pair/start without a usable radio_sig: badReply', () async {
      final c = MockClient((r) async => http.Response(MsContractExamples.pairStart, 200));
      await expectLater(apiOn(c).pairStart(appNonce: 'ab' * 16, app: 'x'), throwsA(isA<MsRadioError>().having((e) => e.kind, 'kind', MsErrorKind.badReply)));
    });
  });

  group('error mapping', () {
    final cases = <int, MsErrorKind>{
      400: MsErrorKind.badRequest,
      401: MsErrorKind.notPaired,
      403: MsErrorKind.forbidden,
      404: MsErrorKind.notFound,
      409: MsErrorKind.conflict,
      410: MsErrorKind.expired,
      423: MsErrorKind.locked,
      429: MsErrorKind.rateLimited,
      500: MsErrorKind.server,
    };
    for (final e in cases.entries) {
      test('${e.key} -> ${e.value.name} with the radio\'s own text', () async {
        final c = MockClient((r) async => http.Response(jsonEncode({'error': 'Radio says ${e.key}', 'status': e.key}), e.key));
        await expectLater(
          apiOn(c, token: 'ab' * 16).probeNow(),
          throwsA(isA<MsRadioError>()
              .having((x) => x.kind, 'kind', e.value)
              .having((x) => x.status, 'status', e.key)
              .having((x) => x.message, 'message', 'Radio says ${e.key}')
              .having((x) => x.fromRadio, 'fromRadio', isTrue)),
        );
      });
    }

    test('without an error text: a plain English default', () async {
      final c = MockClient((r) async => http.Response('', 423));
      await expectLater(apiOn(c).lockNow(), throwsA(isA<MsRadioError>().having((x) => x.message, 'm', 'The radio is locked.').having((x) => x.fromRadio, 'f', isFalse)));
    });

    test('401 drops the token and calls onUnauthorized; the error never shows the token', () async {
      final c = MockClient((r) async => http.Response('{"error":"Not paired.","status":401}', 401));
      var called = 0;
      final api = apiOn(c, token: 'ab' * 16)..onUnauthorized = () => called++;
      try {
        await api.status();
        fail('no error');
      } on MsRadioError catch (e) {
        expect(e.needsPairing, isTrue);
        expect(e.toString(), isNot(contains('ab' * 16)));
      }
      expect(api.token, isNull);
      expect(called, 1);
    });

    test('client-side checks: IATA, PIN, quiet hours, owner key, main.lua size', () {
      final api = apiOn(MockClient((r) async => http.Response('{}', 200)));
      expect(() => api.setUplink(iata: 'CMHX'), throwsA(isA<MsRadioError>()));
      expect(() => api.setPin('12'), throwsA(isA<MsRadioError>()));
      expect(() => api.clearPin('12a4'), throwsA(isA<MsRadioError>()));
      expect(() => api.setSettings(quietStart: 60), throwsA(isA<MsRadioError>()));
      expect(() => api.setOwner(ownerKey: 'abc'), throwsA(isA<MsRadioError>()));
      expect(() => api.uploadApp(MsUploadSource.bytes('main.lua', List<int>.filled(33 * 1024, 32)), id: 'x', name: 'X'), throwsA(isA<MsRadioError>()));
    });
  });

  group('uploads and downloads', () {
    test('map pack: POST /maps?size= multipart field file, Bearer token, X-MS, progress to 100%', () async {
      late http.Request seen;
      final c = MockClient((r) async {
        seen = r;
        return http.Response('Done: 3 KB written.', 200);
      });
      final bytes = utf8.encode('MSMP${'x' * 3000}');
      final progress = <int>[];
      final api = apiOn(c, token: 'ab' * 16);
      final res = await api.uploadMapPack(
          MsUploadSource(name: 'cmh-20261108.msmp', size: bytes.length, open: () => Stream.fromIterable([bytes.sublist(0, 1000), bytes.sublist(1000)])),
          onProgress: (done, total) {
        progress.add(done);
        expect(total, bytes.length);
      });
      expect(res.text, 'Done: 3 KB written.');
      expect(seen.url.path, '/maps');
      expect(seen.url.queryParameters, {'size': '${bytes.length}'});
      expect(seen.headers['Authorization'], 'Bearer ${'ab' * 16}');
      expect(seen.headers['X-MS'], '1');
      expect(seen.headers['content-type'], startsWith('multipart/form-data; boundary='));
      final body = utf8.decode(seen.bodyBytes);
      expect(body, contains('Content-Disposition: form-data; name="file"; filename="cmh-20261108.msmp"'));
      expect(body, contains('MSMP${'x' * 3000}'));
      expect(seen.bodyBytes.length, seen.contentLength);
      expect(progress.last, bytes.length);
      expect(progress, orderedEquals([...progress]..sort()));
    });

    test('Lua app upload: /apps/upload with the query the contract lists', () async {
      late http.Request seen;
      final c = MockClient((r) async {
        seen = r;
        return http.Response('Done.', 200);
      });
      await apiOn(c, token: 'ab' * 16).uploadApp(MsUploadSource.bytes('main.lua', utf8.encode('print("hi")')),
          id: 'hello', name: 'Hello', version: '1.0.0', icon: 'HI', desc: 'Says hi', internet: true, memoryKb: 48);
      expect(seen.url.path, '/apps/upload');
      expect(seen.url.queryParameters, {'id': 'hello', 'name': 'Hello', 'version': '1.0.0', 'icon': 'HI', 'desc': 'Says hi', 'http': '1', 'mem': '48', 'size': '11'});
    });

    test('firmware upload goes to /update; a refusal shows the radio\'s plain text', () async {
      final c = MockClient((r) async => r.url.path == '/update' ? http.Response('Wrong board for this radio.', 400) : http.Response('', 404));
      await expectLater(
        apiOn(c, token: 'ab' * 16).uploadFirmware(MsUploadSource.bytes('meshsonar-heltec-v4-touch-0.2.0.bin', [1, 2, 3])),
        throwsA(isA<MsRadioError>().having((e) => e.message, 'm', 'Wrong board for this radio.').having((e) => e.kind, 'k', MsErrorKind.badRequest)),
      );
    });

    test('an upload retried after a 503 opens the file again', () async {
      var n = 0, opens = 0;
      final c = MockClient((r) async => ++n == 1 ? http.Response('busy', 503) : http.Response('Done.', 200));
      final res = await apiOn(c, token: 'ab' * 16, waits: []).uploadFirmware(MsUploadSource(
          name: 'f.bin',
          size: 3,
          open: () {
            opens++;
            return Stream.value([1, 2, 3]);
          }));
      expect(res.text, 'Done.');
      expect(opens, 2);
    });

    test('log file download: raw bytes with progress', () async {
      final radio = FakeMsRadio();
      final api = MsRadioApi(baseUrl: base, client: radio.client, token: radio.issueToken());
      var last = 0;
      final cur = await api.logFile(MsLogWhich.current, onProgress: (d, t) => last = d);
      final old = await api.logFile(MsLogWhich.old);
      expect(cur.length, 5 * 24);
      expect(cur.first, 0xA5);
      expect(old.length, 3 * 24);
      expect(last, cur.length);
      expect(radio.requests.last, 'GET /api/app/v1/log/file?which=old');
    });
  });

  group('every endpoint on the fake radio', () {
    test('reads and actions', () async {
      final radio = FakeMsRadio();
      final api = MsRadioApi(baseUrl: base, client: radio.client, token: radio.issueToken());

      expect((await api.index())['api'], 1);
      final info = await api.info();
      expect(info.key, radio.keyHex);
      expect(info.paired, isTrue);

      final st = await api.status();
      expect(st.device!.battPct, 84);
      expect(st.uplink!.iata, 'CMH');

      final up = await api.setUplink(share: false);
      expect(up.uplink!.share, isFalse);
      expect(radio.share, isFalse);
      await expectLater(api.setUplink(capture: false, wardrive: true), throwsA(isA<MsRadioError>().having((e) => e.kind, 'k', MsErrorKind.conflict)));

      final log = await api.log();
      expect(log.hourly, hasLength(24));
      expect(log.file(MsLogWhich.old)!.size, 1200000);

      // paging log/records until end
      final kinds = <MsRecordKind>[];
      var page = await api.logRecords();
      kinds.addAll(page.records.map((r) => r.kind));
      while (page.hasMore) {
        page = await api.logRecords(off: page.next!);
        kinds.addAll(page.records.map((r) => r.kind));
      }
      expect(kinds, [MsRecordKind.packet, MsRecordKind.gps, MsRecordKind.probe]);
      expect(radio.requests.where((q) => q.contains('log/records')).last, contains('off=1234'));

      expect((await api.probes()).records.single.probe!.answered, 3);
      expect((await api.probeNow()).listenS, 8);

      final maps = await api.maps();
      expect(maps.pack!.name, 'Columbus');
      expect((await api.uploadMapPack(MsUploadSource.bytes('a.msmp', utf8.encode('MSMP1234'))).then((r) => r.text)), startsWith('Done'));
      expect(radio.uploadedBytes['/maps'], greaterThan(8));

      var apps = await api.apps();
      expect(apps.installed.map((a) => a.id), ['clock', 'weather']);
      expect(apps.catalog!.state, MsCatalogState.idle);
      await api.loadCatalog();
      apps = await api.apps();
      expect(apps.catalog!.state, MsCatalogState.ok);
      expect(apps.catalog!.entries.first.updateAvailable, isTrue);
      expect(apps.catalog!.entries.last.installed, isFalse);
      await api.installApp('snake');
      await api.runApp('weather');
      expect((await api.apps()).running, 'weather');
      await api.stopApp();
      expect((await api.apps()).running, isNull);
      await expectLater(api.removeApp('clock'), throwsA(isA<MsRadioError>().having((e) => e.message, 'm', 'Built-in apps cannot be removed.')));
      await api.removeApp('weather');
      expect((await api.apps()).installed.map((a) => a.id), ['clock']);

      expect((await api.ota()).offer!.version, '0.2.0');
      await api.otaCheck();
      await api.otaInstall(force: true);
      await api.otaChannel(beta: true);
      expect((await api.ota()).beta, isTrue);
      await api.otaAuto(on: false);
      expect((await api.ota()).autoCheck, isFalse);
      await api.otaRestart();
      expect(radio.requests.last, 'POST /api/app/v1/ota/restart');

      final s = await api.setSettings(screenTimeoutMs: 300000, volume: 3, quietOn: true, quietStart: 1320, quietEnd: 420, events: 63);
      expect(s.screenTimeoutMs, 300000);
      expect(s.sounds!.volume, 3);
      expect(s.sounds!.eventOn('low_battery'), isTrue);
      await expectLater(api.setSettings(brightness: 1), throwsA(isA<MsRadioError>().having((e) => e.kind, 'k', MsErrorKind.badRequest)));

      await expectLater(api.lockNow(), throwsA(isA<MsRadioError>().having((e) => e.kind, 'k', MsErrorKind.conflict)));
      await api.setPin('1234');
      await api.lockNow();
      expect(radio.locked, isTrue);
      await expectLater(api.clearPin('9999'), throwsA(isA<MsRadioError>().having((e) => e.message, 'm', 'Wrong PIN')));
      await api.clearPin('1234');
      expect(radio.lockSet, isFalse);

      final ownerKey = 'ef' * 32;
      final o = await api.setOwner(ownerKey: ownerKey, name: 'KE4BFI Home');
      expect(o.linked, isTrue);
      expect(o.ownerKey, ownerKey);
      await expectLater(api.setOwner(ownerKey: radio.keyHex), throwsA(isA<MsRadioError>().having((e) => e.kind, 'k', MsErrorKind.badRequest)));
      expect((await api.clearOwner()).linked, isFalse);

      expect((await api.spectrum()).scan, isNull);
      await api.spectrumStart(f0: 902, f1: 928, step: 0.2, seconds: 10);
      final sp = await api.spectrum();
      expect(sp.scanning, isTrue);
      expect(sp.scan!.last, hasLength(131));
      expect(sp.scan!.last.where((x) => x == null), isNotEmpty);
      await expectLater(api.probeNow(), throwsA(isA<MsRadioError>().having((e) => e.kind, 'k', MsErrorKind.conflict)));
      await api.spectrumStop();

      final t = await api.tokens();
      expect(t.tokens.single.me, isTrue);
      await api.revokeToken(0);
      await expectLater(api.status(), throwsA(isA<MsRadioError>().having((e) => e.needsPairing, 'pair', isTrue)));
      expect(api.token, isNull);
    });

    test('revoke all and unpair', () async {
      final radio = FakeMsRadio();
      final mine = radio.issueToken();
      radio.issueToken(app: 'Other');
      final api = MsRadioApi(baseUrl: base, client: radio.client, token: mine);
      expect((await api.tokens()).tokens, hasLength(2));
      await api.unpair();
      expect(radio.issuedTokens, hasLength(1));
      final other = MsRadioApi(baseUrl: base, client: radio.client, token: radio.issuedTokens.single);
      await other.revokeAllTokens();
      expect(radio.issuedTokens, isEmpty);
    });

    test('POST without X-MS is refused by the radio (the client always sends it)', () async {
      final radio = FakeMsRadio();
      final t = radio.issueToken();
      final r = await radio.client.post(Uri.parse('http://192.168.1.77/api/app/v1/uplink'), headers: {'Authorization': 'Bearer $t'}, body: {'share': 'true'});
      expect(r.statusCode, 403);
    });
  });
}
