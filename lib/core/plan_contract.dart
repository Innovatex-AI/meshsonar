// The wire contract of the Master Planner endpoints (release 0.38), typed. Request and response shapes follow
// meshsonar-infra docs/planning/plan-tab-master-planner-2026-11-15.md section 4.4 as corrected by
// build-0.38-final-plan-2026-11-15.md section 5.4:
//   POST <base>/api/cmh/plan-link     PlanLinkRequest    -> PlanLinkResult     (score-link stays unchanged beside it)
//   POST <base>/api/cmh/plan-verify   PlanVerifyRequest  -> PlanVerifyResult   (the coverage run + what it adds)
//   POST <base>/api/cmh/plan-suggest  PlanSuggestRequest -> PlanSuggestResult  (Find sites, stage 1)
// The region is the server's (its Host); no request carries a `region` field. Every response carries [PlanProvenance]
// (`model`, `terrain`, `asOf`, `confidence`). Only coordinates and settings leave the phone: never the drive position, a
// name or any identifier of the person. A wizard's approximate point is rounded to about 1 km here, at the seam, so no
// caller can send it more precisely.
//
// Parsing is tolerant (a missing or odd field takes its default) because servers roll out field by field; a response
// without the fields that make it usable throws [FormatException] (the client turns that into a CmatException).
// Pure Dart: no Flutter imports.

/// A point on the map, degrees.
class PlanPoint {
  final double lat, lon;
  const PlanPoint(this.lat, this.lon);

  /// Rounded to 5 places (about a metre) on the wire.
  Map<String, dynamic> toJson() => {'lat': _r(lat, 5), 'lon': _r(lon, 5)};

  /// Rounded to 2 places (about 1 km): the approximate point of the Find sites wizard (privacy rule, plan section 4.4).
  Map<String, dynamic> toApproximateJson() => {'lat': _r(lat, 2), 'lon': _r(lon, 2)};

  static PlanPoint? tryParse(Object? v) {
    if (v is! Map) return null;
    final la = _n(v['lat']), lo = _n(v['lon']);
    return la == null || lo == null ? null : PlanPoint(la, lo);
  }

  @override
  bool operator ==(Object other) => other is PlanPoint && other.lat == lat && other.lon == lon;
  @override
  int get hashCode => Object.hash(lat, lon);
  @override
  String toString() => 'PlanPoint($lat, $lon)';
}

/// The LoRa settings a plan is computed for (never hard-coded: the default comes from the region's radio preset).
class PlanRadio {
  final double freqMHz, bwKHz;
  final int sf, cr;
  const PlanRadio({required this.freqMHz, required this.bwKHz, required this.sf, required this.cr});

  /// The US MeshCore default (910.525 MHz, 62.5 kHz, SF7, CR5), used only when the region has no preset.
  static const usDefault = PlanRadio(freqMHz: 910.525, bwKHz: 62.5, sf: 7, cr: 5);

  Map<String, dynamic> toJson() => {'freqMHz': freqMHz, 'bwKHz': bwKHz, 'sf': sf, 'cr': cr};

  static PlanRadio? tryParse(Object? v) {
    if (v is! Map) return null;
    final f = _n(v['freqMHz']), b = _n(v['bwKHz']), s = _i(v['sf']), c = _i(v['cr']);
    return f == null || b == null || s == null || c == null ? null : PlanRadio(freqMHz: f, bwKHz: b, sf: s, cr: c);
  }

  @override
  bool operator ==(Object other) => other is PlanRadio && other.freqMHz == freqMHz && other.bwKHz == bwKHz && other.sf == sf && other.cr == cr;
  @override
  int get hashCode => Object.hash(freqMHz, bwKHz, sf, cr);
}

/// Tree and clutter loss, an estimate the person can change (labelled as one in the UI).
class PlanClutter {
  final double canopyM, dbPerKm;
  const PlanClutter({this.canopyM = 15, this.dbPerKm = 13.3});
  Map<String, dynamic> toJson() => {'canopyM': canopyM, 'dbPerKm': dbPerKm};
  static PlanClutter? tryParse(Object? v) => v is Map ? PlanClutter(canopyM: _n(v['canopyM']) ?? 15, dbPerKm: _n(v['dbPerKm']) ?? 13.3) : null;
}

/// Which way a link is judged: A to B (downlink, the repeater to the person), B to A (uplink) or both (the weaker one).
enum PlanDirection {
  down('down'),
  up('up'),
  both('both');

  final String wire;
  const PlanDirection(this.wire);
  static PlanDirection parse(Object? v) => values.firstWhere((d) => d.wire == v, orElse: () => PlanDirection.both);
}

/// How a site is mounted: on a pole at ground level, at treetop, or on a building (the candidate pool's heights).
enum PlanMount {
  ground('ground'),
  tree('tree'),
  building('building');

  final String wire;
  const PlanMount(this.wire);
  static PlanMount? tryParse(Object? v) => values.where((m) => m.wire == v).firstOrNull;
}

/// The three-state verdict every link and site shows.
enum PlanVerdict {
  likely('likely'),
  marginal('marginal'),
  unlikely('unlikely');

  final String wire;
  const PlanVerdict(this.wire);
  static PlanVerdict? tryParse(Object? v) => values.where((x) => x.wire == v).firstOrNull;
}

/// How much a number can be trusted: `measured` (our drives/observers say so), `calibrated` (the model, calibrated on
/// nearby measured data) or `estimate` (the model alone, unobserved here).
enum PlanConfidenceLevel {
  measured('measured'),
  calibrated('calibrated'),
  estimate('estimate');

  final String wire;
  const PlanConfidenceLevel(this.wire);
  static PlanConfidenceLevel parse(Object? v) => values.firstWhere((x) => x.wire == v, orElse: () => PlanConfidenceLevel.estimate);
}

/// What every planner response says about itself: which model, which terrain, how fresh and how sure.
class PlanProvenance {
  /// Model name and version, e.g. `profile+bullington+clutter v1`.
  final String model;

  /// Terrain source, e.g. `AWS Terrain Tiles (bare earth)`.
  final String terrain;

  /// When the data behind the answer was last refreshed (null when the server did not say).
  final DateTime? asOf;
  final PlanConfidenceLevel confidence;

  /// The plain-words reason for [confidence], e.g. "412 drive cells within 2 km" or "calibrated on Columbus".
  final String? confidenceNote;
  const PlanProvenance({
    this.model = 'estimate',
    this.terrain = 'terrain tiles',
    this.asOf,
    this.confidence = PlanConfidenceLevel.estimate,
    this.confidenceNote,
  });

  /// Reads `model`, `terrain`, `asOf` and `confidence` from a response. `model` and `terrain` may be strings or objects
  /// with `name`/`source`; `confidence` may be a string or `{level, note}`.
  static PlanProvenance of(Map<String, dynamic> j) {
    final m = j['model'], t = j['terrain'], c = j['confidence'];
    final model = m is String ? m : (m is Map ? _s(m['name']) ?? _s(m['note']) : null);
    final terrain = t is String ? t : (t is Map ? _s(t['source']) ?? _s(t['name']) : null);
    return PlanProvenance(
      model: model ?? 'estimate',
      terrain: terrain ?? 'terrain tiles',
      asOf: _t(j['asOf']),
      confidence: PlanConfidenceLevel.parse(c is Map ? c['level'] : c),
      confidenceNote: c is Map ? _s(c['note']) : null,
    );
  }
}

// ======================================================================================================== plan-link

class PlanLinkRequest {
  final PlanPoint a, b;

  /// Antenna heights above ground at A and B, metres.
  final double haM, hbM;
  final PlanRadio radio;
  final PlanClutter clutter;
  final PlanDirection direction;

  /// Public keys of A and B when they are known network nodes, so the server can attach measured evidence for the pair.
  /// Repeater keys are public data; never the person's own radio unless they picked it as an end.
  final String? aKey, bKey;
  const PlanLinkRequest({
    required this.a,
    required this.b,
    this.haM = 6,
    this.hbM = 6,
    this.radio = PlanRadio.usDefault,
    this.clutter = const PlanClutter(),
    this.direction = PlanDirection.both,
    this.aKey,
    this.bKey,
  });

  Map<String, dynamic> toJson() => {
        'a': a.toJson(),
        'b': b.toJson(),
        'haM': haM,
        'hbM': hbM,
        'radio': radio.toJson(),
        'clutter': clutter.toJson(),
        'direction': direction.wire,
        'aKey': ?aKey,
        'bKey': ?bKey,
      };
}

/// The terrain profile between A and B: ground elevation (m above sea level) at evenly spaced points and each point's
/// distance from A (km). Same shape as score-link's `profile`.
class PlanProfile {
  final List<double> distanceKm, groundM;
  const PlanProfile({required this.distanceKm, required this.groundM});
  static PlanProfile parse(Object? v) {
    final p = v is Map ? v : const {};
    final d = _ds(p['distanceKm']), g = _ds(p['groundM']);
    if (d.length < 2 || d.length != g.length) throw const FormatException('plan-link profile');
    return PlanProfile(distanceKm: d, groundM: g);
  }
}

/// The point where the first Fresnel zone is most obstructed and how much higher the lower end must go to clear it.
class PlanTightestPoint {
  final double km;
  final double raiseM;
  const PlanTightestPoint({required this.km, required this.raiseM});
}

/// The terrain ridge that blocks the line of sight, when one does.
class PlanRidge {
  final double km;
  final PlanPoint? at;
  final double? groundM;
  const PlanRidge({required this.km, this.at, this.groundM});
}

/// What our own data says about a pair of known nodes (`region_link`, hop pairs, neighbour reports).
class PlanMeasured {
  final int echoes;
  final double? meanSnr;
  final DateTime? lastAt;

  /// Where the evidence comes from, in plain words (e.g. `neighbor reports`, `drives`).
  final String source;
  const PlanMeasured({required this.echoes, this.meanSnr, this.lastAt, required this.source});
  static PlanMeasured? tryParse(Object? v) {
    if (v is! Map) return null;
    return PlanMeasured(echoes: _i(v['echoes']) ?? 0, meanSnr: _n(v['meanSnr']), lastAt: _t(v['lastAt']), source: _s(v['source']) ?? 'measured');
  }
}

class PlanLinkResult {
  final double km;
  final PlanProfile profile;

  /// Smallest clearance of the first Fresnel zone along the path, percent (100 = fully clear, negative = blocked).
  final double? fresnelClearancePct;
  final PlanTightestPoint? tightest;
  final PlanRidge? ridge;

  /// Terrain odds 0..1 that the link works.
  final double? odds;
  final PlanVerdict? verdict;

  /// Link margin above the receiver's sensitivity (after the 10 dB fade margin), dB.
  final double? marginDb;
  final PlanMeasured? measured;
  final PlanProvenance provenance;
  final bool cached;
  const PlanLinkResult({
    required this.km,
    required this.profile,
    this.fresnelClearancePct,
    this.tightest,
    this.ridge,
    this.odds,
    this.verdict,
    this.marginDb,
    this.measured,
    this.provenance = const PlanProvenance(),
    this.cached = false,
  });

  static PlanLinkResult parse(Map<String, dynamic> j) {
    final profile = PlanProfile.parse(j['profile']);
    final t = _m(j['tightest']), r = j['ridge'];
    return PlanLinkResult(
      km: _n(j['km']) ?? profile.distanceKm.last,
      profile: profile,
      fresnelClearancePct: _n(j['fresnelClearancePct']),
      tightest: _n(t['km']) == null ? null : PlanTightestPoint(km: _n(t['km'])!, raiseM: _n(t['raiseM']) ?? 0),
      ridge: r is Map && _n(r['km']) != null ? PlanRidge(km: _n(r['km'])!, at: PlanPoint.tryParse(r), groundM: _n(r['groundM'])) : null,
      odds: _n(j['odds']),
      verdict: PlanVerdict.tryParse(j['verdict']),
      marginDb: _n(j['marginDb']),
      measured: PlanMeasured.tryParse(j['measured']),
      provenance: PlanProvenance.of(j),
      cached: j['cached'] == true,
    );
  }
}

// ======================================================================================================== plan-verify

class PlanVerifyRequest {
  final PlanPoint site;
  final PlanRadio radio;

  /// Antenna height above ground, metres.
  final double antennaM;
  final double txDbm, gainDbi;
  final PlanClutter clutter;

  /// The receiver the footprint is drawn for (`handheld`, `mobile`, `rooftop`) and its height above ground, metres.
  final String receiver;
  final double? receiverM;
  final PlanMount? mount;
  final PlanDirection direction;
  const PlanVerifyRequest({
    required this.site,
    this.radio = PlanRadio.usDefault,
    this.antennaM = 10,
    this.txDbm = 22,
    this.gainDbi = 3,
    this.clutter = const PlanClutter(),
    this.receiver = 'handheld',
    this.receiverM,
    this.mount,
    this.direction = PlanDirection.both,
  });

  Map<String, dynamic> toJson() => {
        'site': site.toJson(),
        'radio': radio.toJson(),
        'antennaM': antennaM,
        'txDbm': txDbm,
        'gainDbi': gainDbi,
        'clutter': clutter.toJson(),
        'receiver': receiver,
        'receiverM': ?receiverM,
        'mount': ?mount?.wire,
        'direction': direction.wire,
      };
}

/// Area of one signal band of a footprint.
class PlanBandArea {
  final String id, label;
  final double areaKm2;
  const PlanBandArea(this.id, this.label, this.areaKm2);
}

/// A network node the planned site is predicted to reach.
class PlanPredictedLink {
  final String publicKey, name;
  final double km, marginDb;
  const PlanPredictedLink({required this.publicKey, required this.name, required this.km, required this.marginDb});
}

class PlanVerifyResult {
  final double coveredKm2;
  final List<PlanBandArea> bands;
  final List<PlanPredictedLink> links;

  /// What the site adds to today's measured + modelled coverage.
  final double? newAreaKm2;
  final int? newPeople;
  final PlanProvenance provenance;
  final bool cached;

  /// The whole answer (the coverage run's `footprint` GeoJSON, `sweep`, `population`...), for the footprint layer.
  final Map<String, dynamic> raw;
  const PlanVerifyResult({
    required this.coveredKm2,
    this.bands = const [],
    this.links = const [],
    this.newAreaKm2,
    this.newPeople,
    this.provenance = const PlanProvenance(),
    this.cached = false,
    this.raw = const {},
  });

  static PlanVerifyResult parse(Map<String, dynamic> j) {
    if (j['coveredKm2'] is! num && j['bands'] is! List) throw const FormatException('plan-verify');
    return PlanVerifyResult(
      coveredKm2: _n(j['coveredKm2']) ?? 0,
      bands: [for (final b in _ms(j['bands'])) PlanBandArea(_s(b['id']) ?? '', _s(b['label']) ?? '', _n(b['areaKm2']) ?? 0)],
      links: [
        for (final l in _ms(j['links']))
          PlanPredictedLink(publicKey: _s(l['publicKey']) ?? '', name: _s(l['name']) ?? 'Repeater', km: _n(l['km']) ?? 0, marginDb: _n(l['marginDb']) ?? 0),
      ],
      newAreaKm2: _n(j['newAreaKm2']),
      newPeople: _i(j['newPeople']),
      provenance: PlanProvenance.of(j),
      cached: j['cached'] == true,
      raw: j,
    );
  }
}

// ======================================================================================================== plan-suggest

/// The Find sites goal chips (Map Definition `plan.goals`; default Best overall).
enum PlanGoal {
  coverage('coverage'),
  links('links'),
  redundancy('redundancy'),
  overall('overall');

  final String wire;
  const PlanGoal(this.wire);
  static PlanGoal parse(Object? v) => values.firstWhere((g) => g.wire == v, orElse: () => PlanGoal.overall);
}

class PlanBounds {
  final double south, north, west, east;
  const PlanBounds({required this.south, required this.north, required this.west, required this.east});
  Map<String, dynamic> toJson() => {'south': _r(south, 4), 'north': _r(north, 4), 'west': _r(west, 4), 'east': _r(east, 4)};
}

class PlanSuggestRequest {
  final PlanBounds bounds;
  final PlanGoal goal;

  /// At most 20 (the server caps it too).
  final int limit;
  final PlanRadio radio;
  final double antennaM, txDbm, gainDbi;
  final PlanClutter clutter;
  final PlanMount? mount;
  final double? receiverM;

  /// The wizard's "my approximate location", sent rounded to about 1 km ([PlanPoint.toApproximateJson]); null = none.
  final PlanPoint? near;
  const PlanSuggestRequest({
    required this.bounds,
    this.goal = PlanGoal.overall,
    this.limit = 10,
    this.radio = PlanRadio.usDefault,
    this.antennaM = 10,
    this.txDbm = 22,
    this.gainDbi = 3,
    this.clutter = const PlanClutter(),
    this.mount,
    this.receiverM,
    this.near,
  });

  static const int maxLimit = 20;

  Map<String, dynamic> toJson() => {
        'bounds': bounds.toJson(),
        'goal': goal.wire,
        'limit': limit.clamp(1, maxLimit),
        'radio': radio.toJson(),
        'antennaM': antennaM,
        'txDbm': txDbm,
        'gainDbi': gainDbi,
        'clutter': clutter.toJson(),
        'mount': ?mount?.wire,
        'receiverM': ?receiverM,
        if (near != null) 'near': near!.toApproximateJson(),
      };
}

/// An existing repeater a suggested site would link to.
class PlanSiteLink {
  final String key, name;
  final double km;
  final double? odds;
  final String? tier;
  const PlanSiteLink({required this.key, required this.name, required this.km, this.odds, this.tier});
}

/// How a suggested site changes the mesh's redundancy (from E8).
enum PlanRedundancyGain {
  none('none'),
  secondPath('second_path'),
  joinsComponents('joins_components'),
  removesSpof('removes_spof');

  final String wire;
  const PlanRedundancyGain(this.wire);
  static PlanRedundancyGain parse(Object? v) => values.firstWhere((x) => x.wire == v, orElse: () => PlanRedundancyGain.none);
}

class PlanSiteGain {
  final double? newAreaKm2;
  final int? newPeople;
  final List<PlanSiteLink> newLinks;
  final PlanRedundancyGain redundancy;

  /// The single point of failure this site removes, when [redundancy] is [PlanRedundancyGain.removesSpof].
  final String? spofName;
  const PlanSiteGain({this.newAreaKm2, this.newPeople, this.newLinks = const [], this.redundancy = PlanRedundancyGain.none, this.spofName});
}

class PlanSite {
  final String id;
  final PlanPoint at;
  final double? groundM, heightAboveM;

  /// `terrain`, `pole`, `tower`, `building`, `tree` (the candidate's source).
  final String kind;
  final PlanMount? mount;
  final String? osmId, osmOperator;

  /// 0-100 for the goal asked.
  final double score;

  /// Plain words: why this site.
  final String reason;
  final PlanSiteGain gain;

  /// Drives that went through dead zones this site would cover.
  final int deadZoneDrives;
  const PlanSite({
    required this.id,
    required this.at,
    this.groundM,
    this.heightAboveM,
    this.kind = 'terrain',
    this.mount,
    this.osmId,
    this.osmOperator,
    required this.score,
    this.reason = '',
    this.gain = const PlanSiteGain(),
    this.deadZoneDrives = 0,
  });

  static PlanSite? tryParse(Map<String, dynamic> j) {
    final at = PlanPoint.tryParse(j);
    final id = _s(j['id']) ?? (j['id'] is num ? '${j['id']}' : null);
    if (at == null || id == null) return null;
    final osm = _m(j['osm']), g = _m(j['gain']);
    return PlanSite(
      id: id,
      at: at,
      groundM: _n(j['groundM']),
      heightAboveM: _n(j['heightAboveM']),
      kind: _s(j['kind']) ?? 'terrain',
      mount: PlanMount.tryParse(j['mount']),
      osmId: _s(osm['id']) ?? (osm['id'] is num ? '${osm['id']}' : null),
      osmOperator: _s(osm['operator']),
      score: (_n(j['score']) ?? 0).clamp(0, 100).toDouble(),
      reason: _s(j['reason']) ?? '',
      gain: PlanSiteGain(
        newAreaKm2: _n(g['newAreaKm2']),
        newPeople: _i(g['newPeople']),
        newLinks: [
          for (final l in _ms(g['newLinks']))
            if (_s(l['key']) != null)
              PlanSiteLink(key: _s(l['key'])!, name: _s(l['name']) ?? 'Repeater', km: _n(l['km']) ?? 0, odds: _n(l['odds']), tier: _s(l['tier'])),
        ],
        redundancy: PlanRedundancyGain.parse(g['redundancy']),
        spofName: _s(g['spofName']),
      ),
      deadZoneDrives: _i(_m(j['evidence'])['deadZoneDrives']) ?? 0,
    );
  }
}

class PlanSuggestResult {
  /// How many candidates the region's table holds.
  final int pool;
  final List<PlanSite> sites;
  final List<String> notes;

  /// The region's candidate table is being built (first request in a region): try again shortly.
  final bool preparing;
  final PlanProvenance provenance;
  final bool cached;
  const PlanSuggestResult({
    this.pool = 0,
    this.sites = const [],
    this.notes = const [],
    this.preparing = false,
    this.provenance = const PlanProvenance(),
    this.cached = false,
  });

  static PlanSuggestResult parse(Map<String, dynamic> j) {
    if (j['sites'] is! List && j['preparing'] != true) throw const FormatException('plan-suggest');
    return PlanSuggestResult(
      pool: _i(j['pool']) ?? 0,
      sites: [for (final s in _ms(j['sites'])) ?PlanSite.tryParse(s)],
      notes: [for (final n in (j['notes'] is List ? j['notes'] as List : const [])) if (n is String && n.isNotEmpty) n],
      preparing: j['preparing'] == true,
      provenance: PlanProvenance.of(j),
      cached: j['cached'] == true,
    );
  }
}

// ======================================================================================================== helpers
double _r(double v, int places) => double.parse(v.toStringAsFixed(places));
double? _n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _i(Object? v) => v is num && v.isFinite ? v.round() : null;
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
Map<String, dynamic> _m(Object? v) => v is Map<String, dynamic> ? v : const {};
List<Map<String, dynamic>> _ms(Object? v) => v is List ? [for (final e in v) if (e is Map<String, dynamic>) e] : const [];
List<double> _ds(Object? v) => v is List ? [for (final e in v) if (e is num && e.isFinite) e.toDouble()] : const [];
