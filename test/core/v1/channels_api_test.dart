// The Channels reads (build 71): the list, a channel's messages (older and newer cursors), search, the report POST
// (202 receipt, 429, not switched on, offline, sent once) and the "no packet feed" probe with its session cache.
// Bodies follow the live `/v1` answers (cmh, phx) and the site's contract fixtures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart' show cacheAsOfHeader, cacheSourceHeader;
import 'package:meshsonar/core/region_overview_api.dart' show RegionDataState, RegionDataStatus;
import 'package:meshsonar/core/v1/channels_api.dart';

const base = 'https://cmh.meshsonar.com';
http.Response js(Object body, [int status = 200, Map<String, String> h = const {}]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json', ...h});

Map<String, dynamic> meta({Map<String, dynamic>? status, String slug = 'cmh', String name = 'Columbus, US'}) => {
      'apiVersion': '1.0',
      'region': {'slug': slug, 'name': name, 'kind': 'region'},
      'generatedAt': '2026-11-21T11:27:23.012Z',
      'dataAt': null,
      'status': status ?? {'state': 'ready', 'reason': null},
      'sources': <String, dynamic>{},
    };

Map<String, dynamic> msg(String id, String seen, {String? text = 'hello', bool hidden = false, List<List<int>>? highlight}) => {
      'id': id,
      'packetHash': id,
      'channel': {'id': 'public', 'name': 'Public', 'kind': 'public'},
      'sender': 'Jet11 Mobile',
      'senderVerified': false,
      'text': text,
      'hidden': hidden,
      'senderTime': seen,
      'firstSeen': seen,
      'heardBy': 3,
      'hops': 7,
      'bestSnr': 12.5,
      'scope': null,
      'src': ['meshsonar'],
      'highlight': ?highlight,
    };

const noFeed = {
  'state': 'unavailable',
  'code': 'no_packet_feed',
  'reason': 'No packet feed covers Southern Arizona, US yet: no outside feed delivers packets here and no MeshSonar observer or phone reports to it.',
};

void main() {
  setUp(() {
    resetV1NotLive();
    resetPacketFeedProbes();
  });

  test('list: public, hashtag and private rows; hub rows carry regions', () async {
    final api = ChannelsApi(base,
        client: MockClient((r) async {
          expect(r.url.path, '/v1/channels');
          return js({
            'data': [
              {'id': 'tag:wardriving', 'name': '#wardriving', 'kind': 'hashtag', 'hashByte': '81', 'decodable': true, 'messages24h': 204, 'senders24h': 15, 'lastMessageAt': '2026-11-21T10:45:08.000Z', 'lastSender': 'Jet11 Mobile', 'keySource': 'hashtag_list', 'regions': ['yvr', 'san']},
              {'id': 'enc:fc', 'name': null, 'kind': 'unknown', 'hashByte': 'fc', 'decodable': false, 'messages24h': 20, 'senders24h': null, 'lastMessageAt': '2026-11-21T06:18:02.683Z', 'lastSender': null, 'keySource': null},
              {'nonsense': true},
            ],
            'meta': meta(),
          });
        }));
    final p = await api.list();
    expect(p.rows, hasLength(2));
    expect(p.rows[0].label, '#wardriving');
    expect(p.rows[0].private, isFalse);
    expect(p.rows[0].messages24h, 204);
    expect(p.rows[0].senders24h, 15);
    expect(p.rows[0].regions, ['yvr', 'san']);
    expect(p.rows[0].lastMessageAt, DateTime.utc(2026, 11, 21, 10, 45, 8));
    expect(p.rows[1].private, isTrue);
    expect(p.rows[1].label, 'Private channel');
    expect(p.rows[1].privateId, 'fc');
    expect(p.rows[1].senders24h, isNull);
    expect(p.scopeName, 'Columbus, US');
  });

  test('list: an empty answer keeps the status code (channel store off)', () async {
    final api = ChannelsApi(base,
        client: MockClient((r) async => js({
              'data': [],
              'meta': meta(status: {'state': 'pending', 'code': 'channel_store_off', 'reason': 'No channel messages stored for Columbus, US yet.'}),
            })));
    final p = await api.list();
    expect(p.rows, isEmpty);
    expect(p.statusCode, 'channel_store_off');
    expect(p.status.state, RegionDataState.pending);
  });

  test('messages: the id is path-encoded, order and limit are sent, both cursors come back', () async {
    final seen = <Uri>[];
    final api = ChannelsApi(base,
        client: MockClient((r) async {
          seen.add(r.url);
          return js({
            'data': [msg('bb', '2026-11-21T11:21:02.809Z'), msg('aa', '2026-11-21T11:20:37.658Z', text: null, hidden: true)],
            'page': {'limit': 50, 'next': 'OLDER', 'prev': 'NEWER', 'order': 'newest_first'},
            'meta': meta(),
          });
        }));
    final p = await api.messages('tag:test');
    expect(seen.single.toString(), contains('/v1/channels/tag%3Atest/messages'));
    expect(seen.single.queryParameters, {'order': 'newest_first', 'limit': '50'});
    expect(p.next, 'OLDER');
    expect(p.prev, 'NEWER');
    expect(p.rows[0].sender, 'Jet11 Mobile');
    expect(p.rows[0].bestSnr, 12.5);
    expect(p.rows[1].hidden, isTrue);
    expect(p.rows[1].text, isNull);
    await api.messages('tag:test', cursor: 'NEWER');
    expect(seen.last.queryParameters, {'order': 'newest_first', 'limit': '50', 'cursor': 'NEWER'});
  });

  test('search: q, channel and cursor are sent; highlight ranges are read', () async {
    late Uri url;
    final api = ChannelsApi(base,
        client: MockClient((r) async {
          url = r.url;
          return js({
            'data': [msg('cf', '2026-11-21T11:24:31.000Z', text: 'Test', highlight: [[0, 4]])],
            'page': {'limit': 30, 'next': 'N2'},
            'meta': meta(),
          });
        }));
    final p = await api.search('test', channelId: 'public', cursor: 'N1');
    expect(url.path, '/v1/messages/search');
    expect(url.queryParameters, {'q': 'test', 'channel': 'public', 'cursor': 'N1', 'limit': '30'});
    expect(p.rows.single.highlight, [(0, 4)]);
    expect(p.next, 'N2');
    expect(p.prev, isNull);
  });

  test('search: a too-short q is the server\'s bad_param', () async {
    final api = ChannelsApi(base,
        client: MockClient((r) async => js({
              'error': {'code': 'bad_param', 'message': 'q must be 2 to 100 characters.', 'param': 'q', 'requestId': 'req_1'}
            }, 400)));
    await expectLater(api.search('a'), throwsA(isA<V1Error>().having((e) => e.code, 'code', 'bad_param')));
  });

  group('report', () {
    test('202 gives the receipt; the body is exactly {reason, note}; it is sent once', () async {
      var calls = 0;
      late http.Request req;
      final api = ChannelsApi(base,
          client: MockClient((r) async {
            calls++;
            req = r;
            return js({
              'data': {'id': 'rep_01JD6A0B1C', 'messageId': '28ae38a42d01ec6b', 'status': 'received'},
              'meta': meta(),
            }, 202);
          }));
      final r = await api.report('28ae38a42d01ec6b', reason: 'spam', note: '  flood  ');
      expect(r.id, 'rep_01JD6A0B1C');
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/messages/28ae38a42d01ec6b/report');
      expect(jsonDecode(req.body), {'reason': 'spam', 'note': 'flood'});
      expect(calls, 1);
    });

    test('an empty note is left out and a long one is cut to the limit', () async {
      final bodies = <Object?>[];
      final api = ChannelsApi(base,
          client: MockClient((r) async {
            bodies.add(jsonDecode(r.body));
            return js({
              'data': {'id': 'rep_1', 'messageId': 'aa', 'status': 'received'},
              'meta': meta(),
            }, 202);
          }));
      await api.report('aa', reason: 'other', note: '   ');
      await api.report('aa', reason: 'other', note: 'x' * 900);
      expect(bodies[0], {'reason': 'other'});
      expect(((bodies[1] as Map)['note'] as String).length, reportNoteMaxChars);
    });

    test('429 carries retryAfter and is not retried', () async {
      var calls = 0;
      final api = ChannelsApi(base,
          client: MockClient((r) async {
            calls++;
            return js({
              'error': {'code': 'rate_limited', 'message': 'Too many reports.', 'retryAfter': 1200, 'requestId': 'req_2'}
            }, 429);
          }));
      await expectLater(
          api.report('aa', reason: 'spam'), throwsA(isA<V1Error>().having((e) => e.code, 'code', 'rate_limited').having((e) => e.retryAfter, 'retryAfter', 1200)));
      expect(calls, 1);
    });

    test('a server without the route is "not switched on"', () async {
      final api = ChannelsApi(base, client: MockClient((r) async => http.Response('<html>', 404)));
      await expectLater(api.report('aa', reason: 'spam'), throwsA(isA<V1NotLive>()));
    });

    test('no network is an offline error, sent once', () async {
      var calls = 0;
      final api = ChannelsApi(base,
          client: MockClient((r) async {
            calls++;
            throw const SocketException('down');
          }));
      await expectLater(api.report('aa', reason: 'spam'), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
      expect(calls, 1);
    });
  });

  test('offline: the list and a first page served from the stored copy carry their as-of time', () async {
    final asOf = DateTime.utc(2026, 11, 21, 9);
    final api = ChannelsApi(base,
        client: MockClient((r) async => js(
              r.url.path == '/v1/channels'
                  ? {
                      'data': [
                        {'id': 'public', 'name': 'Public', 'kind': 'public', 'hashByte': '11', 'decodable': true, 'messages24h': 1}
                      ],
                      'meta': meta()
                    }
                  : {
                      'data': [msg('aa', '2026-11-21T08:00:00.000Z')],
                      'page': {'limit': 50, 'next': null, 'prev': 'NEWER'},
                      'meta': meta()
                    },
              200,
              {cacheSourceHeader: 'offline', cacheAsOfHeader: asOf.toIso8601String()},
            )));
    expect((await api.list()).offlineAsOf, asOf);
    expect((await api.messages('public')).offlineAsOf, asOf);
  });

  group('packet feed probe', () {
    test('no_packet_feed is read from /v1/packets?limit=1 and remembered for the session', () async {
      var calls = 0;
      http.Client c() => MockClient((r) async {
            calls++;
            expect(r.url.path, '/v1/packets');
            expect(r.url.queryParameters, {'limit': '1'});
            return js({
              'data': [],
              'page': {'limit': 1, 'next': null},
              'meta': meta(status: noFeed, slug: 'phx', name: 'Southern Arizona, US'),
            });
          });
      final a = await ChannelsApi('https://phx.meshsonar.com', client: c()).packetFeed();
      expect(a.hasFeed, isFalse);
      expect(a.reason, startsWith('No packet feed covers Southern Arizona'));
      expect(a.scopeName, 'Southern Arizona, US');
      final b = await ChannelsApi('https://phx.meshsonar.com', client: c()).packetFeed();
      expect(b.hasFeed, isFalse);
      expect(calls, 1);
      // another host is asked on its own
      await ChannelsApi('https://swoh.meshsonar.com', client: c()).packetFeed();
      expect(calls, 2);
    });

    test('a region with a feed has one', () async {
      final api = ChannelsApi(base,
          client: MockClient((r) async => js({
                'data': [],
                'page': {'limit': 1, 'next': null},
                'meta': meta(),
              })));
      expect((await api.packetFeed()).hasFeed, isTrue);
    });

    test('a failure never reads as "no feed" and is asked again', () async {
      var calls = 0;
      http.Client c() => MockClient((r) async {
            calls++;
            throw const SocketException('down');
          });
      expect((await ChannelsApi(base, client: c()).packetFeed()).hasFeed, isTrue);
      expect((await ChannelsApi(base, client: c()).packetFeed()).hasFeed, isTrue);
      expect(calls, 2);
    });

    test('isNoPacketFeed: the code, or the sentence when the code is not known', () {
      const st = RegionDataStatus(state: RegionDataState.unavailable, reason: 'No packet feed covers Southwest Ohio (SWOH) yet: nothing reports to it.');
      expect(isNoPacketFeed(st), isTrue);
      expect(isNoPacketFeed(const RegionDataStatus(state: RegionDataState.unavailable, reason: 'The store is down.')), isFalse);
      expect(isNoPacketFeed(const RegionDataStatus(state: RegionDataState.ready), code: 'no_packet_feed'), isTrue);
      expect(isNoPacketFeed(null), isFalse);
    });
  });

  group('merging', () {
    ChannelMessage m(String id, int minute) => ChannelMessage(id: id, packetHash: id, channelId: 'public', firstSeen: DateTime.utc(2026, 11, 21, 11, minute));

    test('newer rows go to the bottom, duplicates are dropped, the cap drops the oldest', () {
      final held = [m('a', 1), m('b', 2)];
      final (rows, added) = mergeNewer(held, [m('d', 4), m('b', 2), m('c', 3)]);
      expect([for (final r in rows) r.id], ['a', 'b', 'c', 'd']);
      expect(added, 2);
      final (capped, _) = mergeNewer(held, [m('c', 3), m('d', 4)], cap: 3);
      expect([for (final r in capped) r.id], ['b', 'c', 'd']);
      expect(mergeNewer(held, [m('a', 1)]).$2, 0);
    });

    test('an older page goes in front, duplicates dropped', () {
      final held = [m('c', 3), m('d', 4)];
      final rows = mergeOlder(held, [m('c', 3), m('b', 2), m('a', 1)]);
      expect([for (final r in rows) r.id], ['a', 'b', 'c', 'd']);
    });
  });
}
