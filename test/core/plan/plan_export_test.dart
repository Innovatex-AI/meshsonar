// Plan exports (KML, GeoJSON, MeshCore setup commands) and contacts / public-repeater import (release 0.38 A11).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_export.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/radio/repeater_settings.dart' show parseRadioParams, settingFor, BoardLimits;

import 'plan_test_kit.dart';

final _t = DateTime.utc(2026, 11, 15, 12);

Plan _plan() => Plan(id: 'p_x', name: 'North Ridge & <Co>', radio: PlanRadio.usDefault, createdAt: _t, nodes: const [
      PlanNode(id: 'a', name: 'My Tower: [roof]*', lat: 39.961234, lon: -82.998765, status: PlanNodeStatus.planned, mine: true, heightM: 32, txDbm: 22),
      PlanNode(id: 'b', name: 'Hill site', lat: 40.012345, lon: -83.054321, status: PlanNodeStatus.planned, heightM: 18),
      PlanNode(id: 'c', name: 'Installed one', lat: 40.1, lon: -83.2, status: PlanNodeStatus.installed),
      PlanNode(id: 'd', name: 'Someone else', lat: 40.2, lon: -83.3, status: PlanNodeStatus.existing),
      PlanNode(id: 'e', name: 'Handheld', lat: 40.3, lon: -83.4, role: PlanNodeRole.handheld),
    ]);

/// A small well-formedness check: every tag closes in order, entities are the five XML ones, one root.
void expectWellFormedXml(String xml) {
  final body = xml.replaceFirst(RegExp(r'^<\?xml[^>]*\?>\s*'), '');
  final stack = <String>[];
  var roots = 0;
  for (final m in RegExp(r'<(/?)([A-Za-z][\w:.-]*)([^>]*?)(/?)>').allMatches(body)) {
    final close = m.group(1) == '/', name = m.group(2)!, selfClose = m.group(4) == '/';
    if (close) {
      expect(stack, isNotEmpty, reason: 'stray </$name>');
      expect(stack.removeLast(), name, reason: 'mismatched </$name>');
    } else if (!selfClose) {
      if (stack.isEmpty) roots++;
      stack.add(name);
    }
  }
  expect(stack, isEmpty, reason: 'unclosed tags');
  expect(roots, 1);
  for (final m in RegExp(r'&([^;\s]*);?').allMatches(body)) {
    expect(const {'amp', 'lt', 'gt', 'quot', 'apos'}, contains(m.group(1)), reason: 'bad entity ${m.group(0)}');
  }
  final text = body.replaceAll(RegExp(r'<[^>]*>'), '');
  expect(text.contains('<'), isFalse);
}

void main() {
  group('KML', () {
    test('is well-formed KML 2.2 with one placemark per node, escaped names, positions rounded for mine/installed', () {
      final kml = planToKml(_plan());
      expect(kml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(kml, contains('<kml xmlns="http://www.opengis.net/kml/2.2">'));
      expectWellFormedXml(kml);
      expect(RegExp('<Placemark>').allMatches(kml), hasLength(5));
      expect(kml, contains('<name>North Ridge &amp; &lt;Co&gt;</name>'));
      // Mine (a) and installed (c) rounded to 2 decimals; planned (b) exact; lon,lat,alt order.
      expect(kml, contains('<coordinates>-83.0,39.96,32.0</coordinates>'));
      expect(kml, contains('<coordinates>-83.05432,40.01235,18.0</coordinates>'));
      expect(kml, contains('<coordinates>-83.2,40.1,10.0</coordinates>'));
      expect(kml, contains('position rounded to about 1 km'));
      expect(kml, isNot(contains('mine')));
    });

    test('exact positions keep the spot', () {
      expect(planToKml(_plan(), exactPositions: true), contains('<coordinates>-82.99877,39.96123,32.0</coordinates>'));
    });

    test('a 30-node plan parses', () {
      final kml = planToKml(thirtyNodePlan());
      expectWellFormedXml(kml);
      expect(RegExp('<Placemark>').allMatches(kml), hasLength(30));
    });
  });

  group('GeoJSON', () {
    test('is an RFC 7946 FeatureCollection of [lon, lat] points without the mine flag', () {
      final j = jsonDecode(planToGeoJson(_plan())) as Map<String, dynamic>;
      expect(j['type'], 'FeatureCollection');
      final f = (j['features'] as List).cast<Map<String, dynamic>>();
      expect(f, hasLength(5));
      for (final x in f) {
        expect(x['type'], 'Feature');
        final g = x['geometry'] as Map;
        expect(g['type'], 'Point');
        final c = (g['coordinates'] as List).cast<num>();
        expect(c, hasLength(2));
        expect(c[0].abs(), lessThanOrEqualTo(180));
        expect(c[1].abs(), lessThanOrEqualTo(90));
        expect((x['properties'] as Map).containsKey('mine'), isFalse);
      }
      expect(f[0]['geometry']['coordinates'], [-83.0, 39.96]);
      expect(f[0]['properties']['approx'], true);
      expect(f[1]['geometry']['coordinates'], [-83.05432, 40.01235]);
      expect(f[0]['properties']['name'], 'My Tower: [roof]*');
      expect(j['meshsonar']['radio'], PlanRadio.usDefault.toJson());
    });

    test('a 30-node plan parses', () {
      final j = jsonDecode(planToGeoJson(thirtyNodePlan(), exactPositions: true)) as Map;
      expect((j['features'] as List), hasLength(30));
    });
  });

  group('MeshCore setup commands', () {
    test('covers own and planned/installed repeaters only; every command is one the repeater admin accepts', () {
      final blocks = meshcoreCliBlocks(_plan(), exactPositions: true);
      expect(blocks.map((b) => b.node.id), ['a', 'b', 'c'], reason: 'not someone else\'s network repeater, not a handheld');
      final a = blocks.first;
      expect(a.commands, [
        'set name My Tower roof',
        'set lat 39.961234',
        'set lon -82.998765',
        'set radio 910.525,62.5,7,5',
        'set tx 22',
        'set txdelay 1.5',
        'advert',
      ]);
      expect(a.notes.join(' '), contains('shortened'));
      for (final b in blocks) {
        for (final c in b.commands) {
          if (c == 'advert') continue;
          final parts = c.split(' ');
          expect(parts.first, 'set');
          final def = settingFor(parts[1]);
          expect(def, isNotNull, reason: c);
          expect(def!.validate(parts.sublist(2).join(' '), const BoardLimits(30)), isNull, reason: c);
        }
      }
      expect(blocks[1].commands, contains('set txdelay 1'));
      expect(blocks[1].commands.any((c) => c.startsWith('set tx ')), isFalse, reason: 'power left alone when not set');
    });

    test('rounded positions by default, said in the notes', () {
      final a = meshcoreCliBlocks(_plan()).first;
      expect(a.commands, contains('set lat 39.960000'));
      expect(a.notes.join(' '), contains('about 1 km'));
    });

    test('names are cut to the 23 bytes an advert with a position carries', () {
      expect(cliNodeName('A very long repeater name that goes on'), 'A very long repeater na');
      expect(cliNodeName('???'), '');
      expect(cliNodeName('Café ☕ North'), 'Café ☕ North');
    });

    test('tx delay by height stays inside the firmware range', () {
      for (final h in [1.0, 10, 15, 29.9, 30, 300]) {
        final d = suggestedTxDelay(h.toDouble());
        expect(d, inInclusiveRange(0, 2));
      }
      expect(suggestedTxDelay(8), 0.5);
    });

    test('the text file: notes behind #, commands bare, a radio that parses', () {
      final text = meshcoreSetupText(_plan());
      final cmds = text.split('\n').where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
      expect(cmds.where((c) => c == 'advert'), hasLength(3));
      final radio = cmds.firstWhere((c) => c.startsWith('set radio ')).substring(10);
      expect(parseRadioParams(radio), isNotNull);
      expect(meshcoreSetupText(Plan(id: 'p', createdAt: _t)), contains('no repeater of yours'));
    });

    test('file names', () {
      expect(exportPlan(_plan(), PlanExportFormat.kml).fileName, 'meshsonar-plan-north-ridge-co.kml');
      expect(exportPlan(_plan(), PlanExportFormat.geojson).fileName, 'meshsonar-plan-north-ridge-co.geojson');
      expect(exportPlan(_plan(), PlanExportFormat.cli).fileName, 'meshsonar-plan-north-ridge-co-setup.txt');
      expect(planFileStem(Plan(id: 'p', name: '!!!', createdAt: _t)), 'meshsonar-plan');
      expect(roundedNodeCount(_plan()), 2);
      expect(roundedNodeCount(_plan(), exactPositions: true), 0);
    });
  });

  group('import', () {
    final k1 = '1a' * 32, k2 = '2b' * 32, k3 = '3c' * 32, k4 = '4d' * 32, k5 = '5e' * 32;

    test('MeshCore contacts JSON (an object keyed by public key, meshcore-cli)', () {
      final r = parseNodeImport(jsonEncode({
        k1: {'type': 2, 'adv_name': 'North Rpt', 'adv_lat': 40.1, 'adv_lon': -83.0},
        k2: {'type': 1, 'adv_name': 'Andy phone', 'adv_lat': 40.0, 'adv_lon': -83.1},
        k3: {'type': 2, 'adv_name': 'No fix', 'adv_lat': 0.0, 'adv_lon': 0.0},
        k4: {'type': 3, 'adv_name': '\u{1F6AB} Hidden room', 'adv_lat': 40.2, 'adv_lon': -83.2},
        k5: {'type': 4, 'adv_name': 'Weather', 'adv_lat': 40.3, 'adv_lon': -83.3},
      }));
      expect(r.read, 5);
      expect(r.nodes.map((n) => n.name), ['North Rpt', 'Andy phone']);
      expect(r.nodes[0].key, k1);
      expect(r.nodes[1].role, PlanNodeRole.handheld);
      expect(r.noPosition, 1);
      expect(r.hidden, 1);
      expect(r.sensors, 1);
      expect(r.summary, '2 with a position; 1 without a position, 1 hidden by its owner and 1 sensor left out.');
    });

    test('an array (companion app export, map.meshcore.io nodes) and network-repeaters rows', () {
      final a = parseNodeImport(jsonEncode([
        {'public_key': k1.toUpperCase(), 'type': 'REPEATER', 'name': 'Up', 'lat': '40.5', 'lon': '-83.5'},
        {'public_key': k1, 'type': 2, 'adv_name': 'Dup', 'adv_lat': 40.5, 'adv_lon': -83.5},
      ]));
      expect(a.nodes, hasLength(1), reason: 'same key once');
      expect(a.nodes.single.key, k1);
      final rows = parseNodeImport(jsonEncode({
        'v': 1,
        'rows': [
          [k2, 'Row one', 39.9, -82.9, 2, null],
          [k3, null, 39.8, -82.8, 3, 1700000000],
        ]
      }));
      expect(rows.nodes.map((n) => n.name), ['Row one', k3.substring(0, 8)]);
    });

    test('nearest first', () {
      final r = parseNodeImport(jsonEncode([
        {'public_key': k1, 'type': 2, 'adv_name': 'Far', 'adv_lat': 41.0, 'adv_lon': -83.0},
        {'public_key': k2, 'type': 2, 'adv_name': 'Near', 'adv_lat': 40.01, 'adv_lon': -83.0},
      ]));
      expect(r.nearest(const PlanPoint(40, -83)).first.name, 'Near');
    });

    test('not a list: a sentence the UI can show', () {
      expect(() => parseNodeImport('hello'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('not JSON'))));
      expect(() => parseNodeImport('{"a":1}'), throwsFormatException);
      expect(() => parseNodeImport('[]'), throwsFormatException);
    });
  });
}
