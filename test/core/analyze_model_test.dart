// AN-1 (app): the Analyze model reads the website's engine payloads (fixtures copied from meshcore-insights
// docs/analyze-contract.md examples, test/fixtures/analyze/) and produces the same figures, chip, states and times as the web.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/analyze_model.dart';
import 'package:meshsonar/core/zone_time.dart';

Map<String, dynamic> fx(String n) =>
    jsonDecode(File('test/fixtures/analyze/$n.json').readAsStringSync()) as Map<String, dynamic>;

final now = DateTime.utc(2026, 11, 11, 9); // 6 h after the engine built
const ok = EngineStatus('ready', null);

void main() {
  final traffic = TrafficRead.parse(fx('traffic'));
  final health = RepeaterHealthRead.parse(fx('repeater_health'));
  final insights = InsightsRead.parse(fx('insights'));
  final gate = NodeGateRead.parse(fx('node_gate'));

  group('traffic figures equal the payload', () {
    test('headline figures and rounding', () {
      final f = trafficFigures(traffic);
      expect(f.packets, '61,234');
      expect(f.observations, '640,000');
      expect(f.observers, '41');
      expect(f.snr, '4.2');
      expect(f.rssi, '-101');
    });
    test('null SNR / RSSI show a dash, never 0', () {
      final t = TrafficRead.parse({...fx('traffic'), 'snrMeanDb': null, 'rssiMeanDbm': null});
      expect(trafficFigures(t).snr, '—');
      expect(trafficFigures(t).rssi, '—');
    });
    test('source chip: ours, outside, phones from the endpoint shares', () {
      expect(sourceChip(traffic), 'ours 38% · outside 60% · phones 2%');
    });
    test('a source with 0 packets is left out', () {
      final j = fx('traffic');
      (j['sources'] as Map)['phone'] = {'packets': 0, 'observations': 0, 'share': 0, 'observers': 0};
      expect(sourceChip(TrafficRead.parse(j)), 'ours 38% · outside 60%');
    });
    test('hop bars sum the three route groups, flood share over all bins', () {
      // flood 100/120/80 at 0-2 hops (x2 hours), direct 20/30 at 0-1, other 50 at 3
      final h = hopHistogram(traffic.rows);
      expect(h.map((e) => (e.hops, e.n)).toList(), [(0, 240), (1, 300), (2, 160), (3, 100)]);
      expect(floodShare(traffic.rows), closeTo(600 / 800, 1e-9)); // flood bins 0..16: 100+120+80 per row = 300 x 2
    });
    test('SNR bars start at -30 + first non-empty bin, edges trimmed', () {
      final s = snrBars(traffic.rows);
      expect(s.first.snr, 3);
      expect(s.last.snr, 5);
      expect(s.map((e) => e.n).toList(), [20, 60, 120]);
    });
    test('packets by type uses the packet-type table', () {
      final t = packetsByType(traffic.rows);
      expect(t, {4: 120, 5: 80});
      expect(packetTypeName(4), 'Advert');
      expect(packetTypeName(5), 'Group text');
      expect(packetTypeName(12), 'Type 12');
    });
  });

  group('network health', () {
    test('counts as sent, silent = nodes - heard24h', () {
      expect(health.counts!.nodes, 40);
      expect(health.counts!.heard24h, 31);
      expect(health.counts!.silent24h, 9);
      expect(health.counts!.relaying24h, 22);
    });
    test('uptime is a 0-100 percent number', () {
      expect(uptimeText(89.3), '89%');
      expect(uptimeText(41.2), '41%');
      expect(uptimeText(null), '—');
    });
    test('busiest leaves out null relays (shared code); least reliable by lowest uptime', () {
      expect(busiest(health.rows).map((r) => r.name), ['Central', 'Ridge']);
      expect(leastReliable(health.rows).map((r) => r.uptime7d), [12.0, 41.2, 89.3]);
    });
    test('events parse and name', () {
      final e = parseRecentEvents(fx('overview'));
      expect(e.length, 2);
      expect(eventWord[e.first.type], 'New repeater');
    });
  });

  test('findings sort most severe first, engine order inside a severity', () {
    expect(sortFindings(insights.rows).map((f) => f.code), ['critical_nodes', 'low_uptime', 'repeaters_new']);
  });

  test('node gate: the server sentence for a partial list, history by UTC day', () {
    final g = gate.gate!;
    expect(g.trusted, isFalse);
    expect(describeNodeList(g).title, 'Partial: node list incomplete');
    expect(describeNodeList(g).body, contains('812 of 1,000'));
    expect(formatPct(g.ratio, 0), '81%');
    expect(gate.history.map((d) => d.day), ['2026-11-09', '2026-11-10']);
    expect(gate.hopsFrom, 'e3');
  });

  group('formatters match the web', () {
    test('formatInt', () {
      expect(formatInt(1234567), '1,234,567');
      expect(formatInt(null), '—');
      expect(formatInt(2.5), '3');
    });
    test('formatPct rounds half up and keeps digits', () {
      expect(formatPct(0.38, 0), '38%');
      expect(formatPct(0.5, 0), '50%');
      expect(formatPct(0.0125, 1), '1.3%');
      expect(formatPct(null), '—');
    });
  });

  group('section verdict (DEF-2)', () {
    SectionVerdict v({
      bool loading = false,
      bool failed = false,
      EngineStatus? status = ok,
      DateTime? built,
      DatasetStatus? ds,
    }) => sectionVerdict(
      loading: loading,
      failed: failed,
      status: status,
      builtAt: built ?? DateTime.utc(2026, 11, 11, 3, 50),
      dataset: ds,
      now: now,
    );
    test('loading, error, ready', () {
      expect(v(loading: true).state, SectionState.loading);
      expect(v(failed: true).state, SectionState.error);
      expect(v().state, SectionState.ready);
    });
    test('region-status error beats a ready read; none gives its reason', () {
      expect(v(ds: const DatasetStatus('k', 'error', 'unit failed', null)).state, SectionState.error);
      final n = v(ds: const DatasetStatus('k', 'none', 'No source covers this region.', null));
      expect(n.state, SectionState.none);
      expect(n.reason, 'No source covers this region.');
    });
    test('pending / unavailable / not_found reads are none', () {
      for (final s in ['pending', 'unavailable', 'not_found']) {
        expect(v(status: EngineStatus(s, 'why')).state, SectionState.none);
      }
    });
    test('stale: engine says so, region-status says so, or older than 36 h client-side', () {
      expect(v(status: const EngineStatus('stale', null)).state, SectionState.stale);
      expect(v(ds: const DatasetStatus('k', 'stale', null, null)).state, SectionState.stale);
      expect(v(built: DateTime.utc(2026, 11, 9, 3, 50)).state, SectionState.stale); // 53 h old, cached "ready"
      expect(
        v(built: now.subtract(const Duration(hours: 36))).state,
        SectionState.ready,
      ); // exactly 36 h is still current
    });
  });

  group('region time zone', () {
    test('EST in November, EDT in July, abbreviation shown', () {
      expect(formatInZone(DateTime.utc(2026, 11, 11, 3, 50), 'America/New_York'), 'Nov 10, 2026, 10:50 PM EST');
      expect(formatInZone(DateTime.utc(2026, 7, 4, 16), 'America/New_York'), 'Jul 4, 2026, 12:00 PM EDT');
      expect(zoneAbbr('America/New_York', DateTime.utc(2026, 11, 11)), 'EST');
    });
    test('missing or unknown zone says UTC, never the phone zone', () {
      expect(formatInZone(DateTime.utc(2026, 11, 11, 3, 50), null), 'Nov 11, 2026, 3:50 AM UTC');
      expect(formatInZone(DateTime.utc(2026, 11, 11, 3, 50), 'Nowhere/Land'), 'Nov 11, 2026, 3:50 AM UTC');
      expect(formatInZone(null, 'America/New_York'), '—');
    });
  });
}
