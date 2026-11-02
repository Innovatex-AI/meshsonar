// Shared fixtures for the V3 native network screens: bodies shaped like the website's real answers
// (tool-routes recent / trace / aggregate, region-observer, region-packet, region-findings).
const kHashA = '73af46d9fd880617';

Map<String, dynamic> recentBody({bool unavailable = false}) => unavailable
    ? {'packets': [], 'since': null, 'fetchedAt': '2026-11-02T12:00:00Z', 'cached': false, 'source': '', 'unavailable': true}
    : {
        'packets': [
          {'hash': kHashA, 'firstSeen': '2026-11-02T11:58:01Z', 'payloadType': 'ADVERT', 'routeType': 1, 'hops': 3, 'observers': 4, 'observations': 6, 'firstRelay': 'aa', 'firstRelayName': 'Hilltop', 'originName': 'Alpha'},
          {'hash': '0123456789abcdef', 'firstSeen': '2026-11-02T11:50:00Z', 'payloadType': 'GRP_TXT', 'routeType': 1, 'hops': 1, 'observers': 1, 'observations': 1, 'firstRelay': null, 'firstRelayName': null, 'originName': null},
        ],
        'since': '2026-11-01T12:00:00Z',
        'fetchedAt': '2026-11-02T12:00:00Z',
        'cached': false,
        'source': 'x',
      };

Map<String, dynamic> traceBody() => {
      'hash': kHashA,
      'via': 'okimesh',
      'packet': {'firstSeen': '2026-11-02T11:58:01Z', 'payloadType': 'ADVERT', 'routeType': 1, 'decoded': null},
      'origin': {'pubkey': 'a1' * 32, 'name': 'Alpha', 'lat': 40.0, 'lon': -83.0, 'kind': 'advert'},
      'observations': [
        {'observerId': 'ob1${'0' * 61}', 'observerName': 'Obs One', 'time': '2026-11-02T11:58:03Z', 'snr': 6.5, 'rssi': -90, 'path': ['b2', 'c3'], 'resolvedPath': null, 'observerLat': 40.1, 'observerLon': -83.1},
        {'observerId': 'ob2${'0' * 61}', 'observerName': null, 'time': '2026-11-02T11:58:04Z', 'snr': null, 'rssi': null, 'path': ['b2'], 'resolvedPath': null, 'observerLat': null, 'observerLon': null},
      ],
      'hops': {},
      'tree': {
        'nodes': [
          {'id': 'a1' * 32, 'pubkey': 'a1' * 32, 'prefix': null, 'name': 'Alpha', 'lat': 40.0, 'lon': -83.0, 'depth': 0, 'kind': 'origin', 'confidence': 'origin', 'firstHeard': null, 'observations': 0},
          {'id': 'b2' * 32, 'pubkey': 'b2' * 32, 'prefix': 'b2', 'name': 'Bravo', 'lat': 40.05, 'lon': -83.05, 'depth': 1, 'kind': 'relay', 'confidence': 'okimesh', 'firstHeard': '2026-11-02T11:58:02Z', 'observations': 2},
          {'id': 'hop:c3', 'pubkey': null, 'prefix': 'c3', 'name': null, 'lat': null, 'lon': null, 'depth': 2, 'kind': 'relay', 'confidence': 'unresolved', 'firstHeard': '2026-11-02T11:58:03Z', 'observations': 1},
          {'id': 'obs:ob1', 'pubkey': null, 'prefix': null, 'name': 'Obs One', 'lat': 40.1, 'lon': -83.1, 'depth': 3, 'kind': 'observer', 'confidence': 'observer', 'firstHeard': '2026-11-02T11:58:03Z', 'observations': 1},
        ],
        'edges': [
          {'from': 'a1' * 32, 'to': 'b2' * 32, 'depth': 1, 'snr': null, 'snrN': 0, 'rssi': null, 'firstHeard': '2026-11-02T11:58:02Z', 'observations': 2, 'km': 7.1, 'toObserver': false},
          {'from': 'b2' * 32, 'to': 'hop:c3', 'depth': 2, 'snr': null, 'snrN': 0, 'rssi': null, 'firstHeard': '2026-11-02T11:58:03Z', 'observations': 1, 'km': null, 'toObserver': false},
          {'from': 'hop:c3', 'to': 'obs:ob1', 'depth': 3, 'snr': 6.5, 'snrN': 1, 'rssi': -90, 'firstHeard': '2026-11-02T11:58:03Z', 'observations': 1, 'km': null, 'toObserver': true},
        ],
        'maxDepth': 3,
        'observationCount': 2,
        'observerCount': 2,
        'maxHops': 2,
      },
      'bytes': {
        'rawHex': '11',
        'fromObserver': 'Obs One',
        'ranges': [
          {'start': 0, 'end': 1, 'label': 'Header', 'hex': '11', 'group': 'header'},
          {'start': 1, 'end': 3, 'label': 'Path (2 hops)', 'hex': 'B2C3', 'group': 'path'},
          {'start': 3, 'end': 10, 'label': 'Advert payload', 'hex': '00112233445566', 'group': 'payload'},
        ],
      },
      'decoded': {'header': {'payloadVersion': 1}},
      'resolution': {'relayHops': 2, 'byConfidence': {}},
      'fetchedAt': '2026-11-02T12:00:00Z',
      'cached': false,
      'source': 'x',
    };

Map<String, dynamic> aggregateBody({int hours = 24, int hashes = 200}) => {
      'hours': hours,
      'since': '2026-11-01T12:00:00Z',
      'truncated': false,
      'upstreamTotals': {},
      'totals': {'hashes': hashes, 'withRelay': 150, 'observations': 900, 'hops': 400, 'unresolvedHops': 200, 'oneByteHops': 180, 'regionPickedHops': 5},
      'carry': [
        {'id': 'b2' * 32, 'hashes': 80, 'share': 0.4, 'hashesWithPicks': 85, 'name': 'Bravo'},
        {'id': 'c3' * 32, 'hashes': 20, 'share': 0.1, 'hashesWithPicks': 20, 'name': null},
        {'id': 'hop:dd', 'hashes': 9, 'share': 0.045, 'hashesWithPicks': 9, 'name': null},
      ],
      'subpaths': [
        {'ids': ['b2' * 32, 'c3' * 32], 'hashes': 30, 'share': 0.15, 'names': ['Bravo', null]},
        {'ids': ['b2' * 32, 'hop:dd'], 'hashes': 10, 'share': 0.05, 'names': ['Bravo', null]},
      ],
      'okimeshSubpaths': {'error': 'skipped'},
      'hopHistogram': [
        {'hops': 0, 'hashes': 50},
        {'hops': 1, 'hashes': 60},
        {'hops': 2, 'hashes': 70},
        {'hops': 13, 'hashes': 20},
      ],
      'ends': [
        {'id': 'b2' * 32, 'hashes': 70, 'name': 'Bravo'},
        {'id': 'hop:dd', 'hashes': 10, 'name': null},
      ],
      'links': [
        {'a': 'b2' * 32, 'b': 'c3' * 32, 'hashes': 25},
      ],
      'pairs': [],
      'locations': {
        'b2' * 32: {'lat': 40.05, 'lon': -83.05},
        'c3' * 32: {'lat': 40.15, 'lon': -83.15},
      },
      'collisions': {
        'stats': {'collision_count': 1},
        'cells': [
          {
            'prefix': 'b2',
            'seenAsOneByteHop': 12,
            'nodes': [
              {'pubkey': 'b2' * 32, 'name': 'Bravo', 'role': 'repeater', 'hashSize': 1, 'lat': 40.05, 'lon': -83.05},
              {'pubkey': 'b2${'ff' * 31}', 'name': null, 'role': null, 'hashSize': null, 'lat': null, 'lon': null},
            ],
          },
        ],
        'inconsistentNodes': 0,
      },
      'fetchedAt': '2026-11-02T12:00:00Z',
      'cached': false,
      'source': 'x',
    };

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

Map<String, dynamic> findingsBody({bool empty = false}) => empty
    ? {'status': {'state': 'pending', 'reason': 'No findings have been written for this region yet.', 'computedAt': null, 'source': 'MeshSonar analysis'}, 'asOf': null, 'insights': [], 'recommendations': [], 'sites': {}}
    : {
        'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-01T00:00:00Z', 'source': 'MeshSonar analysis'},
        'asOf': '2026-10-01T00:00:00Z',
        'insights': [
          {
            'id': 'I1',
            'category': 'Coverage',
            'severity': 'high',
            'headline': 'East side has no repeater',
            'finding': 'No repeater covers the east side.',
            'evidence': [
              {'label': 'People within 3 km', 'value': 12345, 'ref': 'D2'},
              {'label': 'Link odds', 'value': '33%', 'ref': 'link:D2|Oscar'},
            ],
            'implication': 'Drivers lose signal there.',
            'action': 'Add a repeater at D2.',
            'related': {'sites': ['D2'], 'repeaters': ['Oscar']},
          },
          {'id': 'I2', 'category': 'Health', 'severity': 'low', 'headline': 'One quiet repeater', 'finding': 'f', 'evidence': [], 'implication': '', 'action': '', 'related': {'sites': [], 'repeaters': []}},
        ],
        'recommendations': [
          {'id': 'R1', 'title': 'Build D2', 'why': 'Closes the east gap.', 'impact': {'newPeopleWithin3km': 12345, 'sites': 1}, 'actions': ['Ask the library'], 'insights': ['I1'], 'sites': ['D2']},
        ],
        'sites': {'D2': 'Dublin Library'},
      };
