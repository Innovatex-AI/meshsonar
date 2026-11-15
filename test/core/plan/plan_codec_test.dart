import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_codec.dart';
import 'package:meshsonar/core/plan/plan_model.dart';

import 'plan_test_kit.dart';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  final plan = thirtyNodePlan();

  test('30 nodes round trip exactly with exact positions', () {
    final e = encodePlanShare(plan, exactPositions: true);
    expect(e.roundedNodes, 0);
    expect(e.warning, isNull);
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(e.code), isTrue, reason: 'base64url, no padding');
    expect(e.code.length, lessThan(3000), reason: 'a full plan fits comfortably in a link');
    final back = decodePlanShare(e.code);
    expect(back.nodes.length, 30);
    for (var i = 0; i < 30; i++) {
      expect(back.nodes[i], plan.nodes[i].copyWith(mine: false), reason: 'node $i: everything but the sharer\'s mine flag');
    }
    expect(back.name, plan.name);
    expect(back.radio, plan.radio);
    expect(back.goal, plan.goal);
    expect(back.receiverM, plan.receiverM);
  });

  test('the committed share code (golden) still decodes to the 30-node plan', () {
    final code = File('test/fixtures/plan_native/plan_v1_30_nodes.share.txt').readAsStringSync().trim();
    final back = decodePlanShare(code);
    expect(back.nodes.length, 30);
    expect(back.nodes.map((n) => n.id), plan.nodes.map((n) => n.id));
    expect(back.nodes.where((n) => n.approximate).length, 14);
  });

  test('by default mine and installed positions are rounded to about 1 km and marked approx; others stay exact', () {
    final e = encodePlanShare(plan);
    final sensitive = plan.nodes.where((n) => n.mine || n.status == PlanNodeStatus.installed).length;
    expect(e.roundedNodes, sensitive);
    expect(e.rounded, isTrue);
    expect(e.warning, contains('$sensitive positions'));
    expect(e.warning, contains('about 1 km'));
    final back = decodePlanShare(e.code);
    for (var i = 0; i < 30; i++) {
      final o = plan.nodes[i], b = back.nodes[i];
      expect(b.mine, isFalse, reason: 'the sharer\'s ownership never travels');
      if (o.sensitivePosition) {
        expect(b.approximate, isTrue);
        expect(b.lat, double.parse(o.lat.toStringAsFixed(2)));
        expect(b.lon, double.parse(o.lon.toStringAsFixed(2)));
      } else {
        expect(b.approximate, isFalse);
        expect((b.lat, b.lon), (o.lat, o.lon));
      }
    }
    final j = jsonDecode(utf8.decode(ZLibDecoder().convert(base64Url.decode(base64Url.normalize(e.code))))) as Map;
    expect(j.containsKey('updatedAt'), isFalse);
    expect((j['nodes'] as List).any((n) => (n as Map).containsKey('mine')), isFalse);
  });

  test('zlib deflate (what the browser\'s DecompressionStream("deflate") reads) of the Plan JSON v1', () {
    final e = encodePlanShare(plan, exactPositions: true);
    final raw = base64Url.decode(base64Url.normalize(e.code));
    expect(raw[0], 0x78, reason: 'zlib header');
    final j = jsonDecode(utf8.decode(ZLibDecoder().convert(raw))) as Map;
    expect(j['v'], 1);
    expect((j['nodes'] as List).length, 30);
  });

  test('share links: base, fragment, helpers', () {
    final e = encodePlanShare(plan);
    final uri = planShareUri(e.code);
    expect(uri.toString(), startsWith('https://meshsonar.com/share/plan#'));
    expect(uri.query, isEmpty, reason: 'the plan is in the fragment, never sent to a server');
    expect(planCodeFrom(uri), e.code);
    expect(planCodeFrom(Uri.parse('meshsonar://plan#plan=${e.code}')), e.code);
    expect(planCodeFrom(Uri.parse('https://meshsonar.com/share/plan')), isNull);
    expect(decodePlanUri(uri).nodes.length, 30);
    expect(() => decodePlanUri(Uri.parse('https://meshsonar.com/share/plan')), throwsFormatException);
    // Padded codes (some share sheets add `=`) are read too.
    final padded = base64Url.encode(base64Url.decode(base64Url.normalize(e.code)));
    expect(decodePlanShare(padded).nodes.length, 30);
  });

  test('damaged, oversized and hostile codes are refused with a sentence', () {
    expect(() => decodePlanShare(''), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('no plan'))));
    expect(() => decodePlanShare('not base64!'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('damaged'))));
    expect(() => decodePlanShare(_b64(utf8.encode('plain text, not deflate'))), throwsFormatException);
    expect(() => decodePlanShare(_b64(ZLibEncoder().convert(utf8.encode('[1,2,3]')))), throwsFormatException);
    expect(() => decodePlanShare(_b64(ZLibEncoder().convert(utf8.encode('{"v":2,"nodes":[]}')))), throwsFormatException);
    expect(() => decodePlanShare('A' * (maxShareCodeLength + 1)), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too large'))));
    // A deflate bomb: 10 MB of spaces compresses to a few KB and must stop at the cap.
    final bomb = ZLibEncoder(level: 9).convert(List<int>.filled(10 * 1024 * 1024, 0x20));
    expect(bomb.length, lessThan(maxShareCodeLength));
    expect(() => decodePlanShare(_b64(bomb)), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too large'))));
  });
}
