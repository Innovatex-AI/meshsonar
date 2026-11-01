// The website's account pages, native: devices and keys (reveal, new key, MeshMapper), a server drive with its pings, my
// reports, the full leaderboard, Download my data and Delete my account. Capability `driverAccount` / `driverDelete`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/driver_account.dart';
import 'package:meshsonar/core/driver_summary.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/account/devices_screen.dart';
import 'package:meshsonar/ui/account/leaderboard_screen.dart';
import 'package:meshsonar/ui/account/reports_history_screen.dart';
import 'package:meshsonar/ui/account/server_drive_screen.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/region/stats_panel.dart' show regionStatsApiFactory;
import 'package:meshsonar/ui/settings/delete_my_data.dart';

import 'fakes.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _myKey = 'secretkey-abcdef-1234';

class AcctClient extends FakeCmatClient {
  AcctClient(super.baseUrl);
  bool linked = true;
  Object? rotateError;
  String? rotatedTo;
  Object? deleteError;
  int deleteCalls = 0;
  final List<String> calls = [];
  int exports = 0;

  @override
  Future<DriverDevices> driverDevices(String driverKey) async {
    calls.add('devices');
    return DriverDevices(
      driver: const AccountDevice(id: 'd1', display: 'KE4BFI', status: DriverKeyStatus.approved, keyHint: '1234', revealable: true),
      linked: linked,
      devices: [
        const AccountDevice(id: 'd1', display: 'KE4BFI', status: DriverKeyStatus.approved, keyHint: '1234', revealable: true),
        if (linked) const AccountDevice(id: 'd2', display: 'iPad', status: DriverKeyStatus.approved, keyHint: '9876', revealable: true),
      ],
      mmKeys: linked ? [const MmForwardKey(id: 'm1', keyHint: 'wxyz', items: 40, items24h: 4, revealable: true)] : const [],
    );
  }

  @override
  Future<RevealedKey> revealKey(String driverKey, {required String kind, required String id}) async {
    calls.add('reveal:$kind:$id');
    return kind == 'mm' ? const RevealedKey(key: 'mmf_secret', configLink: 'meshmapper://custom-api?url=u&key=mmf_secret') : const RevealedKey(key: 'ms_other_phone_key');
  }

  @override
  Future<String> rotateKey(String driverKey, String newKey) async {
    if (rotateError != null) throw rotateError!;
    rotatedTo = newKey;
    return newKey.substring(newKey.length - 4);
  }

  @override
  Future<ServerDriveDetail> driverDrive(String driverKey, String sessionId) async => ServerDriveDetail.tryParse({
        'drive': {'id': sessionId, 'startedAt': '2026-10-30T10:00:00Z', 'km': 2.5, 'review': 'ok'},
        'pings': [
          {'id': 'p1', 'at': '2026-10-30T10:01:00Z', 'lat': 39.9, 'lon': -83.0, 'heard': true, 'echoes': [{'repeaterId': 'ab12', 'name': 'Hill', 'snr': 4.5}]},
          {'id': 'p2', 'at': '2026-10-30T10:02:00Z', 'lat': 39.91, 'lon': -83.0, 'heard': false, 'echoes': []},
        ],
      })!;

  @override
  Future<void> updateServerDrive(String driverKey, String sessionId, {String? label, bool clearLabel = false, bool? hidden}) async {
    calls.add('update:$sessionId:${label ?? (clearLabel ? '-' : '')}:${hidden ?? ''}');
  }

  @override
  Future<void> deleteServerDrive(String driverKey, String sessionId) async => calls.add('delete:$sessionId');

  @override
  Future<List<ReportRow>> driverReports(String driverKey) async => [
        ReportRow(id: 'r1', createdAt: DateTime.utc(2026, 10, 31), status: 'triaged', category: 'gps', source: 'app', summary: 'No fix in the tunnel'),
      ];

  @override
  Future<List<int>> exportAccount(String driverKey) async {
    exports++;
    return utf8.encode('{"format":"meshsonar.driver-export.v1"}');
  }

  @override
  Future<DriverDeleteCounts> deleteDriver(String driverKey) async {
    deleteCalls++;
    if (deleteError != null) throw deleteError!;
    return const DriverDeleteCounts(sessions: 3, pings: 120, reports: 1);
  }
}

class AcctHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => AcctClient(u);
  AcctClient get ac => state.client as AcctClient;
}

Future<AcctHarness> open(WidgetTester tester, {Set<String> caps = const {'driverAccount', 'driverDelete', 'networkLeaderboard'}, bool linked = true}) async {
  useTallScreen(tester);
  tester.view.physicalSize = const Size(1080, 4800);
  final h = AcctHarness();
  h.approveKey();
  await h.state.init();
  h.ac.linked = linked;
  h.ac.siteConfigResult = SiteConfig(region: _region, capabilities: caps);
  await h.state.refreshUploadSiteConfig(force: true);
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  return h;
}

void push(WidgetTester tester, Widget w) => Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => w));

void main() {
  tearDown(() => regionStatsApiFactory = (b) => RegionStatsApi(b));

  testWidgets('devices: this phone, the account list, a sibling key and the MeshMapper link are shown on tap and never listed', (tester) async {
    final h = await open(tester);
    push(tester, const DevicesScreen());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-row-self')), findsOneWidget);
    expect(find.byKey(const Key('devices-row-d2')), findsOneWidget);
    expect(find.byKey(const Key('devices-mm-m1')), findsOneWidget);
    expect(find.text(_myKey), findsNothing, reason: 'the key is masked until asked for');
    expect(find.byKey(const Key('devices-key-hidden')), findsOneWidget);
    await tester.tap(find.byKey(const Key('devices-key-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('devices-key-shown')), findsOneWidget);
    await tester.pump(keyRevealFor + const Duration(seconds: 1));
    expect(find.byKey(const Key('devices-key-shown')), findsNothing, reason: 'hides itself after 30 s');

    await tester.tap(find.byKey(const Key('reveal-driver-d2')));
    await tester.pumpAndSettle();
    expect(find.text('ms_other_phone_key'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reveal-close')));
    await tester.pumpAndSettle();
    expect(find.text('ms_other_phone_key'), findsNothing);

    await tester.tap(find.byKey(const Key('reveal-mm-m1')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const Key('reveal-text'))).data, startsWith('meshmapper://custom-api'));
    expect(h.ac.calls, containsAll(['reveal:driver:d2', 'reveal:mm:m1']));
    await tester.pump(keyRevealFor + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reveal-dialog')), findsNothing, reason: 'the dialog closes itself after 30 s');
  });

  testWidgets('devices: an anonymous key lists only itself and explains MeshMapper needs an account', (tester) async {
    await open(tester, linked: false);
    push(tester, const DevicesScreen());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-unlinked')), findsOneWidget);
    expect(find.byKey(const Key('devices-mm-needs-account')), findsOneWidget);
    expect(find.byKey(const Key('devices-row-d2')), findsNothing);
  });

  testWidgets('devices: no capability = the key still shows, the account lists say the server does not offer them', (tester) async {
    await open(tester, caps: const {});
    push(tester, const DevicesScreen());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('devices-this-phone')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('devices-rotate'))).onPressed, isNull);
  });

  testWidgets('new key: confirm, then the phone holds the new key and the old one is gone', (tester) async {
    final h = await open(tester);
    push(tester, const DevicesScreen());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('devices-rotate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rotate-key-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(h.ac.rotatedTo, isNotNull);
    expect(isDriverKeyShape(h.ac.rotatedTo!), isTrue);
    expect(h.state.settings.driverKey, h.ac.rotatedTo);
    expect(h.state.settings.pendingDriverKey, isNull);
    expect(find.byKey(const Key('devices-rotate-result')), findsOneWidget);
  });

  testWidgets('new key: a refused answer keeps the old key and drops the staged one', (tester) async {
    final h = await open(tester);
    h.ac.rotateError = const CmatException('Too many requests', status: 429);
    final err = await h.state.rotateDriverKey();
    expect(err, isNotNull);
    expect(h.state.settings.driverKey, _myKey);
    expect(h.state.settings.pendingDriverKey, isNull);
  });

  testWidgets('new key: a lost answer keeps the staged key; the next check adopts it when the server switched', (tester) async {
    final h = await open(tester);
    h.ac.rotateError = const CmatException('timed out');
    final err = await h.state.rotateDriverKey();
    expect(err, contains('No answer'));
    final staged = h.state.settings.pendingDriverKey;
    expect(staged, isNotNull);
    expect(h.state.settings.driverKey, _myKey, reason: 'never lose the working key until the server says');
    // the server did switch: the staged key is the live one
    h.ac.statusError = null;
    h.ac.statusResult = (status: DriverKeyStatus.approved, display: 'KD8XYZ');
    await h.state.settlePendingKey();
    expect(h.state.settings.driverKey, staged);
    expect(h.state.settings.pendingDriverKey, isNull);
  });

  testWidgets('new key: a lost answer where the server did NOT switch drops the staged key', (tester) async {
    final h = await open(tester);
    h.ac.rotateError = const CmatException('timed out');
    await h.state.rotateDriverKey();
    h.ac.statusError = const CmatException('unknown key', status: 401); // staged key unknown...
    await h.state.settlePendingKey();
    // ...and the old key still works (status(old) also errors 401 in this fake, so both are unknown): nothing to keep
    expect(h.state.settings.pendingDriverKey, isNull);
  });

  testWidgets('server drive: map, totals and per-ping list; rename, hide and delete go to the server', (tester) async {
    final h = await open(tester);
    final d = ServerDrive.tryParse({'id': 's1', 'startedAt': '2026-10-30T10:00:00Z'})!;
    push(tester, ServerDriveScreen(drive: d));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('server-drive-totals')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('server-drive-totals'))).data, contains('2 pings'));
    expect(tester.widget<Text>(find.byKey(const Key('server-drive-totals'))).data, contains('50% heard'));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('server-ping-p1')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Hill 4.5 dB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('server-drive-hide')));
    await tester.pumpAndSettle();
    expect(h.ac.calls, contains('update:s1::true'));
    await tester.tap(find.byKey(const Key('server-drive-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-drive-delete-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(h.ac.calls, contains('delete:s1'));
    expect(find.byKey(const Key('server-drive-screen')), findsNothing, reason: 'closes after deleting');
  });

  testWidgets('my reports: lists what was sent with plain-words status', (tester) async {
    await open(tester);
    push(tester, const ReportsHistoryScreen());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('report-r1')), findsOneWidget);
    expect(find.textContaining('working on it'), findsOneWidget);
    expect(find.text('GPS or location'), findsOneWidget);
  });

  testWidgets('leaderboard: period and scope switches ask the right endpoint; offline copy is labelled', (tester) async {
    final paths = <String>[];
    regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async {
          paths.add('${r.url.path}?${r.url.query}');
          return http.Response(
              jsonEncode({'period': r.url.queryParameters['period'], 'rows': [{'rank': 1, 'callsign': 'KD8XYZ', 'km': 12.5, 'drives': 3, 'cells': 40, 'repeatersHeard': 5}]}), 200,
              headers: {'content-type': 'application/json'});
        }));
    await open(tester);
    push(tester, const LeaderboardScreen());
    await tester.pumpAndSettle();
    expect(find.text('KD8XYZ (you)'), findsOneWidget, reason: 'the row matching the name this phone shows is marked');
    expect(paths.last, '/api/cmh/leaderboard?period=30d');
    await tester.tap(find.text('All time'));
    await tester.pumpAndSettle();
    expect(paths.last, '/api/cmh/leaderboard?period=all');
    await tester.tap(find.text('Every region'));
    await tester.pumpAndSettle();
    expect(paths.last, '/api/cmh/network-leaderboard?period=all');
  });

  testWidgets('leaderboard: without the network capability there is no scope switch', (tester) async {
    regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async => http.Response(jsonEncode({'period': '30d', 'rows': []}), 200, headers: {'content-type': 'application/json'})));
    await open(tester, caps: const {});
    push(tester, const LeaderboardScreen());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('leaderboard-scope')), findsNothing);
    expect(find.text('No one on the leaderboard yet'), findsOneWidget);
  });

  testWidgets('Download my data hands the server file to the share sheet', (tester) async {
    final h = await open(tester);
    push(tester, const DeleteMyDataScreen());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('export-data')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('export-data')));
    for (var i = 0; i < 10 && find.byKey(const Key('export-result')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(tester.widget<Text>(find.byKey(const Key('export-result'))).data, startsWith('Done'));
    expect(h.ac.exports, 1);
    expect(h.shared.single.path, contains('meshsonar-account-export-'));
    expect(h.shared.single.readAsStringSync(), contains('driver-export.v1'));
  });

  testWidgets('Delete my account: confirm, the server deletes, the phone forgets the key and does not make a new one', (tester) async {
    final h = await open(tester);
    push(tester, const DeleteMyDataScreen());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('delete-account')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pumpAndSettle();
    expect(h.ac.deleteCalls, 1);
    expect(h.state.hasKey, isFalse);
    expect(h.state.settings.autoKey, isFalse);
    expect(find.byKey(const Key('delete-account-result')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('delete-account-result'))).data, contains('3 drives'));
  });

  testWidgets('Delete my account: offline changes nothing and says so', (tester) async {
    final h = await open(tester);
    h.ac.deleteError = const CmatException('network error: down');
    push(tester, const DeleteMyDataScreen());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('delete-account')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pumpAndSettle();
    expect(h.state.hasKey, isTrue);
    expect(tester.widget<Text>(find.byKey(const Key('delete-account-result'))).data, contains('Nothing was changed'));
  });

  testWidgets('Delete my account on a server without the endpoint keeps the website hand-off', (tester) async {
    await open(tester, caps: const {});
    push(tester, const DeleteMyDataScreen());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('delete-account-website')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('delete-account')), findsNothing);
  });
}
