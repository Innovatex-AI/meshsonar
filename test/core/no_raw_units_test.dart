// Units migration (spec app-website-parity D.2): every distance, speed, height, temperature and pressure the person
// sees goes through lib/core/units.dart so Settings > Units (Auto/Metric/Imperial, plus the per-quantity choices)
// changes it. No code in lib/ui or lib/app may glue a raw unit onto a number inside a string: `'${x} m'`, `'$n km'`,
// `'... mph'`, `'... ft'`, `'... mi'`, `'$t °C'`, `'$p hPa'`; and no code outside units.dart may convert units itself
// (miles, feet, mph, °F, inHg, mmHg factors).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lines (substrings) allowed to carry a raw unit, with the reason.
const List<String> allowedLines = [
  // Metric branch of the unit-aware antenna help text (the imperial branch sits beside it).
  'Roughly: about 1 m in a hand',
  'Enter 0 to 300 metres',
  'about 3 ft in a hand',
  // Metric branch of the range-ring switch label (the imperial text sits beside it).
  '1 km and 2 km around you',
  // Time ("5m ago"), not distance.
  'm ago',
  r'~/ 60}m',
  r'~ 60}m',
  // The fixed ~220 m size of a grid cell, a fact about the map grid rather than a measurement.
  '(≈220 m, the same grid',
  // The fixed ~5 km size of the weather grid cell (0.05 degrees) the server looks up, a fact about the source.
  'about 5 km',
  'a 5 km cell',
  'Server address moved',
  // The Plan tools' antenna heights are feet on the wire (the website's score-link/coverage take feet and metres) and in the
  // sliders; the factor is Units' own constant, shown to the person only through Units.height.
  "import '../units.dart' show metresPerFoot;",
  'const double ftM = metresPerFoot;',
];

final _raw = RegExp(r'(\}|\$\w+|\d) ?(km/h|kph|km|mph|mi|ft|m|hPa|mbar|inHg|mmHg|°C|°F|° ?C|° ?F)(?![\w:])');

/// Unit conversion done by hand: the constants and factors that belong to lib/core/units.dart only.
final _conversion = RegExp(r'metresPerMile|metresPerFoot|mphPerMps|kmhPerMps|inHgPerHpa|mmHgPerHpa|\b1609(\.\d+)?\b|'
    r'\b0\.3048\b|\b3\.28\d*\b|\b2\.236\d*\b|\b0\.6213\d*\b|\* ?3\.6\b|/ ?3\.6\b|\b9 ?/ ?5\b|\b5 ?/ ?9\b|\b33\.86\d*\b|'
    r'\b0\.02953\d*\b|\b1\.3332\d*\b|\b0\.75006\d*\b');

void main() {
  test('no raw distance/speed/height units outside lib/core/units.dart', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) continue;
      if (!path.startsWith('lib/ui/') && !path.startsWith('lib/app/')) continue;
      for (final line in f.readAsLinesSync()) {
        final t = line.trim();
        if (t.startsWith('//')) continue;
        if (!t.contains("'") && !t.contains('"')) continue;
        final code = t.replaceFirst(RegExp(r'\s//.*$'), '');
        if (_raw.hasMatch(code) && !allowedLines.any(code.contains)) hits.add('$path: $t');
      }
    }
    expect(hits, isEmpty, reason: 'format via Units (lib/core/units.dart) instead:\n${hits.join('\n')}');
  });

  test('no unit conversion outside lib/core/units.dart', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path == 'lib/core/units.dart') continue;
      for (final line in f.readAsLinesSync()) {
        final t = line.trim();
        if (t.startsWith('//')) continue;
        final code = t.replaceFirst(RegExp(r'\s//.*$'), '');
        if (_conversion.hasMatch(code) && !allowedLines.any(code.contains)) hits.add('$path: $t');
      }
    }
    expect(hits, isEmpty, reason: 'convert via Units (lib/core/units.dart) instead:\n${hits.join('\n')}');
  });

  test('the patterns catch what they are meant to', () {
    for (final bad in [r"'${t.round()} °C'", r"'$p hPa'", r"'${x} mph'", r"'12 km'", r"'${v} inHg'", r"'$f °F'"]) {
      expect(_raw.hasMatch(bad), isTrue, reason: bad);
    }
    for (final ok in [r"'5m ago'", r"'${u.speed(v)}'", r"'Celsius (°C)'", r"'km and m'"]) {
      expect(_raw.hasMatch(ok) && !allowedLines.any(ok.contains), isFalse, reason: ok);
    }
    for (final bad in ['m / 1609.344', 'v * 3.6', 'c * 9 / 5 + 32', 'h * 3.28084', 'x * metresPerFoot']) {
      expect(_conversion.hasMatch(bad), isTrue, reason: bad);
    }
    expect(_conversion.hasMatch('zoom 13.6'), isFalse);
  });
}
