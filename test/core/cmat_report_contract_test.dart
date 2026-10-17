// AC-10 (spec m1-app-0.4.0 §8): the app's report body against CMAT's REAL report-handlers.ts (bun fixture
// test/fixtures/cmat_report_server.ts). A report returns 201 and the stored text equals the app's redacted text
// (server redaction is idempotent on app-cleaned text, CMAT spec AC-8). Skips when bun or the CMAT checkout (with
// src/lib/platform/report-handlers.ts) isn't present, like cmat_contract_test.dart.
// Set CMAT_DIR to the meshcore-insights checkout (default /home/claude/meshcore-insights).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/report_body.dart';
import 'package:path/path.dart' as p;

import 'cmat_contract_test.dart' show findBun;

const driverKey = 'ms_contractReportKey_0123456789abcdefghijklmn';

void main() {
  final cmatDir = Platform.environment['CMAT_DIR'] ?? '/home/claude/meshcore-insights';
  final handlers = '$cmatDir/src/lib/platform/report-handlers.ts';
  final bun = findBun();
  final skip = bun == null
      ? 'bun not installed'
      : !File(handlers).existsSync()
          ? 'CMAT report handlers not found at $handlers'
          : null;

  Process? server;
  late Uri base;
  final err = StringBuffer();

  setUpAll(() async {
    if (skip != null) return;
    server = await Process.start(
        bun!, ['run', p.join(Directory.current.path, 'test', 'fixtures', 'cmat_report_server.ts'), cmatDir, driverKey]);
    server!.stderr.transform(utf8.decoder).listen(err.write);
    final lines = server!.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final port = await lines.firstWhere((l) => l.startsWith('PORT ')).timeout(const Duration(seconds: 20),
        onTimeout: () => throw StateError('bun report server did not start: $err'));
    lines.listen((_) {});
    base = Uri.parse('http://127.0.0.1:${port.substring(5).trim()}');
  });

  tearDownAll(() async {
    server?.kill();
    await server?.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  });

  test('a redacted app report → 201, and the server stores exactly the app\'s redacted text', () async {
    final report = buildProblemReport(
      category: 'upload',
      description: 'Upload failed at 40.128091,-82.977705 with $driverKey',
      app: const AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'iOS'),
      device: const {'os': 'ios', 'osVersion': '26.0.1', 'locale': 'en_US'},
      radio: const {'name': 'KE4BFI-v4', 'firmware': '1.9', 'freqMhz': 910.525, 'bwKhz': 62.5, 'sf': 7, 'cr': 5, 'txDbm': 22},
      log: const [
        '2026-10-17T14:02:11Z Authorization: Bearer abc.def-ghi',
        '2026-10-17T14:02:12Z observer mqtt://obs:hunter2@broker.example:1883',
        '2026-10-17T14:02:13Z > set mqtt1.password x',
        '2026-10-17T14:02:14Z password=hunter2',
      ],
      driverKey: driverKey,
    );
    final r = await HttpCmatClient(base).reportProblem(driverKey, report.body);
    expect(r.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(r.status, 'new');

    final st = jsonDecode((await http.get(base.resolve('/__test/reports'))).body) as Map<String, dynamic>;
    final stored = (st['reports'] as List).cast<Map<String, dynamic>>().singleWhere((x) => x['id'] == r.id);
    final sent = jsonDecode(report.body) as Map<String, dynamic>;
    expect(stored['description'], sent['description']);
    expect(stored['log'], sent['log']);
    expect(stored['category'], 'upload');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
