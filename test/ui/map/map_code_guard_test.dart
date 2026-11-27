// MAP slice 7 (app half, build 75): "no stray map code". A file under lib/ui that draws on a map (it imports flutter_map, or lives in
// lib/ui/map) must not (1) hard-code a colour (`Color(0x..)`, `Color.fromARGB/RGBO`, `Colors.<name>` other than transparent: map
// colours come from the Map Definition and the theme tokens) or (2) mark repeaters with a Material or SF icon (`Icons.cell_tower`,
// `AppSymbols.antenna`, `AppSymbols.locationFill`) without also using the one node symbol set ([NodeSymbol] / `paintRepeaterSprite`).
//
// The files that already broke a rule when this test was written are listed below, each with its reason. The list can only shrink:
// a new file is not allowed to join it, and an entry whose file no longer breaks the rule (or is gone) fails the test until it is
// removed. Comments are not scanned.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files allowed to hard-code a map colour, and why.
const Map<String, String> kColourAllowlist = {
  'lib/ui/map/layers/clustered_points_layer.dart': 'cluster count ink (near-black or white by the bubble colour); the cluster painter is the old layer, going with MAP slice 7',
  'lib/ui/map/layers/link_lines_layer.dart': 'white outline of the link end cap; the link style moves into the definition with the snrLink layer',
  'lib/ui/map/layers/m3_layers.dart': 'fallback colours for a definition that lacks the ramp (the layer is not drawn then)',
  'lib/ui/map/layers/repeater_name_labels.dart': 'Colors.grey fallback ink for a label with no freshness colour',
  'lib/ui/map/layers/repeater_sprites.dart': 'white ring of the repeater sprite; the sprite reads the definition symbol, the ring is its fixed halo',
  'lib/ui/map/legend_card.dart': 'black26 card shadow, not a map colour',
  'lib/ui/map/live_puck.dart': 'the live puck (white halo, black shadow, grey weak fill); owned by the Drive map',
  'lib/ui/map/map_health_overlay.dart': 'black pill with white text over the map (a status chip)',
  'lib/ui/map/parts/map_markers.dart': 'black marker shadow',
  'lib/ui/network/live/live_map_view.dart': 'Live map dot ink (white or black87 by theme); moves into the definition with the Live slice',
  'lib/ui/shell/drive_next_card.dart': 'white rings of the target dots and the me dot on the Where-to-drive-next card preview (the me dot itself is the theme primary since build 76)',
  'lib/ui/tools/tool_kit.dart': 'white ring and white number of the numbered pin in the radio tools',
};

/// Files allowed to mark repeaters with an icon without the node symbol set, and why.
const Map<String, String> kMarkerAllowlist = {
  'lib/ui/map/layers/plan_layer.dart': 'the planner\'s planned-site marker (a candidate antenna), not an existing repeater',
  'lib/ui/map/layers/plan_node_sheet.dart': 'a sheet row icon for a planned site, not a map marker',
  'lib/ui/map/sheets/repeater_sheet.dart': 'list leading icons of the repeater sheet (a list, not the map)',
  'lib/ui/plan/planner_screen.dart': 'menu and button icons of the planner (UI chrome, not map markers)',
  'lib/ui/report/drive_report_screen.dart': 'the beacon stat row icon of the drive report (not a map marker)',
};

// Not colours of their own: the fully transparent `Color(0x00000000)`, an alpha-only layer paint `Color.fromRGBO(0, 0, 0, a)` and a
// colour computed from a parsed string (`Color.fromARGB(255, int.parse(..`).
final _hex = RegExp(r'Color\(\s*0x(?!00000000\s*\))[0-9A-Fa-f]{6,8}\s*\)');
final _argb = RegExp(r'Color\.from(?:ARGB|RGBO)\((?!\s*0,\s*0,\s*0,)(?!\s*255,\s*int\.parse)');
final _named = RegExp(r'(?<![A-Za-z0-9_])Colors\.(?!transparent\b)[a-zA-Z]');
final _marker = RegExp(r'Icons\.cell_tower\w*|AppSymbols\.antenna\b|AppSymbols\.locationFill\b');
final _symbolSet = RegExp(r'\bNodeSymbol\b|\bpaintRepeaterSprite\b');

String _code(String src) => [for (final l in src.split('\n')) l.contains('//') ? l.substring(0, l.indexOf('//')) : l].join('\n');

List<File> _mapFiles() => [
      for (final e in Directory('lib/ui').listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart') && (e.path.startsWith('lib/ui/map/') || e.readAsStringSync().contains('package:flutter_map/'))) e,
    ]..sort((a, b) => a.path.compareTo(b.path));

bool _hardCodesColour(String code) => _hex.hasMatch(code) || _argb.hasMatch(code) || _named.hasMatch(code);
bool _iconMarker(String code) => _marker.hasMatch(code) && !_symbolSet.hasMatch(code);

void main() {
  final files = _mapFiles();

  test('the scan sees the map files', () {
    expect(files.length, greaterThan(20));
    expect(files.map((f) => f.path), containsAll(['lib/ui/map/map_preview.dart', 'lib/ui/map/still/path_layer.dart']));
  });

  test('no new map file hard-codes a colour', () {
    final bad = [for (final f in files) if (_hardCodesColour(_code(f.readAsStringSync())) && !kColourAllowlist.containsKey(f.path)) f.path];
    expect(bad, isEmpty, reason: 'Map colours come from the Map Definition (MapPathStyle, CoverageBandColors, the node symbol set) or the theme tokens. If a literal is truly needed, add the file to kColourAllowlist with the reason.');
  });

  test('no new map file marks repeaters with an icon instead of NodeSymbol', () {
    final bad = [for (final f in files) if (_iconMarker(_code(f.readAsStringSync())) && !kMarkerAllowlist.containsKey(f.path)) f.path];
    expect(bad, isEmpty, reason: 'Repeaters on a map are drawn with NodeSymbol (lib/ui/map/node_symbol.dart). If an icon is truly needed, add the file to kMarkerAllowlist with the reason.');
  });

  test('every allowlist entry still needs its place (the lists only shrink)', () {
    final byPath = {for (final f in files) f.path: _code(f.readAsStringSync())};
    for (final e in kColourAllowlist.entries) {
      expect(byPath.containsKey(e.key), isTrue, reason: '${e.key} is gone or no longer a map file: remove it from kColourAllowlist');
      expect(_hardCodesColour(byPath[e.key]!), isTrue, reason: '${e.key} no longer hard-codes a colour: remove it from kColourAllowlist');
      expect(e.value.trim(), isNotEmpty);
    }
    for (final e in kMarkerAllowlist.entries) {
      expect(byPath.containsKey(e.key), isTrue, reason: '${e.key} is gone or no longer a map file: remove it from kMarkerAllowlist');
      expect(_iconMarker(byPath[e.key]!), isTrue, reason: '${e.key} no longer uses an icon marker: remove it from kMarkerAllowlist');
      expect(e.value.trim(), isNotEmpty);
    }
  });

  test('the rules catch what they are meant to', () {
    expect(_hardCodesColour("final c = Color(0xFF1E6FFF);"), isTrue);
    expect(_hardCodesColour('Paint()..color = Colors.black.withValues(alpha: .3)'), isTrue);
    expect(_hardCodesColour('Color.fromARGB(255, 1, 2, 3)'), isTrue);
    expect(_hardCodesColour('color: Colors.transparent, c: MeshSonarColors.of(context)'), isFalse);
    expect(_iconMarker('Icon(Icons.cell_tower)'), isTrue);
    expect(_iconMarker('Icon(Icons.cell_tower); NodeSymbol(role: "repeater")'), isFalse);
    expect(_iconMarker('AppSymbolIcon(AppSymbols.antenna)'), isTrue);
  });
}
