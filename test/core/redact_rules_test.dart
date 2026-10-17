// Builder (M) unit tests for the §8 rule decisions of Oct 17 and the report draft round trip; Q's acceptance tests
// are in redact_test.dart and report_body_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/messages.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/redact.dart';
import 'package:meshsonar/core/report_body.dart';

void main() {
  group('redaction rule decisions', () {
    test('R4 hides a password up to the last @ before the host', () {
      final r = redactText('broker mqtt://u:p@ss@host.example:1883/x');
      expect(r.text, 'broker mqtt://u:[redacted]@host.example:1883/x');
      expect(r.counts['mqtt'], 1);
    });

    test('C1 leaves dotted chains (versions) alone but still rounds a plain coordinate', () {
      expect(redactText('fw 10.12345.6789').text, 'fw 10.12345.6789');
      expect(redactText('v1.23456.7').text, 'v1.23456.7');
      expect(redactText('at -82.977705 now').text, 'at -82.978 now');
      expect(redactText('fix at 40.128091,-82.977705.').text, 'fix at 40.128,-82.978.', reason: 'sentence-ending period');
    });

    test('redacting twice gives the same text and zero new counts', () {
      const input = 'mqtt://u:p@ss@h set mqtt1.password x token=abc 40.128091,-82.977705 Bearer t0k';
      final once = redactText(input);
      final twice = redactText(once.text);
      expect(twice.text, once.text);
      expect(twice.counts.values.every((n) => n == 0), isTrue, reason: '${twice.counts}');
    });

    test('literal secrets are removed first and counted as secret', () {
      final r = redactText(
        'key abc-def-123456 at https://x.org/p',
        secrets: const ['abc-def-123456', 'https://x.org/p', ' '],
      );
      expect(r.text, 'key [redacted] at [redacted]');
      expect(r.counts['secret'], 2);
    });
  });

  test('a saved report comes back identical (draft round trip)', () {
    final r = buildProblemReport(
      category: 'gps',
      description: 'Jumps at 40.128091,-82.977705',
      app: const AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'iOS'),
      log: const ['line one', 'line two'],
      maxBytes: 450,
    );
    final back = ProblemReport.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
    expect(back.body, r.body);
    expect(back.bytes, r.bytes);
    expect(back.redacted, r.redacted);
    expect(back.logShortened, r.logShortened);
  });

  test('server answers map to the report messages', () {
    expect(
      friendlyReportError(const CmatException('off', status: 503)),
      'This server doesn\'t accept problem reports.',
    );
    expect(friendlyReportError(const CmatException('x', status: 502)), reportNotSentMessage);
    expect(friendlyReportError(const CmatException('network error')), reportNotSentMessage);
    expect(friendlyReportError(const CmatException('category: required', status: 400)), contains('category: required'));
  });
}
