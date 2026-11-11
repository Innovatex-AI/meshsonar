// Phone observer O2 (Nov 8 2026): the uploader's `meshsonar-telemetry/2` request shape, the v1 fallback on a 400 about the
// format (contract section 1), the flush cadence (5 s foreground; 60 s or 50 packets background; contract section 6) and
// batching per observer mode.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

class _Tx implements TelemetryTransport {
  final posts = <Map<String, dynamic>>[];
  final results = <TelemetryHttpResult>[];
  TelemetryHttpResult deleteResult = const TelemetryHttpResult(200, body: {'deleted': 3});
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) async {
    posts.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    if (results.isEmpty) return const TelemetryHttpResult(200, body: {'stored': 1, 'observer': {'key': 'ab', 'kind': 'mobile'}});
    return results.removeAt(0);
  }

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) async => deleteResult;
}

const _id = '0123456789abcdef0123456789abcdef';

void main() {
  late DateTime clock;
  late _Tx tx;
  TelemetryObserver? obs;

  TelemetryUploader make({TelemetryConfig config = const TelemetryConfig(holdFor: Duration.zero), void Function()? erased, void Function(Map<String, dynamic>)? onObs}) =>
      TelemetryUploader(
        enabled: () => true,
        driverKey: () => 'k' * 40,
        keyApproved: () => true,
        transport: () => tx,
        appVersion: '0.30.0',
        platform: 'ios',
        config: config,
        now: () => clock,
        autoSchedule: false,
        observer: (_) => obs,
        onServerErased: erased,
        onObserver: onObs,
      );

  var salt = 0;
  TelemetryRecord advert({ObserverMode mode = ObserverMode.background, String? cell = '872a1072bffffff', DateTime? at}) {
    salt++;
    return TelemetryRecord.fromRx(
      RxPacket(
        at: at ?? clock.subtract(const Duration(seconds: 1)),
        raw: MeshPacket(
          header: makeHeader(RouteType.flood, PayloadType.advert),
          pathLenByte: 1,
          path: [Uint8List.fromList([0xa1])],
          payload: Uint8List.fromList(List.generate(40, (i) => (i + salt) & 0xff)),
        ).toBytes(),
        snrDb: 4,
        rssiDbm: -95,
      ),
      region: 'CMH',
      cell: cell,
      mode: mode,
    )!;
  }

  setUp(() {
    clock = DateTime.utc(2026, 11, 8, 12);
    tx = _Tx();
    obs = const TelemetryObserver(
      id: _id,
      radio: TelemetryRadio(model: 'Heltec V3 (LoRa)!', firmware: 'v1.9.0 beta', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, antenna: 'roof_mag_mount'),
    );
  });

  test('request shape: format 2, app, region, observer {id, mode, radio}, packets with raw and cell', () async {
    final u = make();
    expect(u.add(advert()), isTrue);
    await u.flush();
    final b = tx.posts.single;
    expect(b.keys.toList(), ['format', 'app', 'region', 'observer', 'packets']);
    expect(b['format'], 'meshsonar-telemetry/2');
    expect(b['app'], {'version': '0.30.0', 'platform': 'ios'});
    expect(b['region'], 'CMH');
    final o = b['observer'] as Map;
    expect(o['id'], _id);
    expect(o['mode'], 'background');
    // Free-text radio fields are made to fit the contract tokens; never sent malformed.
    expect(o['radio'], {
      'model': 'Heltec V3 LoRa',
      'firmware': 'v1.9.0beta',
      'freq_mhz': 910.525,
      'bw_khz': 62.5,
      'sf': 7,
      'cr': 5,
      'antenna': 'roof_mag_mount',
    });
    final p = (b['packets'] as List).single as Map;
    expect(p.keys.every(TelemetryRecord.wireKeysV2.contains), isTrue);
    expect(p['raw'], isA<String>());
    expect(p['cell'], '872a1072bffffff');
  });

  test('radio tokens: invalid values are left out, not sent', () {
    expect(const TelemetryRadio(model: '!!!', firmware: '', antenna: 'Roof Mount', sf: 99, cr: 2, freqMhz: double.nan).toJson(), isEmpty);
    expect(telemetryToken('x' * 60, RegExp(r'^[0-9A-Za-z][0-9A-Za-z ._+-]{0,39}$'), max: 40, spaces: true)!.length, 40);
  });

  test('no observer id yet, or an invalid one: the batch goes as v1 (headers only, no raw, no cell)', () async {
    obs = null;
    final u = make();
    u.add(advert());
    await u.flush();
    obs = const TelemetryObserver(id: 'not-hex');
    u.add(advert());
    await u.flush();
    for (final b in tx.posts) {
      expect(b['format'], 'meshsonar-telemetry/1');
      expect(b.containsKey('observer'), isFalse);
      final p = (b['packets'] as List).single as Map;
      expect(p.keys.toList(), TelemetryRecord.wireKeys);
    }
  });

  test('v1 fallback: a 400 that mentions the format resends the same batch as v1 at once, then v1 for the rest of the run', () async {
    tx.results.add(const TelemetryHttpResult(400, body: {'error': 'unsupported format meshsonar-telemetry/2'}));
    final u = make();
    u.add(advert());
    await u.flush();
    expect(tx.posts, hasLength(2));
    expect(tx.posts[0]['format'], 'meshsonar-telemetry/2');
    expect(tx.posts[1]['format'], 'meshsonar-telemetry/1');
    expect(((tx.posts[1]['packets'] as List).single as Map).containsKey('raw'), isFalse);
    expect(u.v1Only, isTrue);
    expect(u.queued, 0, reason: 'the v1 resend was accepted');
    u.add(advert());
    await u.flush();
    expect(tx.posts.last['format'], 'meshsonar-telemetry/1');
  });

  test('a 400 for another reason drops the batch (as before) and keeps v2', () async {
    tx.results.add(const TelemetryHttpResult(400, body: {'error': 'too many packets'}));
    final u = make();
    u.add(advert());
    await u.flush();
    expect(tx.posts, hasLength(1));
    expect(u.v1Only, isFalse);
    expect(u.queued, 0);
    expect(u.dropped, 1);
    expect(isFormatRefusal(const TelemetryHttpResult(400)), isFalse);
    expect(isFormatRefusal(const TelemetryHttpResult(413, body: {'error': 'format'})), isFalse);
  });

  test('the server\'s observer answer is handed to the app', () async {
    Map<String, dynamic>? got;
    final u = make(onObs: (o) => got = o);
    u.add(advert());
    await u.flush();
    expect(got, {'key': 'ab', 'kind': 'mobile'});
  });

  test('home and background packets never share a batch; home batches say mode home and carry no cell', () async {
    final u = make();
    u.add(advert());
    u.add(advert(mode: ObserverMode.home));
    await u.flush();
    clock = clock.add(const Duration(seconds: 6));
    await u.flush();
    expect(tx.posts, hasLength(2));
    expect((tx.posts[0]['observer'] as Map)['mode'], 'background');
    expect((tx.posts[1]['observer'] as Map)['mode'], 'home');
    expect(((tx.posts[1]['packets'] as List).single as Map).containsKey('cell'), isFalse);
  });

  test('foreground cadence: at most one batch every 5 s', () async {
    final u = make();
    u.add(advert());
    await u.flush();
    u.add(advert());
    clock = clock.add(const Duration(seconds: 4));
    await u.flush();
    expect(tx.posts, hasLength(1));
    clock = clock.add(const Duration(seconds: 1));
    await u.flush();
    expect(tx.posts, hasLength(2));
  });

  test('background cadence: a batch after 60 s, or sooner once 50 packets are ready', () async {
    final u = make();
    u.foreground = false;
    u.add(advert());
    await u.flush();
    expect(tx.posts, hasLength(1), reason: 'nothing sent yet this run: the first batch goes');
    u.add(advert());
    clock = clock.add(const Duration(seconds: 30));
    await u.flush();
    expect(tx.posts, hasLength(1), reason: '30 s and 1 packet: wait');
    clock = clock.add(const Duration(seconds: 30));
    await u.flush();
    expect(tx.posts, hasLength(2), reason: '60 s passed');
    for (var i = 0; i < 49; i++) {
      u.add(advert());
    }
    clock = clock.add(const Duration(seconds: 10));
    await u.flush();
    expect(tx.posts, hasLength(2), reason: '49 packets: wait');
    u.add(advert());
    await u.flush();
    expect(tx.posts, hasLength(3), reason: '50 packets ready: send now');
    expect((tx.posts.last['packets'] as List), hasLength(50));
    u.foreground = true;
    u.add(advert());
    clock = clock.add(const Duration(seconds: 5));
    await u.flush();
    expect(tx.posts, hasLength(4), reason: 'back in front: 5 s cadence');
  });

  test('the own-ping hold-back still applies in v2 while a ping is in flight (default 90 s)', () async {
    final u = make(config: const TelemetryConfig());
    u.pingSent(clock);
    u.add(advert(at: clock));
    clock = clock.add(const Duration(seconds: 60));
    await u.flush();
    expect(tx.posts, isEmpty);
    clock = clock.add(const Duration(seconds: 31));
    await u.flush();
    expect(tx.posts, hasLength(1));
  });

  test('the hourly budget stays under the server\'s 200: the gap widens past half of it', () async {
    final u = make();
    var sent = 0;
    for (var s = 0; s < 3600; s += 5) {
      u.add(advert());
      await u.flush();
      clock = clock.add(const Duration(seconds: 5));
      sent = tx.posts.length;
    }
    expect(sent, lessThanOrEqualTo(const TelemetryConfig().maxBatchesPerHour));
    expect(const TelemetryConfig().maxBatchesPerHour, lessThan(200));
    expect(sent, greaterThan(100), reason: 'still sending through the hour');
  });

  test('a confirmed server erase calls back (the app then rotates the observer id)', () async {
    var erased = 0;
    final u = make(erased: () => erased++);
    expect(await u.eraseServerData(), 3);
    expect(erased, 1);
    tx.deleteResult = const TelemetryHttpResult(503);
    await u.eraseServerData();
    expect(erased, 1, reason: 'not confirmed: no callback');
  });
}
