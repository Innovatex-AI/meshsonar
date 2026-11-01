// Drive Format v1.3 on the wire: per-ping window_ms and outcome, only for a server that lists meshsonar.drive.v1.3,
// while v1 / v1.1 / v1.2 bodies stay exactly as before. The real website validator is exercised in
// test/core/cmat_contract_test.dart ("Drive Format v1.3").
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_context_wire.dart';
import 'package:meshsonar/core/model.dart';

import 'helpers.dart';

const _app = AppInfo(name: 'MeshSonar', version: '0.19.0', platform: 'ios');

void main() {
  final t = DateTime.utc(2026, 11, 1, 12);
  DrivePing tx(int n, {int? windowMs, List<Echo> echoes = const []}) =>
      DrivePing(id: newId(), ts: t.add(Duration(seconds: n)), lat: 40.1, lon: -82.9, echoes: echoes, windowMs: windowMs);
  const echo = Echo(repeater: 'df0136', snrDb: 5, rssiDbm: -90, hops: 1);
  final session = makeSession(startedAt: t);

  Map<String, dynamic> body(List<DrivePing> pings, {bool v13 = false, ContextUpload? cu}) =>
      jsonDecode(jsonEncode(DriveBatch(app: _app, session: session, pings: pings, context: cu, v13: v13).toJson())) as Map<String, dynamic>;

  test('v1.3 body: tx pings carry outcome from the echo list and window_ms when in 1000..60000; rx pings carry neither', () {
    final rx = DrivePing(id: newId(), ts: t, lat: 40.1, lon: -82.9, kind: PingKind.rx, echoes: const [echo], windowMs: 10000);
    final b = body([tx(1, windowMs: 10000, echoes: const [echo]), tx(2, windowMs: 1000), tx(3, windowMs: 999), tx(4, windowMs: 60001), tx(5), rx],
        v13: true, cu: const ContextUpload(weather: false));
    expect(b['format'], 'meshsonar.drive.v1.3');
    expect((b['session'] as Map)['enrich'], {'weather': false}); // the weather opt-out stays explicit (v1.3 default is on)
    final ps = (b['pings'] as List).cast<Map>();
    expect([for (final p in ps) p['window_ms']], [10000, 1000, null, null, null, null]);
    expect([for (final p in ps) p['outcome']], ['echo', 'no_reply', 'no_reply', 'no_reply', 'no_reply', null]);
    expect(ps.last.containsKey('window_ms'), isFalse);
  });

  test('older bodies never carry window_ms or outcome, even when the ping has a window', () {
    final p = tx(1, windowMs: 10000, echoes: const [echo]);
    for (final b in [body([p]), body([p], cu: const ContextUpload(weather: true))]) {
      for (final x in (b['pings'] as List).cast<Map>()) {
        expect(x.containsKey('window_ms'), isFalse);
        expect(x.containsKey('outcome'), isFalse);
      }
    }
    expect(body([p])['format'], 'meshsonar.drive.v1');
    expect(body([p], cu: const ContextUpload(weather: true))['format'], 'meshsonar.drive.v1.2');
  });

  test('window_ms survives the local store round trip but is not in a plain DrivePing without one', () {
    final p = tx(1, windowMs: 12500);
    expect(DrivePing.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>).windowMs, 12500);
    expect(tx(2).toJson().containsKey('window_ms'), isFalse);
  });

  test('capability: acceptsDriveV13 only when the server lists the id', () {
    const r = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
    expect(const SiteConfig(region: r, driveFormats: ['meshsonar.drive.v1.2']).acceptsDriveV13, isFalse);
    expect(const SiteConfig(region: r, driveFormats: ['meshsonar.drive.v1.2', 'meshsonar.drive.v1.3']).acceptsDriveV13, isTrue);
  });
}
