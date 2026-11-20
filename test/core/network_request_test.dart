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
      expect(p('https://cmh.meshsonar.com/'), const NetworkRequest.section(NetworkSection.now, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/packets')!.section, NetworkSection.packets);
      expect(p('https://cmh.meshsonar.com/packets/$hash'), NetworkRequest.packet(hash, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/nodes')!.section, NetworkSection.nodes);
      expect(p('https://cmh.meshsonar.com/nodes/$key'), NetworkRequest.node(key, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/repeaters/$key'), NetworkRequest.node(key, region: 'cmh'), reason: 'old /repeaters/* redirects to /nodes/*');
      expect(p('https://cmh.meshsonar.com/observers')!.observersView, isTrue);
      expect(p('https://cmh.meshsonar.com/observers/compare')!.observersView, isTrue);
      expect(p('https://cmh.meshsonar.com/observers/src_31:obs-1142'), const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/channels/public'), const NetworkRequest.channel('public', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/channels/tag:LongFast')!.channelId, 'tag:LongFast', reason: 'hashtag case is kept');
      expect(p('https://cmh.meshsonar.com/channels')!.insightsTab, 'channels');
      expect(p('https://cmh.meshsonar.com/insights?tab=signal')!.insightsTab, 'signal');
      expect(p('https://cmh.meshsonar.com/analysis')!.section, NetworkSection.insights);
      expect(p('https://cmh.meshsonar.com/map?panel=live')!.mapPanel, 'live');
      expect(p('https://cmh.meshsonar.com/live')!.mapPanel, 'live');
    });

    test('region: the host, ?region= on the hub, or the app scheme; none = the viewed region', () {
      expect(p('https://meshsonar.com/packets')!.region, isNull);
      expect(p('https://meshsonar.com/packets?region=CMH')!.region, 'cmh');
      expect(p('meshsonar://network/nodes/$key?region=day')!.region, 'day');
      expect(p('meshsonar://network')!.section, NetworkSection.now);
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
        'https://meshsonar.com/status',
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
      expect(const NetworkRequest.section(NetworkSection.now, region: 'day').toWebUri().toString(), 'https://day.meshsonar.com/');
      expect(const NetworkRequest.channel('tag:LongFast', region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/channels/tag%3ALongFast');
      expect(const NetworkRequest(section: NetworkSection.insights, region: 'cmh', insightsTab: 'signal', window: '7d').toWebUri().toString(),
          'https://cmh.meshsonar.com/insights?tab=signal&window=7d');
    });

    test('app links carry the region as a query', () {
      expect(NetworkRequest.packet(hash, region: 'cmh').toAppUri().toString(), 'meshsonar://network/packets/$hash?region=cmh');
      expect(const NetworkRequest.section(NetworkSection.now).toAppUri().toString(), 'meshsonar://network');
    });

    final samples = <NetworkRequest>[
      const NetworkRequest.section(NetworkSection.now),
      const NetworkRequest.section(NetworkSection.now, region: 'cmh'),
      const NetworkRequest.section(NetworkSection.packets, region: 'cmh', window: '24h'),
      NetworkRequest.packet(hash, region: 'cmh'),
      NetworkRequest.packet(hash),
      NetworkRequest(section: NetworkSection.packets, region: 'cmh', nodeKey: key, channelId: 'public', since: DateTime.utc(2026, 11, 20, 10), until: DateTime.utc(2026, 11, 20, 11)),
      const NetworkRequest(section: NetworkSection.packets, observerId: 'src_12:7e'),
      const NetworkRequest.section(NetworkSection.nodes, region: 'day'),
      NetworkRequest.node(key, region: 'cmh'),
      const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'),
      NetworkRequest.observer(key),
      const NetworkRequest(section: NetworkSection.nodes, region: 'cmh', observersList: true),
      const NetworkRequest.section(NetworkSection.map, region: 'cmh'),
      const NetworkRequest(section: NetworkSection.map, mapPanel: 'live'),
      const NetworkRequest.section(NetworkSection.insights),
      const NetworkRequest(section: NetworkSection.insights, region: 'cmh', insightsTab: 'hashes', window: '30d'),
      const NetworkRequest.channel('tag:LongFast', region: 'cmh'),
      const NetworkRequest.channel('enc:a3'),
      const NetworkRequest(section: NetworkSection.insights, insightsTab: 'channels'),
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
