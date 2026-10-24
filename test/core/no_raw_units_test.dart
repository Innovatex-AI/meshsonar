// Units migration (spec app-website-parity D.2): every distance, speed and height the person sees goes through
// lib/core/units.dart so Settings > Units (Auto/Metric/Imperial) changes it. No code in lib/ui or lib/app may glue a
// raw unit onto a number inside a string: `'${x} m'`, `'$n km'`, `'... mph'`, `'... ft'`, `'... mi'`.
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
  'Server address moved',
];

final _raw = RegExp(r'(\}|\$\w+|\d) ?(km/h|km|mph|mi|ft|m)(?![\w])');

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
}
