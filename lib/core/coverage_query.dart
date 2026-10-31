// What the network-coverage layer asks the server for (GET /api/cmh/public-coverage?res=&since=&source=), mirroring
// the website's /coverage layer panel (meshcore-insights coverage-layer-panel.tsx). Pure Dart.
import 'package:flutter/foundation.dart' show immutable;

/// The "since" chips: only cells measured inside the window. [all] sends no `since`.
enum CoverageSince {
  hour('1 h', Duration(hours: 1)),
  day('24 h', Duration(hours: 24)),
  week('7 d', Duration(days: 7)),
  all('All', null);

  final String label;
  final Duration? window;
  const CoverageSince(this.label, this.window);
}

/// The `source` filter: MeshSonar drives, MeshMapper forwards, or both merged (the server default).
enum CoverageSource {
  all('All', 'all'),
  meshsonar('MeshSonar', 'meshsonar'),
  meshmapper('MeshMapper', 'meshmapper');

  final String label;
  final String wire;
  const CoverageSource(this.label, this.wire);
}

/// H3 resolutions the server serves.
const int coverageMinRes = 7;
const int coverageMaxRes = 11;

/// The zoom -> H3 resolution table, one place for every hexagon the map draws (the network coverage layer AND the live
/// drive's own cells). Each row is (first zoom of the band, resolution). A cell is about 2 x edge wide: res 7 1.2 km edge,
/// 8 461 m, 9 174 m, 10 66 m, 11 25 m. At mid latitudes this keeps a cell between roughly 17 and 60 px across over the
/// whole zoom range (a band is entered at its smallest and left at its biggest), never sub-pixel and never a blob.
const List<(double fromZoom, int res)> kCoverageResBands = [
  (0, 7),
  (11.5, 8),
  (12.5, 9),
  (14, 10),
  (15.5, 11),
];

/// Hexagon resolution for a map zoom (see [kCoverageResBands]); zoom is clamped, NaN gives the middle band.
int coverageResForZoom(double zoom) {
  if (zoom.isNaN) return 9;
  var res = kCoverageResBands.first.$2;
  for (final b in kCoverageResBands) {
    if (zoom >= b.$1) res = b.$2;
  }
  return res;
}

@immutable
class CoverageQuery {
  /// null = automatic by zoom (the caller resolves it with [coverageResForZoom]); 7..11 = pinned.
  final int? res;
  final CoverageSince since;
  final CoverageSource source;

  /// Timeline "as of": only pings measured before this instant (exclusive). null = live (no bound).
  final DateTime? until;
  const CoverageQuery({
    this.res,
    this.since = CoverageSince.all,
    this.source = CoverageSource.all,
    this.until,
  });

  CoverageQuery copyWith({
    int? res,
    bool autoRes = false,
    CoverageSince? since,
    CoverageSource? source,
    DateTime? until,
    bool clearUntil = false,
  }) => CoverageQuery(
    res: autoRes ? null : (res ?? this.res),
    since: since ?? this.since,
    source: source ?? this.source,
    until: clearUntil ? null : (until ?? this.until),
  );

  @override
  bool operator ==(Object other) =>
      other is CoverageQuery &&
      other.res == res &&
      other.since == since &&
      other.source == source &&
      other.until == until;

  @override
  int get hashCode => Object.hash(res, since, source, until);
}
