// The repeater lists through AppState: opening the app syncs the roster and the global list (launch gates), the
// site-config capability `networkRepeatersDelta` reaches the sync (on = `?updated_since=<cursor>`, off or unknown = the
// full list with ETag, as before), and a region switch syncs the right roster.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/network_repeaters.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/repeater_sync.dart';

import '../ui/fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
const sea = RegionIndexEntry(code: 'SEA', slug: 'sea', name: 'Seattle, US', url: 'https://sea.meshsonar.com', bbox: [-122.6, 47.2, -121.9, 47.9]);
const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');

String hexKey(int i) => i.toRadixString(16).padLeft(4, '0') * 16;
final now = DateTime.utc(2026, 10, 24, 19);
int epochS(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

void main() {
  late Directory tmp;
  late List<Uri> seen;
  late List<String> ifNoneMatch;
  Harness? current;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ms_rdw_');
    seen = [];
    ifNoneMatch = [];
  });
  tearDown(() async {
    await current?.state.repeaterSync?.writesDone;
    current = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> rosterBody(String name) => {
    'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T18:00:00Z'},
    'rows': [
      {'key': hexKey(900), 'hashPrefix': '38', 'name': name, 'role': 'repeater', 'lat': 40.1, 'lon': -82.9, 'ambiguous': false, 'status': 'active'},
    ],
    'counts': {'active': 1},
  };

  http.Client server() => MockClient((req) async {
    seen.add(req.url);
    final p = req.url.path;
    if (p.endsWith('/region-repeaters')) return http.Response(jsonEncode(rosterBody(req.url.host)), 200, headers: {'etag': '"r-${req.url.host}"'});
    if (req.url.host == 'meshsonar.com' && p == '/api/cmh/network-repeaters') {
      final since = req.url.queryParameters['updated_since'];
      if (since != null) {
        final rows = [
          [hexKey(2), 'Two (updated)', 40.0, -83.0, 2, 1792850000],
          [hexKey(5), 'Five (new)', 40.5, -83.2, 2, 1792850000],
        ];
        return http.Response(
          jsonEncode({
            'v': 1,
            'asOf': '2026-10-24T18:58:00.000Z',
            'asOfS': epochS(now) - 120,
            'since': int.parse(since),
            'count': rows.length,
            'removedCount': 1,
            'rows': rows,
            'removed': [hexKey(3)],
          }),
          200,
        );
      }
      ifNoneMatch.add(req.headers['if-none-match'] ?? '');
      final rows = [
        [hexKey(1), 'One', 40.0, -83.0, 2, 1792850000],
        [hexKey(2), 'Two', 40.0, -83.0, 2, 1792850000],
        [hexKey(3), 'Three', 40.0, -83.0, 2, 1792850000],
      ];
      if (req.headers['if-none-match'] == '"seeded"') return http.Response('', 304, headers: {'etag': '"seeded"'});
      return http.Response(jsonEncode({'v': 1, 'asOf': '2026-10-24T18:00:00Z', 'count': 3, 'hidden': 0, 'rows': rows}), 200, headers: {'etag': '"seeded"'});
    }
    return http.Response('nope', 404);
  });

  /// A phone with a stored global list (checked 7 h ago, cursor 11:00 UTC) and a site config with [capabilities].
  Future<Harness> make({Set<String>? capabilities, bool seed = true}) async {
    final c = server();
    final h = Harness();
    final store = RepeaterSyncStore(Directory('${tmp.path}/sync'));
    if (seed) {
      final seedList = NetworkRepeaters.parse({
        'v': 1,
        'asOf': '2026-10-24T11:00:00Z',
        'hidden': 0,
        'rows': [
          [hexKey(1), 'One', 40.0, -83.0, 2, 1792850000],
          [hexKey(2), 'Two', 40.0, -83.0, 2, 1792850000],
          [hexKey(3), 'Three', 40.0, -83.0, 2, 1792850000],
        ],
      });
      final at = now.subtract(const Duration(hours: 7));
      await store.saveNetwork(NetworkRecord(data: seedList, etag: '"seeded"', fetchedAt: at, checkedAt: at, cursorS: deltaCursorOf(seedList)));
    }
    h.repeaterSync = RepeaterSync(store: store, rosterClient: () => c, networkClient: () => c, clock: () => now, parseInIsolate: false);
    h.client.regionsIndexResult = const [cmh, sea];
    if (capabilities != null) h.client.siteConfigResult = SiteConfig(region: _region, capabilities: capabilities);
    current = h;
    return h;
  }

  Iterable<Uri> network() => seen.where((u) => u.path == '/api/cmh/network-repeaters');
  Iterable<Uri> rosters() => seen.where((u) => u.path.endsWith('/region-repeaters'));

  test('opening the app syncs the roster and the global list; capability on: the list is refreshed by delta', () async {
    final h = await make(capabilities: {'networkRepeatersDelta'});
    await h.state.init();
    await h.state.launchSettled.timeout(const Duration(seconds: 20));
    expect(h.client.siteConfigCalls, greaterThanOrEqualTo(1));
    expect(h.state.siteConfig?.networkRepeatersDelta, isTrue);
    expect(rosters().map((u) => u.host), ['cmh.meshsonar.com'], reason: 'the roster of the region the phone is in, once');
    final n = network().toList();
    expect(n, hasLength(1), reason: 'one request for the global list at launch');
    expect(n.single.queryParameters, {'updated_since': '${epochS(DateTime.utc(2026, 10, 24, 11))}'});
    final names = h.state.globalRepeaterSet.rows.map((r) => r.name).toList();
    expect(names, ['One', 'Two (updated)', 'Five (new)'], reason: 'Three removed, Two updated, Five added');
    expect(h.state.repeaterSync!.network!.cursorS, epochS(now) - 120);
    expect(h.state.diagnostics.lines.join('\n'), contains('delta +2 changed, -1 removed'));
  });

  test('capability off: the full list with the stored ETag, no query string', () async {
    final h = await make(capabilities: {'driveEnv'});
    await h.state.init();
    await h.state.launchSettled.timeout(const Duration(seconds: 20));
    expect(h.state.siteConfig?.networkRepeatersDelta, isFalse);
    expect(network().single.hasQuery, isFalse);
    expect(ifNoneMatch, ['"seeded"']);
    expect(h.state.globalRepeaterSet.rows.map((r) => r.name), ['One', 'Two', 'Three'], reason: '304: the stored list stands');
  });

  test('site config unknown (the server has none, or it failed): behaves as before, the full list with ETag', () async {
    final h = await make();
    await h.state.init();
    await h.state.launchSettled.timeout(const Duration(seconds: 20));
    expect(h.state.siteConfig, isNull);
    expect(network().single.hasQuery, isFalse);
    expect(ifNoneMatch, ['"seeded"']);
    expect(h.state.repeaterSync!.networkError, isNull);
  });

  test('a region switch syncs that region\'s roster (once per 10 minutes), not the global list again', () async {
    final h = await make(capabilities: {'networkRepeatersDelta'});
    await h.state.init();
    await h.state.launchSettled.timeout(const Duration(seconds: 20));
    expect(rosters().map((u) => u.host), ['cmh.meshsonar.com']);
    await h.state.setViewingRegion('SEA');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.state.viewingRegion?.code, 'SEA');
    expect(rosters().map((u) => u.host).toList(), ['cmh.meshsonar.com', 'sea.meshsonar.com']);
    expect(h.state.repeaterSync!.roster('sea')!.data.rows.single.name, 'sea.meshsonar.com');
    expect(h.state.regionRepeaterSet.rows.single.name, 'sea.meshsonar.com', reason: 'the map interface follows the viewed region');
    expect(network(), hasLength(1), reason: 'the global list is inside its 6 h gate');
    await h.state.setViewingRegion('CMH');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rosters(), hasLength(2), reason: 'both rosters were confirmed minutes ago');
    expect(h.state.regionRepeaterSet.rows.single.name, 'cmh.meshsonar.com');
  });
}
