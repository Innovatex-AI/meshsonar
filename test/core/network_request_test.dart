// NetworkRequest (AZ-3.1): parse from and serialise to the website's routes (analyzer-api-contract.md section 8 web
// route table), round trips, and input that is not a Network link.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/network_inbox.dart';
import 'package:meshsonar/core/network_request.dart';

const key = 'a7b21db75893e8c8665e5060b05d5e03c68c963d5a3a6e7e0dba6b5e0b9cde85';
const hash = 'c4b06ee8fc39b187';

NetworkRequest? p(String s) => NetworkRequest.parse(Uri.parse(s));

void main() {
  group('parse', () {
    test('each web route lands on its section', () {
      expect(p('https://cmh.meshsonar.com/'), const NetworkRequest.section(NetworkSection.live, region: 'cmh'), reason: 'build 72: the region home opens Live');
      expect(p('https://cmh.meshsonar.com/packets')!.section, NetworkSection.packets);
      expect(p('https://cmh.meshsonar.com/packets/$hash'), NetworkRequest.packet(hash, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/nodes')!.section, NetworkSection.nodes);
      expect(p('https://cmh.meshsonar.com/nodes/$key'), NetworkRequest.node(key, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/repeaters/$key'), NetworkRequest.node(key, region: 'cmh'), reason: 'old /repeaters/* redirects to /nodes/*');
      expect(p('https://cmh.meshsonar.com/observers'), const NetworkRequest.section(NetworkSection.observers, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/observers')!.observersView, isTrue);
      expect(p('https://cmh.meshsonar.com/observers/compare'), const NetworkRequest.toolOf('compare', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/observers/src_31:obs-1142'), const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/channels/public'), const NetworkRequest.channel('public', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/channels/tag:LongFast')!.channelId, 'tag:LongFast', reason: 'hashtag case is kept');
      expect(p('https://cmh.meshsonar.com/channels'), const NetworkRequest.section(NetworkSection.channels, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/live'), const NetworkRequest.section(NetworkSection.live, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/map?panel=live')!.section, NetworkSection.live);
      expect(p('https://cmh.meshsonar.com/pulse'), const NetworkRequest(section: NetworkSection.live, region: 'cmh', pulse: true), reason: 'Live with the pulse sheet');
      expect(p('https://cmh.meshsonar.com/now'), const NetworkRequest.section(NetworkSection.live, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/home'), const NetworkRequest.section(NetworkSection.live, region: 'cmh'));
      expect(p('https://meshsonar.com/regions'), const NetworkRequest.section(NetworkSection.regions), reason: 'All regions');
      expect(p('https://cmh.meshsonar.com/analytics/findings'), const NetworkRequest.analytics(analyticsFindingsSlug, region: 'cmh'), reason: 'the moved Home panels');
      expect(p('meshsonar://network/analytics/region-overview?region=cmh'), const NetworkRequest.analytics(analyticsRegionOverviewSlug, region: 'cmh'));
    });

    test('build 71 site routes: analytics, tools, scope audit, status', () {
      expect(p('https://cmh.meshsonar.com/analytics'), const NetworkRequest.section(NetworkSection.analytics, region: 'cmh'));
      for (final slug in ['overview', 'nodes', 'roles', 'topology', 'rf-signal', 'rf-health', 'hash-stats', 'hash-issues', 'route-patterns', 'distance', 'channels', 'scopes', 'clock-health', 'neighbor-graph', 'repeater-metrics', 'my-repeaters']) {
        expect(p('https://cmh.meshsonar.com/analytics/$slug'), NetworkRequest.analytics(slug, region: 'cmh'), reason: slug);
      }
      expect(p('https://cmh.meshsonar.com/analytics/prefix-tool'), const NetworkRequest.toolOf('prefix', region: 'cmh'), reason: 'a native tool in the app');
      expect(p('https://cmh.meshsonar.com/analytics/prefix-tool?prefix=a7b2'), const NetworkRequest.toolOf('prefix', arg: 'a7b2', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools'), const NetworkRequest.section(NetworkSection.tools, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools/path'), const NetworkRequest.toolOf('path', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools/path?hops=a7,b2,c4')!.toolArg, 'a7,b2,c4');
      expect(p('https://cmh.meshsonar.com/tools/trace'), const NetworkRequest.toolOf('trace', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools/trace/$hash'), const NetworkRequest.toolOf('trace', arg: hash, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools/region'), const NetworkRequest.toolOf('definition', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools/decode'), const NetworkRequest.toolOf('decode', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/tools/airtime')!.tool, 'airtime', reason: 'other tool names pass through');
      expect(p('https://cmh.meshsonar.com/scope-audit'), const NetworkRequest.toolOf('scope-audit', region: 'cmh'));
      expect(p('https://meshsonar.com/status'), const NetworkRequest.toolOf('status'));
    });

    test('the retired Insights links open their Analytics twin', () {
      expect(p('https://cmh.meshsonar.com/insights'), const NetworkRequest.section(NetworkSection.analytics, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/analysis'), const NetworkRequest.section(NetworkSection.analytics, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/insights?tab=signal'), const NetworkRequest.analytics('rf-signal', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/insights?tab=hashes'), const NetworkRequest.analytics('hash-stats', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/insights?tab=growth'), const NetworkRequest.analytics('overview', region: 'cmh'), reason: 'no twin: the first tab');
      expect(p('https://cmh.meshsonar.com/insights?tab=channels'), const NetworkRequest.section(NetworkSection.channels, region: 'cmh'));
    });

    test('section names saved or linked before build 71 still resolve', () {
      expect(NetworkSection.byName('now'), NetworkSection.live);
      expect(NetworkSection.byName('home'), NetworkSection.live, reason: "build 71's Home is gone: Live");
      expect(NetworkSection.byName('map'), NetworkSection.live);
      expect(NetworkSection.byName('insights'), NetworkSection.analytics);
      for (final s in NetworkSection.values) {
        expect(NetworkSection.byName(s.name), s);
      }
      expect(NetworkSection.byName('nope'), isNull);
      expect(networkRegionSections.map((s) => s.label).toList(), ['Live', 'Packets', 'Nodes', 'Channels', 'Observers', 'Analytics', 'Tools'], reason: 'build 72: Live first, no Home');
      expect(networkHubSections.map((s) => s.label).toList(), ['Regions', 'Channels', 'Analytics', 'Tools']);
    });

    test('the live map of one packet keeps the contract form /map?panel=live&packet=', () {
      final r = p('https://cmh.meshsonar.com/map?panel=live&packet=$hash&t=2026-11-20T10:00:00Z')!;
      expect(r, NetworkRequest.mapPacket(hash, region: 'cmh', at: DateTime.utc(2026, 11, 20, 10)));
      expect(r.toWebUri().path, '/map');
      expect(r.toWebUri().queryParameters['panel'], 'live');
    });

    test('region: the host, ?region= on the hub, or the app scheme; none = the viewed region', () {
      expect(p('https://meshsonar.com/packets')!.region, isNull);
      expect(p('https://meshsonar.com/packets?region=CMH')!.region, 'cmh');
      expect(p('meshsonar://network/nodes/$key?region=day')!.region, 'day');
      expect(p('meshsonar://network')!.section, NetworkSection.live);
    });

    test('upper-case keys and hashes are accepted and lower-cased', () {
      expect(p('https://meshsonar.com/packets/${hash.toUpperCase()}')!.packetHash, hash);
      expect(p('https://meshsonar.com/nodes/${key.toUpperCase()}')!.nodeKey, key);
    });

    test('time window: named, or since/until; a bad window is dropped, the link still opens', () {
      expect(p('https://cmh.meshsonar.com/packets?window=24h')!.window, '24h');
      final r = p('https://cmh.meshsonar.com/packets?since=2026-11-20T10:00:00Z&until=2026-11-20T11:00:00Z')!;
      expect(r.since, DateTime.utc(2026, 11, 20, 10));
      expect(r.until, DateTime.utc(2026, 11, 20, 11));
      expect(p('https://cmh.meshsonar.com/packets?window=2y')!.window, isNull);
      final both = p('https://cmh.meshsonar.com/packets?window=1h&since=2026-11-20T10:00:00Z')!;
      expect((both.window, both.since), ('1h', null), reason: 'window and since together keep the named window');
      expect(p('https://cmh.meshsonar.com/packets?since=2026-11-20T11:00:00Z&until=2026-11-20T10:00:00Z')!.since, isNull, reason: 'until before since');
    });

    test('packet list filters', () {
      final r = p('https://cmh.meshsonar.com/packets?node=$key&observer=src_12:7e&channel=tag:wardriving')!;
      expect(r.nodeKey, key);
      expect(r.observerId, 'src_12:7e');
      expect(r.channelId, 'tag:wardriving');
      expect(p('https://cmh.meshsonar.com/packets?node=xyz')!.nodeKey, isNull, reason: 'a bad filter is dropped');
    });

    test('unknown input is null', () {
      for (final s in [
        'https://example.org/packets',
        'https://meshsonar.com.evil.example/packets',
        'https://www.meshsonar.com/packets',
        'https://api.meshsonar.com/packets',
        'https://a.b.meshsonar.com/packets',
        'https://meshsonar.com/share/plan#abc',
        'https://meshsonar.com/plan',
        'https://meshsonar.com/tools/trace/$hash/extra',
        'https://meshsonar.com/analytics/overview/extra',
        'https://meshsonar.com/tools/path/extra',
        'https://meshsonar.com/pulse/x',
        'https://meshsonar.com/settings',
        'https://meshsonar.com/packets/nothex',
        'https://meshsonar.com/packets/$hash/extra',
        'https://meshsonar.com/nodes/abc',
        'https://meshsonar.com/channels/private-key',
        'https://meshsonar.com/insights/signal',
        'https://meshsonar.com/packets?region=bad_slug!',
        'meshsonar://plan#abc',
        'meshcore://contact/add',
        'ftp://meshsonar.com/packets',
        'mailto:x@meshsonar.com',
      ]) {
        expect(p(s), isNull, reason: s);
      }
    });
  });

  group('serialise', () {
    test('web links use the region host, the hub without a region', () {
      expect(NetworkRequest.packet(hash, region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/packets/$hash');
      expect(NetworkRequest.node(key).toWebUri().toString(), 'https://meshsonar.com/nodes/$key');
      expect(const NetworkRequest.section(NetworkSection.live, region: 'day').toWebUri().toString(), 'https://day.meshsonar.com/live');
      expect(const NetworkRequest(section: NetworkSection.live, region: 'day', pulse: true).toWebUri().toString(), 'https://day.meshsonar.com/pulse');
      expect(const NetworkRequest.section(NetworkSection.regions).toWebUri().toString(), 'https://meshsonar.com/regions');
      expect(const NetworkRequest.channel('tag:LongFast', region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/channels/tag%3ALongFast');
      expect(const NetworkRequest(section: NetworkSection.analytics, region: 'cmh', analyticsTab: 'rf-signal', window: '7d').toWebUri().toString(),
          'https://cmh.meshsonar.com/analytics/rf-signal?window=7d');
      expect(const NetworkRequest.toolOf('scope-audit', region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/scope-audit');
      expect(const NetworkRequest.toolOf('prefix', arg: 'a7', region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/analytics/prefix-tool?prefix=a7');
      expect(const NetworkRequest.section(NetworkSection.live, region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/live');
    });

    test('app links carry the region as a query', () {
      expect(NetworkRequest.packet(hash, region: 'cmh').toAppUri().toString(), 'meshsonar://network/packets/$hash?region=cmh');
      expect(const NetworkRequest.section(NetworkSection.live).toAppUri().toString(), 'meshsonar://network/live');
    });

    final samples = <NetworkRequest>[
      const NetworkRequest.section(NetworkSection.regions),
      const NetworkRequest.analytics(analyticsFindingsSlug, region: 'cmh'),
      const NetworkRequest.analytics(analyticsRegionOverviewSlug, region: 'cmh'),
      const NetworkRequest.section(NetworkSection.packets, region: 'cmh', window: '24h'),
      NetworkRequest.packet(hash, region: 'cmh'),
      NetworkRequest.packet(hash),
      NetworkRequest(section: NetworkSection.packets, region: 'cmh', nodeKey: key, channelId: 'public', since: DateTime.utc(2026, 11, 20, 10), until: DateTime.utc(2026, 11, 20, 11)),
      const NetworkRequest(section: NetworkSection.packets, observerId: 'src_12:7e'),
      const NetworkRequest.section(NetworkSection.nodes, region: 'day'),
      NetworkRequest.node(key, region: 'cmh'),
      const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'),
      NetworkRequest.observer(key),
      const NetworkRequest.section(NetworkSection.observers, region: 'cmh'),
      const NetworkRequest.section(NetworkSection.live, region: 'cmh'),
      const NetworkRequest.section(NetworkSection.live),
      NetworkRequest.mapPacket(hash, region: 'cmh', at: DateTime.utc(2026, 11, 20, 10)),
      NetworkRequest.mapPacket(hash),
      const NetworkRequest(section: NetworkSection.live, pulse: true),
      const NetworkRequest(section: NetworkSection.live, region: 'cmh', pulse: true),
      const NetworkRequest.section(NetworkSection.channels),
      const NetworkRequest.section(NetworkSection.channels, region: 'cmh'),
      const NetworkRequest.channel('tag:LongFast', region: 'cmh'),
      const NetworkRequest.channel('enc:a3'),
      const NetworkRequest.channel('public', region: 'day'),
      const NetworkRequest.section(NetworkSection.analytics),
      const NetworkRequest(section: NetworkSection.analytics, region: 'cmh', analyticsTab: 'hash-stats', window: '30d'),
      const NetworkRequest.analytics('rf-signal', region: 'cmh'),
      const NetworkRequest.analytics('topology'),
      const NetworkRequest.section(NetworkSection.tools, region: 'cmh'),
      const NetworkRequest.toolOf('path', region: 'cmh'),
      const NetworkRequest.toolOf('path', arg: 'a7,b2,c4', region: 'cmh'),
      const NetworkRequest.toolOf('trace'),
      const NetworkRequest.toolOf('trace', arg: hash, region: 'cmh'),
      const NetworkRequest.toolOf('prefix', region: 'cmh'),
      const NetworkRequest.toolOf('prefix', arg: 'a7b2'),
      const NetworkRequest.toolOf('scope-audit', region: 'cmh'),
      const NetworkRequest.toolOf('compare', region: 'cmh'),
      const NetworkRequest.toolOf('definition', region: 'cmh'),
      const NetworkRequest.toolOf('status'),
      const NetworkRequest.toolOf('decode', region: 'cmh'),
      const NetworkRequest.toolOf('airtime', region: 'cmh'),
    ];

    for (final r in samples) {
      test('round trip $r ${r.toWebUri()}', () {
        expect(NetworkRequest.parse(r.toWebUri()), r, reason: '${r.toWebUri()}');
        expect(NetworkRequest.parse(r.toAppUri()), r, reason: '${r.toAppUri()}');
        expect(NetworkRequest.parse(Uri.parse(r.toWebUri().toString())), r, reason: 'through a string');
      });
    }
  });

  group('inbox', () {
    test('keeps Network links, ignores the rest, the same one twice in a row once', () {
      final inbox = NetworkInbox();
      expect(inbox.offer(Uri.parse('https://cmh.meshsonar.com/packets/$hash')), isTrue);
      expect(inbox.offer(Uri.parse('https://cmh.meshsonar.com/packets/$hash')), isTrue);
      expect(inbox.offer(Uri.parse('https://meshsonar.com/share/plan#x')), isFalse);
      expect(inbox.offer(Uri.parse('https://example.org/')), isFalse);
      expect(inbox.pending.length, 1);
      expect(inbox.take(), NetworkRequest.packet(hash, region: 'cmh'));
      expect(inbox.take(), isNull);
    });
  });
}
