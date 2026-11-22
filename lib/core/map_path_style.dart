// THE path style (Map Definition v2 `symbols.path`, plan unified-map-engine section 4.3; the website's src/lib/map/path-style.ts):
// one numbered, named route on every map that shows one (a packet's route, a trace, the Path Inspector, Discover, a chat message's
// path). The numbers in the definition are the only place a path's colour, width or dash is written. Reads null when the
// definition has no `symbols.path` block (the bundled copy, a version 1 answer), which leaves every caller on what build 73
// drew. Pure Dart: no Flutter imports.
import 'map_definition.dart';

/// A hop's position is known for certain (a unique match) or only likely. A hop with no position is not drawn at all.
enum PathCertainty { certain, likely }

/// The colours of one theme, ARGB ints.
class PathColours {
  final int line, disc, number, halo;
  const PathColours({required this.line, required this.disc, required this.number, required this.halo});
}

class MapPathStyle {
  final int v;

  /// `certainty[].line` by id: `solid` or `dashed` (certain is solid and likely dashed in the live definition).
  final Map<PathCertainty, String> lineOf;

  /// `certainty[].label` by id (the legend wording).
  final Map<PathCertainty, String> certaintyLabel;
  final PathColours light, dark;
  final double widthPx;

  /// Dash and gap in multiples of the line width (the site's `line-dasharray` unit).
  final List<double> dash;
  final double discRadiusPx, numberPx;

  /// `{n} · {name}`.
  final String label;
  final String unplacedNote;
  final String observerLabel, observerSymbol;
  const MapPathStyle({
    required this.v,
    required this.lineOf,
    required this.certaintyLabel,
    required this.light,
    required this.dark,
    required this.widthPx,
    required this.dash,
    required this.discRadiusPx,
    required this.numberPx,
    required this.label,
    required this.unplacedNote,
    required this.observerLabel,
    required this.observerSymbol,
  });

  /// The style [def] carries, or null when it has no (usable) `symbols.path`.
  static MapPathStyle? of(MapDefinition def) {
    final sym = def.json['symbols'];
    final p = sym is Map ? sym['path'] : null;
    if (p is! Map) return null;
    try {
      final colours = p['colours'];
      if (colours is! Map) return null;
      PathColours theme(Object? t) {
        if (t is! Map) throw const FormatException('no theme colours');
        int c(String k) => parseHexColour(t[k] as String);
        return PathColours(line: c('line'), disc: c('disc'), number: c('number'), halo: c('halo'));
      }

      final line = <PathCertainty, String>{PathCertainty.certain: 'solid', PathCertainty.likely: 'dashed'};
      final labels = <PathCertainty, String>{};
      if (p['certainty'] is List) {
        for (final e in p['certainty'] as List) {
          if (e is! Map) continue;
          final id = switch (e['id']) {
            'certain' => PathCertainty.certain,
            'likely' => PathCertainty.likely,
            _ => null,
          };
          if (id == null) continue;
          if (e['line'] is String) line[id] = e['line'] as String;
          if (e['label'] is String) labels[id] = e['label'] as String;
        }
      }
      final dash = [for (final d in (p['dash'] as List? ?? const [2, 2])) if (d is num) d.toDouble()];
      final obs = p['observer'] is Map ? p['observer'] as Map : const {};
      return MapPathStyle(
        v: (p['v'] as num?)?.toInt() ?? 1,
        lineOf: line,
        certaintyLabel: labels,
        light: theme(colours['light']),
        dark: theme(colours['dark']),
        widthPx: (p['widthPx'] as num?)?.toDouble() ?? 3.5,
        dash: dash.length >= 2 ? dash : const [2, 2],
        discRadiusPx: (p['discRadiusPx'] as num?)?.toDouble() ?? 9,
        numberPx: (p['numberPx'] as num?)?.toDouble() ?? 11,
        label: p['label'] is String ? p['label'] as String : '{n} · {name}',
        unplacedNote: p['unplacedNote'] is String ? p['unplacedNote'] as String : 'Hops with no known position are listed, never drawn, and the line stops there.',
        observerLabel: obs['label'] is String ? obs['label'] as String : 'Observer that heard it',
        observerSymbol: obs['symbol'] is String ? obs['symbol'] as String : 'observer',
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  PathColours colours({required bool dark}) => dark ? this.dark : light;

  /// True when [c] is drawn dashed.
  bool isDashed(PathCertainty c) => lineOf[c] == 'dashed';

  /// The label of hop [n]: "N · Name" (the name is the node's name, else its hash prefix).
  String labelFor(int n, String name) => label.replaceAll('{n}', '$n').replaceAll('{name}', name);
}
