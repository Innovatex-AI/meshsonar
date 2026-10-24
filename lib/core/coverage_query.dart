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

/// Hexagon resolution for a map zoom, picked so a cell stays roughly 10-40 px across at mid latitudes
/// (res 7 ~1.2 km edge ... res 11 ~25 m edge).
int coverageResForZoom(double zoom) {
  if (zoom < 11.5) return 7;
  if (zoom < 12.5) return 8;
  if (zoom < 14) return 9;
  if (zoom < 15.5) return 10;
  return 11;
}

@immutable
class CoverageQuery {
  /// null = automatic by zoom (the caller resolves it with [coverageResForZoom]); 7..11 = pinned.
  final int? res;
  final CoverageSince since;
  final CoverageSource source;
  const CoverageQuery({
    this.res,
    this.since = CoverageSince.all,
    this.source = CoverageSource.all,
  });

  CoverageQuery copyWith({
    int? res,
    bool autoRes = false,
    CoverageSince? since,
    CoverageSource? source,
  }) => CoverageQuery(
    res: autoRes ? null : (res ?? this.res),
    since: since ?? this.since,
    source: source ?? this.source,
  );

  @override
  bool operator ==(Object other) =>
      other is CoverageQuery &&
      other.res == res &&
      other.since == since &&
      other.source == source;

  @override
  int get hashCode => Object.hash(res, since, source);
}
