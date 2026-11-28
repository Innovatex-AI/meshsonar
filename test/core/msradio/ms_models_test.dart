// Parsing every example reply of meshsonar-firmware docs/APP-INTEGRATION.md section 4, and tolerance of missing,
// mistyped and unknown fields.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/msradio/msradio.dart';

Map<String, dynamic> j(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('contract examples', () {
    test('info', () {
      final i = MsInfo.parse(j(MsContractExamples.info));
      expect(i.api, 1);
      expect(i.product, 'MeshSonar Firmware');
      expect(i.fw, '0.1.0');
      expect(i.core, 'v1.18.0');
      expect(i.fwString, 'v1.18.0-ms0.1.0');
      expect(i.board, 'heltec_v4_touch');
      expect(i.model, 'Heltec V4 + Expansion Kit (MeshSonar)');
      expect(i.key, isNull, reason: 'the example key "A1B2C3D4..." is not 64 hex: never trusted');
      expect(i.name, 'KE4BFI Mobile');
      expect(i.host, 'meshsonar-a1b2c3d4.local');
      expect(i.ip, '192.168.1.77');
      expect(i.pair, ['sign', 'approve']);
      expect(i.offersSignedPairing, isTrue);
      expect(i.paired, isFalse);
      expect(i.webConsole, isTrue);
      final k = MsInfo.parse({'key': MsTestVector.key.toUpperCase()});
      expect(k.key, MsTestVector.key);
      expect(k.keyPrefix, '03a107bf');
    });

    test('status', () {
      final s = MsStatus.parse(j(MsContractExamples.status));
      expect(s.device!.name, 'KE4BFI Mobile');
      expect(s.device!.uptimeS, 3600);
      expect(s.device!.battMv, 4012);
      expect(s.device!.battPct, 84);
      expect(s.device!.clockSet, isTrue);
      expect(s.device!.time, DateTime.fromMillisecondsSinceEpoch(1795000000 * 1000, isUtc: true));
      expect(s.device!.clockSource, 'GPS');
      expect(s.device!.heapInternal, 10432);
      expect(s.device!.psramFree, 180224);
      expect(s.radio!.freqMhz, 910.525);
      expect(s.radio!.bwKhz, 62.5);
      expect(s.radio!.sf, 7);
      expect(s.radio!.cr, 5);
      expect(s.radio!.txDbm, 22);
      expect(s.radio!.contacts, 41);
      expect(s.wifi!.state, 'Connected to Home');
      expect(s.wifi!.ssid, 'Home');
      expect(s.wifi!.rssi, -58);
      expect(s.wifi!.mdns, isTrue);
      expect(s.wifi!.timeSynced, isTrue);
      expect(s.uplink!.state, 'Connected to MeshSonar (CMH)');
      expect(s.uplink!.capture, isTrue);
      expect(s.uplink!.share, isTrue);
      expect(s.uplink!.wardrive, isFalse);
      expect(s.uplink!.iata, 'CMH');
      expect(s.uplink!.mqtt, isTrue);
      expect(s.uplink!.linked, isFalse);
      final l = s.log!;
      expect([l.heard, l.heardHour, l.sent, l.sentHour, l.pending, l.backlogSent, l.backlogMaxS, l.dropped, l.logged, l.logBytes, l.gpsPoints],
          [5120, 88, 4980, 85, 12, 340, 3300, 0, 5130, 412000, 220]);
      expect(l.bestSnr, 11);
      expect(s.ota!.state, '');
      expect(s.ota!.updateAvailable, isFalse);
      expect(s.maps!.busy, isFalse);
      expect(s.apps!.count, 4);
      expect(s.apps!.running, isFalse);
      expect(s.apps!.current, '');
      expect(s.rf!.scanning, isFalse);
      expect(s.rf!.txBudgetPct, 100);
      expect(s.lock!.set, isFalse);
      expect(s.lock!.locked, isFalse);
    });

    test('pair/start (placeholders are refused), pair/finish, pair/ask, tokens', () {
      expect(() => MsPairStart.parse(j(MsContractExamples.pairStart)), throwsFormatException);
      final ok = MsPairStart.parse({
        'key': MsTestVector.key.toUpperCase(),
        'nonce': MsTestVector.nonce,
        'expires_in': 120,
        'sign_text': MsTestVector.pair,
        'radio_sig': MsTestVector.helloSig,
      });
      expect(ok.key, MsTestVector.key);
      expect(ok.expiresIn, 120);
      expect(ok.signText, MsTestVector.pair);
      expect(() => MsPairToken.parse(j(MsContractExamples.pairFinish)), throwsFormatException);
      final t = MsPairToken.parse({'token': 'AB' * 16, 'via': 'sign', 'key': MsTestVector.key});
      expect(t.token, 'ab' * 16);
      expect(t.toString(), isNot(contains('ab' * 16)));
      expect(() => MsPairAsk.parse(j(MsContractExamples.pairAsk)), throwsFormatException);
      expect(MsPairAsk.parse({'n': '0011223344556677', 'expires_in': 60}).n, '0011223344556677');
      expect(MsPairAskResult.parse({'state': 'wait'}).state, MsAskState.wait);
      expect(MsPairAskResult.parse({'state': 'yes', 'token': 'cd' * 16, 'via': 'approve'}).token!.via, 'approve');
      expect(MsPairAskResult.parse({'state': 'yes'}).token, isNull);
      expect(MsPairAskResult.parse({'state': 'no'}).state, MsAskState.no);
      expect(MsPairAskResult.parse({'state': 'locked'}).state, MsAskState.locked);
      expect(MsPairAskResult.parse({'state': 'later'}).state, MsAskState.unknown);
      final tk = MsTokens.parse(j(MsContractExamples.tokens)).tokens.single;
      expect(tk.i, 0);
      expect(tk.app, 'MeshSonar iOS');
      expect(tk.via, 'sign');
      expect(tk.created!.millisecondsSinceEpoch, 1795000000 * 1000);
      expect(tk.seenS, 3);
      expect(tk.me, isTrue);
    });

    test('log/records with packet, gps and probe records', () {
      final p = MsLogPage.parse(j(MsContractExamples.logRecords));
      expect(p.which, MsLogWhich.current);
      expect(p.size, 412000);
      expect(p.next, 1234);
      expect(p.end, isFalse);
      expect(p.hasMore, isTrue);
      final [pk, gps, probe] = p.records;
      expect(pk.kind, MsRecordKind.packet);
      expect(pk.seq, 101);
      expect(pk.ms, 412);
      expect(pk.lat, 39.961234);
      expect(pk.lon, -82.998765);
      expect(pk.snr, 7.25);
      expect(pk.rssi, -96);
      expect(pk.raw, '1500AB...');
      expect(gps.kind, MsRecordKind.gps);
      expect(gps.hasPosition, isTrue);
      expect(probe.kind, MsRecordKind.probe);
      expect(probe.bestSnr, 9.5);
      expect(probe.bestRssi, -90);
      final pr = probe.probe!;
      expect(pr.trigger, 'manual');
      expect(pr.answered, 3);
      expect(pr.ping, 'answered');
      expect(pr.pingMs, 840);
      expect(pr.pingRepeater, '5f0a11b2');
      expect(pr.nodes.single.key, '5f0a11b2');
      expect(pr.nodes.single.type, 2);
      expect(pr.nodes.single.snrThem, 6.25);
      expect(pr.nodes.single.rssi, -90);
    });

    test('log/records: no fix, unknown RSSI, a damaged record, a last page', () {
      final p = MsLogPage.parse({
        'records': [
          {'seq': 1, 'kind': 'packet', 'ts': 1, 'rssi': 127},
          {'seq': 2, 'kind': 'gps', 'lat': 95.0, 'lon': 10.0},
          'junk',
          {'seq': 3, 'kind': 'future-kind'},
        ],
        'next': 50,
        'end': false,
        'bad_record': true,
      });
      expect(p.records, hasLength(3));
      expect(p.records[0].hasPosition, isFalse);
      expect(p.records[0].rssi, isNull);
      expect(p.records[1].hasPosition, isFalse, reason: 'an impossible position is dropped');
      expect(p.records[2].kind, MsRecordKind.unknown);
      expect(p.badRecord, isTrue);
      expect(p.hasMore, isFalse);
      expect(MsLogPage.parse({'records': []}).hasMore, isFalse);
    });

    test('maps (with and without a pack)', () {
      final m = MsMaps.parse(j(MsContractExamples.maps));
      expect(m.partition, isTrue);
      expect(m.spaceKb, 8192);
      expect(m.pack!.name, 'Columbus');
      expect([m.pack!.zmin, m.pack!.zmax, m.pack!.zdef, m.pack!.tiles, m.pack!.bytes], [8, 14, 12, 5321, 3911000]);
      expect(m.pack!.lat, 39.96);
      expect(m.upload!.path, '/maps');
      expect(m.upload!.field, 'file');
      expect(m.upload!.sizeArg, 'size');
      expect(MsMaps.parse({'partition': true, 'pack': null}).pack, isNull);
    });

    test('ota', () {
      final o = MsOta.parse(j(MsContractExamples.ota));
      expect(o.state, MsOtaState.idle);
      expect(o.lastResult, 'Updated to MeshSonar 0.1.0.');
      expect(o.beta, isFalse);
      expect(o.autoCheck, isTrue);
      expect(o.feed, 'https://meshsonar.com/firmware/heltec-v4-touch/stable.json');
      expect(o.fw, '0.1.0');
      expect(o.slot, 'app0');
      expect(o.pendingVerify, isFalse);
      final f = o.offer!;
      expect(f.newer, isTrue);
      expect(f.allowed, isTrue);
      expect(f.channel, 'stable');
      expect(f.version, '0.2.0');
      expect(f.build, 12);
      expect(f.size, 2841000);
      expect(f.minVersion, '0.1.0');
      expect(f.checkedSAgo, 40);
      expect(o.upload!.path, '/update');
      expect(MsOta.parse({'state': 'downloading', 'offer': null}).state, MsOtaState.downloading);
      expect(MsOta.parse({'state': 'something-new'}).state, MsOtaState.unknown);
      expect(MsOta.parse({'state': 'something-new'}).stateWord, 'something-new');
    });

    test('settings and sounds', () {
      final s = MsSettings.parse(j(MsContractExamples.settings));
      expect(s.name, 'KE4BFI Mobile');
      expect(s.brightness, 80);
      expect(s.screenTimeoutMs, 120000);
      expect(s.screenTimeouts, [30000, 60000, 120000, 300000, 600000, 0]);
      final so = s.sounds!;
      expect(so.buzzerBuilt, isTrue);
      expect(so.buzzerFitted, isTrue);
      expect(so.volume, 2);
      expect(so.flash, isTrue);
      expect(so.events, 61);
      expect(so.eventBits, ['dm', 'channel', 'mention', 'delivered', 'not_delivered', 'low_battery']);
      // 61 = 0b111101: every event but `channel`
      expect(so.eventOn('dm'), isTrue);
      expect(so.eventOn('channel'), isFalse);
      expect(so.eventOn('low_battery'), isTrue);
      expect(so.eventOn('nope'), isFalse);
      expect(so.eventsWith('channel', true), 63);
      expect(so.eventsWith('dm', false), 60);
      expect(so.eventsWith('nope', true), 61);
      expect(so.quietOn, isFalse);
      expect(so.quietStart, 1320);
      expect(so.quietEnd, 420);
      expect(s.lock!.set, isFalse);
    });

    test('owner', () {
      final o = MsOwner.parse(j(MsContractExamples.owner));
      expect(o.linked, isFalse);
      expect(o.ownerKey, isNull);
      expect(o.ownerName, isNull);
      expect(o.share, isTrue);
      final l = MsOwner.parse({'owner_key': 'EF' * 32, 'owner_name': 'Home'});
      expect(l.linked, isTrue);
      expect(l.ownerKey, 'ef' * 32);
    });

    test('spectrum (null bins, bins not available)', () {
      final s = MsSpectrum.parse(j(MsContractExamples.spectrum));
      expect(s.scanning, isTrue);
      expect(s.binsAvailable, isTrue);
      final sc = s.scan!;
      expect(sc.f0, 902.0);
      expect(sc.f1, 928.0);
      expect(sc.step, 0.2);
      expect(sc.n, 131);
      expect(sc.sweeps, 4);
      expect(sc.seq, 7);
      expect(sc.last, [-118.5, -120.0, null]);
      expect(sc.peak, [-110.0, -112.5, null]);
      expect(sc.freqAt(5), closeTo(903.0, 1e-9));
      final off = MsSpectrum.parse({'scanning': false, 'bins_available': false, 'scan': null});
      expect(off.binsAvailable, isFalse);
      expect(off.scan, isNull);
    });

    test('probe/now and the error body', () {
      final p = MsProbeStart.parse(j(MsContractExamples.probeNow));
      expect(p.ok, isTrue);
      expect(p.listenS, 8);
      final e = j(MsContractExamples.error);
      expect(MsRadioError.fromStatus(e['status'] as int, e['error'] as String).kind, MsErrorKind.conflict);
    });
  });

  group('tolerance', () {
    test('an empty object parses to defaults everywhere', () {
      expect(MsInfo.parse({}).pair, isEmpty);
      expect(MsStatus.parse({}).device, isNull);
      expect(MsUplink.parse({}).uplink, isNull);
      expect(MsLog.parse({}).hourly, isEmpty);
      expect(MsProbes.parse({}).records, isEmpty);
      expect(MsMaps.parse({}).pack, isNull);
      expect(MsApps.parse({}).installed, isEmpty);
      expect(MsOta.parse({}).offer, isNull);
      expect(MsSettings.parse({}).sounds, isNull);
      expect(MsOwner.parse({}).linked, isFalse);
      expect(MsSpectrum.parse({}).binsAvailable, isFalse);
      expect(MsTokens.parse({}).tokens, isEmpty);
      expect(MsActionResult.parse({}).ok, isTrue);
    });

    test('mistyped and unknown fields are ignored; booleans accept 1/0 and on/off', () {
      final s = MsStatus.parse({
        'device': {'batt_pct': '84', 'uptime_s': 3600.0, 'clock_set': 1, 'new_field': [1, 2]},
        'uplink': {'capture': 'on', 'share': 0, 'wardrive': 'yes'},
        'radio': 'not an object',
        'surprise': {'a': 1},
      });
      expect(s.device!.battPct, 84);
      expect(s.device!.uptimeS, 3600);
      expect(s.device!.clockSet, isTrue);
      expect(s.uplink!.capture, isTrue);
      expect(s.uplink!.share, isFalse);
      expect(s.uplink!.wardrive, isFalse);
      expect(s.radio, isNull);
    });

    test('list rows that cannot be read are skipped', () {
      final a = MsApps.parse({
        'installed': [
          {'id': 'clock', 'name': 'Clock'},
          {'name': 'no id'},
          7,
        ],
        'running': 'clock',
        'installing': true,
      });
      expect(a.installed.map((x) => x.id), ['clock']);
      expect(a.running, 'clock');
      expect(a.installing, isTrue);
      expect(a.installingId, isNull);
      final t = MsTokens.parse({
        'tokens': [
          {'app': 'no index'},
          {'i': 1, 'app': 'Two'},
        ],
      });
      expect(t.tokens.single.i, 1);
    });

    test('POST /uplink may answer with the fields at the top level', () {
      final u = MsUplink.parse({'capture': true, 'share': true, 'wardrive': true});
      expect(u.uplink!.wardrive, isTrue);
    });
  });
}
