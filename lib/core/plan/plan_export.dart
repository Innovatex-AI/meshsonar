// Plan exports and node imports (release 0.38 A11; build plan 4.3 improvements 10 and 18, spec section 4.2 item 10).
//
// Exports, each a complete file the share sheet hands to Files, Google Earth, a GIS tool or a notes app:
//   - KML 2.2 (`application/vnd.google-earth.kml+xml`): one Placemark per node, a folder per status, the radio in the
//     document description, antenna height as the point's altitude above ground.
//   - GeoJSON (RFC 7946, `application/geo+json`): a FeatureCollection of Points ([lon, lat]), the plan's radio and name in a
//     `meshsonar` foreign member.
//   - MeshCore setup commands (`text/plain`): for each of the person's own repeaters and planned sites, the CLI lines to type
//     into the repeater's admin console. Only commands the app's own repeater admin knows (lib/radio/repeater_settings.dart,
//     whose ranges are the firmware's CommonCLI.cpp ones) are emitted, each checked by that setting's own validator:
//     `set name`, `set lat`, `set lon`, `set radio f,bw,sf,cr`, `set tx`, `set txdelay`, then `advert`.
// Privacy: an export leaves the phone like a share link, so it follows the same rule (plan_codec.dart): the position of a
// node that is the person's own (`mine`) or installed is rounded to 2 decimals (about 1 km) unless [exactPositions] is
// true, and the `mine` flag itself is never written.
//
// Imports: MeshCore contacts JSON (the companion apps' / meshcore-cli `contacts` export: an array, or an object keyed by
// public key, of {public_key, type, adv_name, adv_lat, adv_lon, ...}), the public repeater list (map.meshcore.io
// `/api/v1/nodes`, the same field names) and MeshSonar's own `network-repeaters` rows ([key, name, lat, lon, type, ...]).
// Nodes with no position (MeshCore writes 0,0), with the no-entry sign in the name (U+1F6AB: the owner hides the
// location) or that are sensors are skipped and counted, never guessed at. Pure Dart.
import 'dart:convert';
import 'dart:math' as math;

import '../../radio/protocol.dart' show invalidNodeNameChars, maxAdvertNameBytesWithPosition, utf8Truncate;
import '../../radio/repeater_settings.dart' show BoardLimits, RadioParams, settingFor;
import '../heard.dart' show haversineM;
import '../plan_contract.dart' show PlanPoint, PlanRadio;
import 'plan_model.dart';

// ------------------------------------------------------------------------------------------------ files

enum PlanExportFormat {
  kml('KML', 'kml', 'application/vnd.google-earth.kml+xml'),
  geojson('GeoJSON', 'geojson', 'application/geo+json'),
  cli('MeshCore setup commands', 'txt', 'text/plain');

  final String label, extension, mimeType;
  const PlanExportFormat(this.label, this.extension, this.mimeType);
}

class PlanExportFile {
  final PlanExportFormat format;
  final String fileName;
  final String content;
  const PlanExportFile(this.format, this.fileName, this.content);
}

/// A file-name stem from the plan's name: `meshsonar-plan-north-ridge` (ASCII letters and digits only, at most 48 chars).
String planFileStem(Plan plan) {
  final words = RegExp(r'[a-z0-9]+').allMatches(plan.name.toLowerCase()).map((m) => m.group(0)!).join('-');
  var stem = words.isEmpty ? 'meshsonar-plan' : 'meshsonar-plan-$words';
  if (stem.length > 48) stem = stem.substring(0, 48).replaceFirst(RegExp(r'-+$'), '');
  return stem;
}

/// The file for [format].
PlanExportFile exportPlan(Plan plan, PlanExportFormat format, {bool exactPositions = false}) {
  final stem = planFileStem(plan);
  return switch (format) {
    PlanExportFormat.kml => PlanExportFile(format, '$stem.kml', planToKml(plan, exactPositions: exactPositions)),
    PlanExportFormat.geojson => PlanExportFile(format, '$stem.geojson', planToGeoJson(plan, exactPositions: exactPositions)),
    PlanExportFormat.cli => PlanExportFile(format, '$stem-setup.txt', meshcoreSetupText(plan, exactPositions: exactPositions)),
  };
}

/// How many node positions an export (or link) of [plan] rounds to about 1 km.
int roundedNodeCount(Plan plan, {bool exactPositions = false}) => exactPositions ? 0 : plan.nodes.where((n) => n.sensitivePosition).length;

double _round(double v, int places) => double.parse(v.toStringAsFixed(places));

/// The node as it leaves the phone: a sensitive position rounded to about 1 km (and marked approximate) unless exact.
PlanNode exportedNode(PlanNode n, {bool exactPositions = false}) =>
    !exactPositions && n.sensitivePosition ? n.copyWith(lat: _round(n.lat, 2), lon: _round(n.lon, 2), approximate: true) : n;

String nodeStatusLabel(PlanNodeStatus s) => switch (s) {
      PlanNodeStatus.planned => 'Planned',
      PlanNodeStatus.installed => 'Installed',
      PlanNodeStatus.existing => 'On the network',
    };

String _radioText(PlanRadio r) => '${_num(r.freqMHz)} MHz, ${_num(r.bwKHz)} kHz, SF${r.sf}, CR${r.cr}';

String _num(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

String _nodeSummary(PlanNode n) {
  final parts = <String>[
    '${nodeStatusLabel(n.status)} ${n.role == PlanNodeRole.handheld ? 'handheld' : 'repeater'}',
    'antenna ${_num(_round(n.antennaM, 1))} m above ground',
    if (n.role == PlanNodeRole.repeater) '${_num(n.effectiveTxDbm)} dBm',
    if (n.approximate) 'position rounded to about 1 km',
  ];
  return parts.join(' · ');
}

// ------------------------------------------------------------------------------------------------ KML

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
    .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');

// KML colours are aabbggrr.
const Map<PlanNodeStatus, String> _kmlColour = {
  PlanNodeStatus.planned: 'ff2a9df4', // amber
  PlanNodeStatus.installed: 'ff50af4c', // green
  PlanNodeStatus.existing: 'fff39621', // blue
};

String planToKml(Plan plan, {bool exactPositions = false}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
    ..writeln('<Document>')
    ..writeln('<name>${_xml(plan.name)}</name>')
    ..writeln('<description>${_xml('MeshSonar plan, ${plan.nodes.length} ${plan.nodes.length == 1 ? 'node' : 'nodes'}. Radio ${_radioText(plan.radio)}. Every modelled number is an estimate.')}</description>');
  for (final s in PlanNodeStatus.values) {
    b
      ..writeln('<Style id="${s.wire}">')
      ..writeln('<IconStyle><color>${_kmlColour[s]}</color><scale>1.1</scale></IconStyle>')
      ..writeln('<LabelStyle><scale>0.9</scale></LabelStyle>')
      ..writeln('</Style>');
  }
  for (final s in PlanNodeStatus.values) {
    final nodes = [for (final n in plan.nodes) if (n.status == s) exportedNode(n, exactPositions: exactPositions)];
    if (nodes.isEmpty) continue;
    b
      ..writeln('<Folder>')
      ..writeln('<name>${_xml(nodeStatusLabel(s))}</name>');
    for (final n in nodes) {
      b
        ..writeln('<Placemark>')
        ..writeln('<name>${_xml(n.name)}</name>')
        ..writeln('<description>${_xml(_nodeSummary(n))}</description>')
        ..writeln('<styleUrl>#${s.wire}</styleUrl>')
        ..writeln('<ExtendedData>');
      for (final e in _properties(n).entries) {
        b.writeln('<Data name="${_xml(e.key)}"><value>${_xml('${e.value}')}</value></Data>');
      }
      b
        ..writeln('</ExtendedData>')
        ..writeln('<Point><altitudeMode>relativeToGround</altitudeMode><coordinates>${_round(n.lon, 5)},${_round(n.lat, 5)},${_round(n.antennaM, 1)}</coordinates></Point>')
        ..writeln('</Placemark>');
    }
    b.writeln('</Folder>');
  }
  b
    ..writeln('</Document>')
    ..writeln('</kml>');
  return b.toString();
}

/// What each exported node carries besides its position (never `mine`).
Map<String, Object> _properties(PlanNode n) => {
      'status': n.status.wire,
      'role': n.role.wire,
      'antennaM': _round(n.antennaM, 1),
      if (n.role == PlanNodeRole.repeater) 'txDbm': n.effectiveTxDbm,
      'gainDbi': _round(n.effectiveGainDbi, 1),
      if (n.mount != null) 'mount': n.mount!.wire,
      if (n.existingKey != null) 'publicKey': n.existingKey!,
      if (n.approximate) 'approx': true,
    };

// ------------------------------------------------------------------------------------------------ GeoJSON

String planToGeoJson(Plan plan, {bool exactPositions = false}) {
  final doc = {
    'type': 'FeatureCollection',
    'meshsonar': {
      'v': Plan.version,
      'name': plan.name,
      'region': ?plan.region,
      'radio': plan.radio.toJson(),
      'note': 'Every modelled number is an estimate.',
    },
    'features': [
      for (final raw in plan.nodes)
        (() {
          final n = exportedNode(raw, exactPositions: exactPositions);
          return {
            'type': 'Feature',
            'id': n.id,
            'geometry': {
              'type': 'Point',
              'coordinates': [_round(n.lon, 5), _round(n.lat, 5)],
            },
            'properties': {'name': n.name, ..._properties(n)},
          };
        })(),
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
}

// ------------------------------------------------------------------------------------------------ MeshCore CLI

/// The setup commands for one node.
class CliBlock {
  final PlanNode node;

  /// Exactly what to type, one command per line.
  final List<String> commands;

  /// Plain-words notes (what a value is, what was left out and why). Never typed into the repeater.
  final List<String> notes;
  const CliBlock(this.node, this.commands, this.notes);
}

/// Does the setup export cover [n]? The person's own radios and every planned or installed repeater; a network repeater
/// that is someone else's is not theirs to set up.
bool cliCovers(PlanNode n) => n.role == PlanNodeRole.repeater && (n.status != PlanNodeStatus.existing || n.mine);

/// Flood TX delay for a repeater at [antennaM] metres. An estimate, not a firmware rule: a high site hears many more
/// repeaters, so it waits longer before repeating a flood and lets the lower, local repeaters go first (fewer collisions);
/// a low site keeps the firmware default 0.5. Always inside the firmware range 0..2.
double suggestedTxDelay(double antennaM) => antennaM >= 30
    ? 1.5
    : antennaM >= 15
        ? 1.0
        : 0.5;

/// The name as `set name` takes it: the characters the firmware refuses removed and cut to the 23 bytes an advert with a
/// position can carry.
String cliNodeName(String name) {
  final bad = invalidNodeNameChars.split('').toSet();
  final clean = name.split('').where((c) => !bad.contains(c)).join().replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  return utf8.decode(utf8Truncate(clean, maxAdvertNameBytesWithPosition), allowMalformed: false).trim();
}

/// A command for setting [key] with [raw], or null when the app's own validator refuses the value (then nothing is sent
/// for it). The limits allow any power the firmware takes; the note says when it is above 22 dBm.
String? _cli(String key, String raw) {
  final def = settingFor(key);
  if (def == null) return null;
  if (def.validate(raw, const BoardLimits(30)) != null) return null;
  return def.command(def.normalize(raw));
}

CliBlock meshcoreCliBlock(Plan plan, PlanNode raw, {bool exactPositions = false}) {
  final n = exportedNode(raw, exactPositions: exactPositions);
  final cmds = <String>[];
  final notes = <String>[];
  final name = cliNodeName(n.name);
  final setName = name.isEmpty ? null : _cli('name', name);
  if (setName != null) {
    cmds.add(setName);
    if (name != n.name.trim()) notes.add('Name shortened to "$name": a repeater name that travels with a position holds 23 bytes, without [ ] \\ : , ? *.');
  } else {
    notes.add('No name command: "${n.name}" has no characters a repeater name can hold.');
  }
  for (final c in [_cli('lat', '${n.lat}'), _cli('lon', '${n.lon}')]) {
    if (c != null) cmds.add(c);
  }
  if (n.approximate) notes.add('Position rounded to about 1 km. Turn on exact positions before exporting to set the real spot.');
  final radio = _cli('radio', RadioParams(plan.radio.freqMHz, plan.radio.bwKHz, plan.radio.sf, plan.radio.cr).text);
  if (radio != null) {
    cmds.add(radio);
    notes.add('Radio ${_radioText(plan.radio)} applies after the repeater reboots; every radio that talks to it must use the same values.');
  } else {
    notes.add('No radio command: the plan\'s radio is outside what a repeater accepts.');
  }
  if (n.txDbm != null) {
    final tx = n.txDbm!.round();
    final c = _cli('tx', '$tx');
    if (c != null) {
      cmds.add(c);
      if (tx > 22) notes.add('$tx dBm is above 22 dBm: check your local rules and that the board can do it.');
    } else {
      notes.add('No power command: ${_num(n.txDbm!)} dBm is outside 1 to 30 dBm.');
    }
  } else {
    notes.add('Power left as it is (the plan uses ${_num(defaultTxDbm)} dBm).');
  }
  final delay = suggestedTxDelay(n.antennaM);
  final d = _cli('txdelay', '$delay');
  if (d != null) {
    cmds.add(d);
    notes.add('TX delay ${_num(delay)} for an antenna ${_num(_round(n.antennaM, 1))} m up (estimate: higher sites wait longer so local repeaters go first).');
  }
  cmds.add('advert');
  return CliBlock(n, cmds, notes);
}

/// A block for every node [cliCovers], in plan order.
List<CliBlock> meshcoreCliBlocks(Plan plan, {bool exactPositions = false}) =>
    [for (final n in plan.nodes) if (cliCovers(n)) meshcoreCliBlock(plan, n, exactPositions: exactPositions)];

/// The setup file: a header, then per repeater its notes (lines starting with #) and its commands. Only the lines that do
/// not start with # are typed into the repeater.
String meshcoreSetupText(Plan plan, {bool exactPositions = false}) {
  final blocks = meshcoreCliBlocks(plan, exactPositions: exactPositions);
  final b = StringBuffer()
    ..writeln('# MeshSonar plan "${plan.name}": MeshCore repeater setup')
    ..writeln('# Log in to each repeater as admin (MeshSonar: the repeater\'s Admin page, or any MeshCore console) and send')
    ..writeln('# its lines one at a time. Lines starting with # are notes: do not send them.')
    ..writeln('# Every advert publishes the repeater\'s name and position, on public maps too.');
  if (blocks.isEmpty) {
    b
      ..writeln('#')
      ..writeln('# This plan has no repeater of yours or planned site to set up.');
  }
  for (final blk in blocks) {
    b
      ..writeln()
      ..writeln('# ${blk.node.name} (${nodeStatusLabel(blk.node.status).toLowerCase()})');
    for (final note in blk.notes) {
      b.writeln('# $note');
    }
    for (final c in blk.commands) {
      b.writeln(c);
    }
  }
  return b.toString();
}

// ------------------------------------------------------------------------------------------------ import

/// One node read from a contacts or repeater list.
class ImportedNode {
  final String name;
  final double lat, lon;

  /// Public key, 64 lower-case hex, when the list had a valid one.
  final String? key;
  final PlanNodeRole role;
  const ImportedNode({required this.name, required this.lat, required this.lon, this.key, this.role = PlanNodeRole.repeater});

  PlanPoint get point => PlanPoint(lat, lon);
}

class NodeImport {
  final List<ImportedNode> nodes;

  /// Entries read, and why the others were left out.
  final int read, noPosition, hidden, sensors, unreadable;
  const NodeImport({required this.nodes, required this.read, this.noPosition = 0, this.hidden = 0, this.sensors = 0, this.unreadable = 0});

  int get skipped => noPosition + hidden + sensors + unreadable;

  /// "41 with a position; 12 without one, 2 hidden by their owners and 1 sensor left out."
  String get summary {
    final why = <String>[
      if (noPosition > 0) '$noPosition without a position',
      if (hidden > 0) '$hidden hidden by ${hidden == 1 ? 'its owner' : 'their owners'}',
      if (sensors > 0) '$sensors ${sensors == 1 ? 'sensor' : 'sensors'}',
      if (unreadable > 0) '$unreadable unreadable',
    ];
    final head = '${nodes.length} with a position';
    if (why.isEmpty) return '$head.';
    final list = why.length == 1 ? why.single : '${why.sublist(0, why.length - 1).join(', ')} and ${why.last}';
    return '$head; $list left out.';
  }

  /// The nodes nearest [centre] first (all of them when there is no centre).
  List<ImportedNode> nearest(PlanPoint? centre) {
    if (centre == null) return nodes;
    final d = {for (final n in nodes) n: haversineM(centre.lat, centre.lon, n.lat, n.lon)};
    return [...nodes]..sort((a, b) => d[a]!.compareTo(d[b]!));
  }
}

/// The owner hides the position: the MeshCore convention is a no-entry sign in the name.
const String hiddenPositionMark = '\u{1F6AB}';

final RegExp _hexKey = RegExp(r'^[0-9a-f]{64}$');

double? _coord(Object? v) {
  if (v is num && v.isFinite) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// 1 companion/chat, 2 repeater, 3 room server, 4 sensor; null when the entry does not say.
int? _type(Object? t) {
  if (t is num) return t.toInt();
  if (t is String) {
    final s = t.trim().toLowerCase();
    if (int.tryParse(s) != null) return int.parse(s);
    if (const {'chat', 'companion', 'client', 'cli'}.contains(s)) return 1;
    if (const {'repeater', 'rep', 'rptr'}.contains(s)) return 2;
    if (const {'room', 'room_server', 'roomserver', 'room server'}.contains(s)) return 3;
    if (s == 'sensor') return 4;
  }
  return null;
}

/// Reads a MeshCore contacts export, the public repeater list or `network-repeaters` rows. Throws [FormatException] with a
/// sentence the UI can show when [text] is none of them.
NodeImport parseNodeImport(String text) {
  final Object? j;
  try {
    j = jsonDecode(text.trim());
  } on FormatException {
    throw const FormatException('This is not JSON. Paste a MeshCore contacts export or a repeater list.');
  }
  final List<Object?> entries;
  if (j is List) {
    entries = j;
  } else if (j is Map) {
    final inner = j['contacts'] ?? j['nodes'] ?? j['rows'] ?? j['repeaters'];
    if (inner is List) {
      entries = inner;
    } else if (inner is Map) {
      entries = [for (final e in inner.entries) e.value is Map ? {'public_key': e.key, ...(e.value as Map)} : e.value];
    } else if (j.values.isNotEmpty && j.values.every((v) => v is Map)) {
      // meshcore-cli / meshcore_py: an object keyed by public key.
      entries = [for (final e in j.entries) {'public_key': e.key, ...(e.value as Map)}];
    } else {
      throw const FormatException('No contacts or repeaters in this JSON.');
    }
  } else {
    throw const FormatException('No contacts or repeaters in this JSON.');
  }
  final out = <ImportedNode>[];
  final seen = <String>{};
  var noPos = 0, hidden = 0, sensors = 0, bad = 0;
  for (final e in entries) {
    Object? k, nm, la, lo, t;
    if (e is List) {
      if (e.length < 4) {
        bad++;
        continue;
      }
      k = e[0];
      nm = e[1];
      la = e[2];
      lo = e[3];
      t = e.length > 4 ? e[4] : null;
    } else if (e is Map) {
      k = e['public_key'] ?? e['publicKey'] ?? e['key'] ?? e['pubkey'];
      nm = e['adv_name'] ?? e['name'] ?? e['advName'];
      la = e['adv_lat'] ?? e['lat'] ?? e['latitude'] ?? e['advLat'];
      lo = e['adv_lon'] ?? e['lon'] ?? e['lng'] ?? e['longitude'] ?? e['advLon'];
      t = e['type'] ?? e['node_type'] ?? e['role'];
    } else {
      bad++;
      continue;
    }
    final type = _type(t);
    final rawKey = k is String ? k.trim().toLowerCase() : null;
    final key = rawKey != null && _hexKey.hasMatch(rawKey) ? rawKey : null;
    final name = nm is String && nm.trim().isNotEmpty ? nm.trim() : key?.substring(0, 8);
    if (name == null) {
      bad++;
      continue;
    }
    if (name.contains(hiddenPositionMark)) {
      hidden++;
      continue;
    }
    if (type == 4) {
      sensors++;
      continue;
    }
    final lat = _coord(la), lon = _coord(lo);
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180 || (lat == 0 && lon == 0)) {
      noPos++;
      continue;
    }
    if (key != null && !seen.add(key)) continue;
    out.add(ImportedNode(name: name, lat: lat, lon: lon, key: key, role: type == 1 ? PlanNodeRole.handheld : PlanNodeRole.repeater));
  }
  if (out.isEmpty && noPos == 0 && hidden == 0 && sensors == 0) {
    throw const FormatException('No contacts or repeaters in this JSON.');
  }
  return NodeImport(nodes: out, read: entries.length, noPosition: noPos, hidden: hidden, sensors: sensors, unreadable: bad);
}

/// Distance in km for a list row ("3.2 km").
String kmText(PlanPoint a, PlanPoint b) {
  final km = haversineM(a.lat, a.lon, b.lat, b.lon) / 1000;
  return km < 10 ? '${km.toStringAsFixed(1)} km' : '${math.max(10, km.round())} km';
}
