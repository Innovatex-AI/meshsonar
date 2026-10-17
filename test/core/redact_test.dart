// AC-5 / AC-6 (spec m1-app-0.4.0 §3, §8): client-side redaction and rounding, identical to CMAT §8.
// test/fixtures/redaction-vectors.json is CMAT's canonical vectors file, copied unchanged from meshcore-insights
// src/lib/platform/redaction-vectors.json (branch m1/problem-reports, 2026-10-17, md5 660d3fddcfc723ef50d1d3856d186f79).
// Re-copy it whenever CMAT changes it; both sides must give every output and count exactly.
//
// API under test (lib/core/redact.dart):
//   RedactionResult redactText(String input)  -> .text, .counts (Map<String,int>: driverKey, jwt, bearer, secret, mqtt, coords)
//   double roundCoordinate(double v)          -> sign × (|v| × 1000).round() / 1000
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/redact.dart';

const countKeys = ['driverKey', 'jwt', 'bearer', 'secret', 'mqtt', 'coords'];

void main() {
  final vectorsFile = File('test/fixtures/redaction-vectors.json');
  final doc = jsonDecode(vectorsFile.readAsStringSync()) as Map<String, dynamic>;
  final vectors = (doc['vectors'] as List).cast<Map<String, dynamic>>();

  test('the vectors file is there and covers every rule', () {
    expect(vectors.length, greaterThanOrEqualTo(20));
    final ruleIds = (doc['rules'] as List).map((r) => (r as Map)['id']).toSet();
    expect(ruleIds, containsAll(['R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'C1']));
    for (final k in countKeys) {
      expect(vectors.any((v) => ((v['counts'] as Map)[k] ?? 0) > 0), isTrue, reason: 'no vector exercises $k');
    }
  });

  group('every vector gives the expected text and counts', () {
    for (final v in vectors) {
      test(v['name'] as String, () {
        final r = redactText(v['input'] as String);
        expect(r.text, v['output'], reason: 'input: ${v['input']}');
        final want = (v['counts'] as Map).cast<String, dynamic>();
        for (final k in countKeys) {
          expect(r.counts[k] ?? 0, want[k] ?? 0, reason: 'count $k for "${v['name']}"');
        }
      });
    }
  });

  test('output text is stable: redacting the output again gives the same text', () {
    for (final v in vectors) {
      final once = redactText(v['input'] as String).text;
      expect(redactText(once).text, once, reason: v['name'] as String);
    }
  });

  test('AC-5: a log seeded with every secret kind reaches nothing in clear; coordinates at 3 decimals', () {
    const key = 'ms_Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Q7k';
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcDEF_123-x';
    const log = '2026-10-17T14:02:11Z upload key=$key\n'
        '2026-10-17T14:02:12Z jwt $jwt\n'
        '2026-10-17T14:02:13Z Authorization: Bearer abc.def-ghi\n'
        '2026-10-17T14:02:14Z observer mqtt://obs:hunter2@broker.example:1883\n'
        '2026-10-17T14:02:15Z > set mqtt1.password x\n'
        '2026-10-17T14:02:16Z fix 40.128091,-82.977705\n';
    final r = redactText(log);
    for (final secret in [key, jwt, 'abc.def-ghi', 'hunter2', 'password x', '40.128091', '82.977705']) {
      expect(r.text, isNot(contains(secret)));
    }
    expect(r.text, contains('40.128,-82.978'));
    expect(r.text, contains('set mqtt1.password [redacted]'));
    expect(r.text.split('\n'), hasLength(7), reason: 'line breaks are kept');
    expect(RegExp(r'\d\.\d{4,}').hasMatch(r.text), isFalse, reason: 'no number with more than 3 decimals left');
  });

  test('3-decimal rounding: half away from zero, values with ≤ 3 decimals unchanged', () {
    expect(roundCoordinate(40.128091), 40.128);
    expect(roundCoordinate(-82.977705), -82.978);
    expect(roundCoordinate(1.0625), 1.063);
    expect(roundCoordinate(-1.0625), -1.063);
    expect(roundCoordinate(11.384), 11.384);
    expect(roundCoordinate(910.525), 910.525);
    expect(roundCoordinate(0.0004), 0.0);
    expect(roundCoordinate(179.99996), 180.0);
    expect(roundCoordinate(-82.977705).toStringAsFixed(3), '-82.978');
  });

  test('patterns are case-insensitive where the table says i (Dart RegExp caseSensitive: false)', () {
    expect(redactText('BEARER abc').text, 'BEARER [redacted]');
    expect(redactText('PassWord=abc').text, 'PassWord=[redacted]');
    expect(redactText('MQTT://a:b@h').text, 'MQTT://a:[redacted]@h');
    // R1/R2 are case-sensitive (no i flag).
    expect(redactText('MS_Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Ab3').text, 'MS_Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Ab3');
  });
}
