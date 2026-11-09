// Shared fixtures for the V3 native network screens: bodies shaped like the website's real answers
// (region-observer, region-packet).
const kHashA = '73af46d9fd880617';

Map<String, dynamic> observerBody({bool withHealth = false}) {
  final base = 1762084800000; // 2026-11-02T12:00Z
  List<String> hours(int n) => [for (var i = n; i > 0; i--) DateTime.fromMillisecondsSinceEpoch(base - i * 3600000, isUtc: true).toIso8601String()];
  final h = hours(6);
  return {
    'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-11-02T11:59:00Z', 'source': 'MeshSonar observers'},
    'row': {
      'key': 'ab' * 32,
      'name': 'Hilltop Obs',
      'online': true,
      'lastPacketAt': '2026-11-02T11:59:30Z',
      'lastStatusAt': '2026-11-02T11:55:00Z',
      'packetsPerHour': 1234,
      'noiseFloorDbm': -104.5,
      'radio': '910.525/62.5/7/5',
      'firmware': 'v1.9.0',
      'model': 'Heltec V3',
      'batteryMv': 4012,
      'lat': 40.1,
      'lon': -83.1,
      'nodesHeard24h': 42,
      'trusted': true,
      'source': 'meshsonar',
      if (withHealth)
        'health': {
          'state': 'deaf',
          'reason': 'peers-advanced',
          'lastStatusAt': '2026-11-02T11:55:00Z',
          'flatSince': '2026-11-02T09:00:00Z',
          'flatSinceExact': true,
          'flatMinutes': 175,
          'battery': {'mv': 3400, 'low': true, 'trend': 'falling', 'slopeMvPerH': -12},
        },
    },
    'noiseFloor': [for (final (i, a) in h.indexed) {'at': a, 'dbm': i == 3 ? null : -105.0 + i}],
    'airtime': [for (final a in h) {'at': a, 'txPct': 1.5, 'rxPct': 7.25}],
    'battery': [for (final a in h) {'at': a, 'mv': 4000}],
    'packetsPerHour': [for (final (i, a) in h.indexed) {'at': a, 'n': 1000 + i * 10}],
    'packetTypes': [
      {'type': 4, 'n': 700},
      {'type': 5, 'n': 300},
    ],
    'topNodes': [
      {'key': 'b2' * 32, 'name': 'Bravo', 'packets': 321, 'bestSnrDb': 9.5},
      {'key': 'c3' * 32, 'name': null, 'packets': 12, 'bestSnrDb': null},
    ],
  };
}

Map<String, dynamic> packetBody() => {
      'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-11-02T11:59:00Z', 'source': 'MeshSonar observers'},
      'row': {'hash': kHashA, 'type': 4, 'route': 1, 'firstAt': '2026-11-02T11:58:01Z', 'observers': 2, 'minHops': 1, 'bestSnrDb': 6.5, 'originKey': 'a1' * 32, 'originName': 'Alpha'},
      'observations': [
        {'observer': 'ob1${'0' * 61}', 'observerName': 'Obs One', 'at': '2026-11-02T11:58:03Z', 'snrDb': 6.5, 'rssiDbm': -90, 'hops': 2, 'path': ['b2', 'c3']},
        {'observer': 'ob2${'0' * 61}', 'observerName': null, 'at': '2026-11-02T11:58:04Z', 'snrDb': null, 'rssiDbm': null, 'hops': 1, 'path': ['b2'], 'via': {'id': 7, 'name': 'Outside Feed'}},
      ],
      'tree': {
        'hop': 'a1',
        'key': 'a1' * 32,
        'name': 'Alpha',
        'lat': 40.0,
        'lon': -83.0,
        'ambiguous': false,
        'confidence': 'high',
        'observers': [],
        'children': [
          {'hop': 'b2', 'key': 'b2' * 32, 'name': 'Bravo', 'lat': null, 'lon': null, 'ambiguous': false, 'observers': ['ob2'], 'children': []},
          {'hop': 'c3', 'key': null, 'name': null, 'lat': null, 'lon': null, 'ambiguous': true, 'observers': [], 'children': []},
        ],
      },
    };
