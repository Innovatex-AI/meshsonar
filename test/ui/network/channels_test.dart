// Network > Channels (build 71) widget tests, dark theme, at a 375 pt wide phone: the channel list (readable rows,
// private rows disabled in place, no packet feed, store off, offline), the reader (newest at the bottom, hidden rows,
// the 20 s poll only while visible and in front, the "N new" pill instead of moving the list, older pages), search
// (nothing under 2 characters, bold match, open channel) and the report sheet (explainer, receipt, rate limit, sent once).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart' show cacheAsOfHeader, cacheSourceHeader;
import 'package:meshsonar/core/v1/channels_api.dart';
import 'package:meshsonar/ui/network/channels/channel_reader.dart';
import 'package:meshsonar/ui/network/channels/channel_search.dart';
import 'package:meshsonar/ui/network/channels/channels_section.dart';
import 'package:meshsonar/ui/theme.dart';

const base = 'https://cmh.meshsonar.com';
DateTime? _asOf;
http.Response js(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {
      'content-type': 'application/json',
      if (_asOf != null) ...{cacheSourceHeader: 'offline', cacheAsOfHeader: _asOf!.toIso8601String()},
    });

Map<String, dynamic> meta({Map<String, dynamic>? status, String name = 'Columbus, US'}) => {
      'apiVersion': '1.0',
      'region': {'slug': 'cmh', 'name': name, 'kind': 'region'},
      'generatedAt': '2026-11-21T11:27:23.012Z',
      'dataAt': null,
      'status': status ?? {'state': 'ready', 'reason': null},
      'sources': <String, dynamic>{},
    };

Map<String, dynamic> msg(int n, {String? text, bool hidden = false, List<List<int>>? highlight, String channel = 'public', String channelName = 'Public'}) => {
      'id': 'm${n.toString().padLeft(4, '0')}',
      'packetHash': 'aaaaaaaaaaaa${n.toString().padLeft(4, '0')}',
      'channel': {'id': channel, 'name': channelName, 'kind': channel == 'public' ? 'public' : 'hashtag'},
      'sender': 'Sender $n',
      'senderVerified': false,
      'text': hidden ? null : (text ?? 'message number $n'),
      'hidden': hidden,
      'senderTime': null,
      'firstSeen': DateTime.utc(2026, 11, 21, 8).add(Duration(minutes: n)).toIso8601String(),
      'heardBy': 3,
      'hops': 7,
      'bestSnr': 12.5,
      'scope': null,
      'src': ['meshsonar'],
      'highlight': ?highlight,
    };

const channels = [
  {'id': 'tag:wardriving', 'name': '#wardriving', 'kind': 'hashtag', 'hashByte': '81', 'decodable': true, 'messages24h': 1204, 'senders24h': 15, 'lastMessageAt': '2026-11-21T10:45:08.000Z', 'lastSender': 'Jet11 Mobile With A Very Long Name Indeed To Check Overflow', 'keySource': 'hashtag_list'},
  {'id': 'enc:fc', 'name': null, 'kind': 'unknown', 'hashByte': 'fc', 'decodable': false, 'messages24h': 20, 'senders24h': null, 'lastMessageAt': '2026-11-21T06:18:02.683Z', 'lastSender': null, 'keySource': null},
  {'id': 'public', 'name': 'Public', 'kind': 'public', 'hashByte': '11', 'decodable': true, 'messages24h': 124, 'senders24h': 45, 'lastMessageAt': '2026-11-21T11:21:02.809Z', 'lastSender': 'MeshMonitor', 'keySource': 'builtin_public'},
];

class Server {
  final List<http.Request> seen = [];
  bool offline = false;
  List<Map<String, dynamic>> channelRows = [...channels];
  Map<String, dynamic>? channelStatus;
  bool noFeed = false;

  /// First page of the public channel (newest first) and what a poll (`cursor=NEWER...`) answers.
  List<Map<String, dynamic>> first = [msg(3), msg(2, hidden: true), msg(1)];
  List<Map<String, dynamic>> older = [];
  List<Map<String, dynamic>> newer = [];
  int polls = 0;
  int reportStatus = 202;
  int reports = 0;

  /// Set: every answer is the phone's stored copy from this time (what the ETag client serves offline).
  DateTime? storedAsOf;

  late final MockClient client = MockClient((r) async {
    seen.add(r);
    _asOf = storedAsOf;
    if (offline) throw const SocketException('down');
    final p = r.url.path;
    final q = r.url.queryParameters;
    if (p == '/v1/channels') return js({'data': channelRows, 'meta': meta(status: channelStatus)});
    if (p == '/v1/packets') {
      return js({
        'data': [],
        'page': {'limit': 1, 'next': null},
        'meta': meta(
            name: 'Southern Arizona, US',
            status: noFeed ? {'state': 'unavailable', 'code': 'no_packet_feed', 'reason': 'No packet feed covers Southern Arizona, US yet: nothing reports to it.'} : null),
      });
    }
    if (p == '/v1/channels/public/messages') {
      final c = q['cursor'];
      if (c == 'OLDER') return js({'data': older, 'page': {'limit': 50, 'next': null}, 'meta': meta()});
      if (c != null && c.startsWith('NEWER')) {
        polls++;
        final rows = newer;
        newer = [];
        return js({'data': rows, 'page': {'limit': 50, 'next': null, 'prev': 'NEWER$polls'}, 'meta': meta()});
      }
      return js({'data': first, 'page': {'limit': 50, 'next': older.isEmpty ? null : 'OLDER', 'prev': 'NEWER'}, 'meta': meta()});
    }
    if (p == '/v1/messages/search') {
      return js({
        'data': [msg(7, text: 'a Test of things', highlight: [[2, 6]], channel: 'tag:test', channelName: '#test')],
        'page': {'limit': 30, 'next': null},
        'meta': meta(),
      });
    }
    if (p.endsWith('/report')) {
      reports++;
      if (reportStatus == 429) return js({'error': {'code': 'rate_limited', 'message': 'Too many reports.', 'retryAfter': 1200, 'requestId': 'r'}}, 429);
      if (reportStatus == 404) return http.Response('<html>', 404);
      return js({'data': {'id': 'rep_01JD6A0B1C', 'messageId': 'm0003', 'status': 'received'}, 'meta': meta()}, 202);
    }
    return js({'error': {'code': 'not_found', 'message': 'Unknown', 'requestId': 'r'}}, 404);
  });

  Iterable<http.Request> at(String path) => seen.where((r) => r.url.path == path);
}

Widget app(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.dark), home: child);

/// A 375 x 812 pt phone.
void phone(WidgetTester t) {
  t.view.physicalSize = const Size(1125, 2436);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Server s;
  setUp(() {
    resetV1NotLive();
    resetPacketFeedProbes();
    _asOf = null;
    s = Server();
    channelsApiFactory = (b) => ChannelsApi(b, client: s.client);
  });
  tearDown(() => channelsApiFactory = (b) => ChannelsApi(b));

  group('channel list', () {
    testWidgets('readable channels first with counts and last sender; a private one is disabled in place', (t) async {
      phone(t);
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: base, regionSlug: 'cmh'))));
      await settle(t);
      expect(find.text('#wardriving'), findsOneWidget);
      expect(find.text('1,204 messages · 15 senders in 24 h'), findsOneWidget);
      expect(find.textContaining('Last: MeshMonitor'), findsOneWidget);
      expect(find.text('Private channel fc'), findsOneWidget);
      expect(find.byKey(const Key('channel-private-enc:fc')), findsOneWidget);
      // readable rows above the private one, whatever order the server sent
      expect(t.getTopLeft(find.text('Public')).dy, lessThan(t.getTopLeft(find.text('Private channel fc')).dy));
      expect(t.takeException(), isNull, reason: 'no overflow at 375 pt');

      // a private row does not navigate
      await t.tap(find.byKey(const Key('channel-row-enc:fc')), warnIfMissed: false);
      await settle(t);
      expect(find.byType(ChannelReaderView), findsNothing);

      // rows and the search field are at least 44 pt tall
      expect(t.getSize(find.byKey(const Key('channel-row-public'))).height, greaterThanOrEqualTo(44));
      expect(t.getSize(find.byKey(const Key('channels-search'))).height, greaterThanOrEqualTo(44));

      // the reader opens INSIDE the section (no pushed page), with a 44 pt back arrow to the list
      await t.tap(find.byKey(const Key('channel-row-public')));
      await settle(t);
      expect(find.byType(ChannelReaderView), findsOneWidget);
      expect(find.byType(ChannelReaderScreen), findsNothing);
      expect(find.byType(ChannelsSection), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('channel-title'))).data, 'Public');
      expect(t.getSize(find.byKey(const Key('channel-back'))).height, greaterThanOrEqualTo(44));
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const Key('channel-back')));
      await settle(t);
      expect(find.byType(ChannelReaderView), findsNothing);
      expect(find.text('#wardriving'), findsOneWidget);
    });

    testWidgets('a region with no packet feed says so plainly (one probe, remembered)', (t) async {
      phone(t);
      s.channelRows = [];
      s.noFeed = true;
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: 'https://phx.meshsonar.com', regionSlug: 'phx'))));
      await settle(t);
      expect(find.byKey(const Key('no-packet-feed')), findsOneWidget);
      expect(find.text('No packet feed for Southern Arizona, US yet'), findsOneWidget);
      expect(find.textContaining('No packet feed covers Southern Arizona'), findsOneWidget);
      expect(find.byKey(const Key('channels-empty')), findsNothing);
      expect(find.byKey(const Key('channels-search')), findsNothing);
      expect(s.at('/v1/packets'), hasLength(1));
      expect(t.takeException(), isNull);
    });

    testWidgets('a region with a feed and nothing said is "no messages in 24 hours"; the hub is never probed', (t) async {
      phone(t);
      s.channelRows = [];
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: base, regionSlug: 'cmh'))));
      await settle(t);
      expect(find.byKey(const Key('channels-empty')), findsOneWidget);
      expect(find.byKey(const Key('no-packet-feed')), findsNothing);
      expect(s.at('/v1/packets'), hasLength(1));

      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(key: Key('hub'), baseUrl: 'https://meshsonar.com', regionSlug: null))));
      await settle(t);
      expect(find.byKey(const Key('channels-empty')), findsOneWidget);
      expect(s.at('/v1/packets'), hasLength(1));
    });

    testWidgets('channel store off shows the server\'s sentence', (t) async {
      phone(t);
      s.channelRows = [];
      s.channelStatus = {'state': 'pending', 'code': 'channel_store_off', 'reason': 'No channel messages stored for Columbus, US yet: channel decoding is off.'};
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: base, regionSlug: 'cmh'))));
      await settle(t);
      expect(find.byKey(const Key('channels-store-off')), findsOneWidget);
      expect(find.textContaining('channel decoding is off'), findsOneWidget);
    });

    testWidgets('offline: no connection with Retry, then the list', (t) async {
      phone(t);
      s.offline = true;
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: base, regionSlug: 'cmh'))));
      await settle(t);
      expect(find.byKey(const Key('region-offline-empty')), findsOneWidget);
      s.offline = false;
      await t.tap(find.byKey(const Key('region-offline-retry')));
      await settle(t);
      expect(find.text('#wardriving'), findsOneWidget);
    });

    testWidgets('the stored copy is labelled "Offline - as of" on the list and in the reader', (t) async {
      phone(t);
      s.storedAsOf = DateTime.now().toUtc().subtract(const Duration(hours: 3));
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: base, regionSlug: 'cmh'))));
      await settle(t);
      expect(find.text('#wardriving'), findsOneWidget);
      expect(find.byKey(const Key('region-offline-asof')), findsOneWidget);
      expect(find.textContaining('Offline - as of 3 h ago'), findsOneWidget);
      await t.tap(find.byKey(const Key('channel-row-public')));
      await settle(t);
      expect(find.text('message number 3'), findsOneWidget);
      expect(find.byKey(const Key('region-offline-asof')), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('hub rows say where a channel was heard; initialChannelId opens the reader', (t) async {
      phone(t);
      s.channelRows = [
        {...channels[2], 'regions': ['yvr', 'san', 'lax', 'oxr', 'sba']}
      ];
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: 'https://meshsonar.com', regionSlug: null, initialChannelId: 'public'))));
      await settle(t);
      expect(find.byType(ChannelReaderView), findsOneWidget);
      expect(find.byType(ChannelsSection), findsOneWidget, reason: 'the section stays on stage: nothing is pushed over the Network tab');
      await t.tap(find.byKey(const Key('channel-back')));
      await settle(t);
      expect(find.textContaining('Heard in yvr, san, lax +2'), findsOneWidget);
      expect(find.byType(ChannelReaderView), findsNothing, reason: 'the link opens once, not on every rebuild');
    });
  });

  group('reader', () {
    Widget reader() => app(const ChannelReaderScreen(baseUrl: base, regionSlug: 'cmh', channelId: 'public', title: 'Public'));

    testWidgets('newest at the bottom; a hidden message keeps its row and cannot be reported', (t) async {
      phone(t);
      await t.pumpWidget(reader());
      await settle(t);
      expect(t.getTopLeft(find.text('message number 3')).dy, greaterThan(t.getTopLeft(find.text('message number 1')).dy));
      expect(find.byKey(const Key('channel-msg-hidden-m0002')), findsOneWidget);
      expect(find.text('7 hops · heard by 3 observers'), findsNWidgets(3), reason: 'short and plain; the signal figure is on the actions sheet');
      expect(find.byKey(const Key('channel-readonly')), findsOneWidget, reason: 'the header says it is a reader');
      expect(find.byKey(const Key('channel-start')), findsOneWidget);
      expect(t.getSize(find.byKey(const Key('channel-msg-more-m0003'))), const Size(44, 44));
      expect(t.takeException(), isNull);

      await t.tap(find.byKey(const Key('channel-msg-more-m0002')));
      await settle(t);
      expect(find.byKey(const Key('channel-msg-open-packet')), findsOneWidget);
      expect(find.byKey(const Key('channel-msg-report')), findsNothing);
      expect(find.byKey(const Key('channel-msg-copy')), findsNothing);
    });

    testWidgets('polls every 20 s and adds a new message in place while at the bottom', (t) async {
      phone(t);
      await t.pumpWidget(reader());
      await settle(t);
      expect(s.polls, 0);
      s.newer = [msg(4)];
      await t.pump(channelPollEvery);
      await settle(t);
      expect(s.polls, 1);
      expect(find.text('message number 4'), findsOneWidget);
      expect(find.byKey(const Key('channel-new-pill')), findsNothing);
      // the next poll uses the cursor the last one gave
      await t.pump(channelPollEvery);
      await settle(t);
      expect(s.at('/v1/channels/public/messages').last.url.queryParameters['cursor'], 'NEWER1');
    });

    testWidgets('scrolled up: new messages wait behind an "N new" pill and the list does not move', (t) async {
      phone(t);
      s.first = [for (var i = 60; i >= 11; i--) msg(i)];
      await t.pumpWidget(reader());
      await settle(t);
      await t.drag(find.byKey(const Key('channel-messages')), const Offset(0, 500));
      await settle(t);
      final list = t.widget<ListView>(find.byKey(const Key('channel-messages')));
      final before = list.controller!.position.pixels;
      expect(before, greaterThan(48));
      final anchor = find.textContaining('Sender ').first;
      final anchorText = t.widget<Text>(anchor).data;
      final dy = t.getTopLeft(anchor).dy;

      s.newer = [msg(62), msg(61)];
      await t.pump(channelPollEvery);
      await settle(t);
      expect(find.text('2 new'), findsOneWidget);
      expect(list.controller!.position.pixels, before);
      expect(t.getTopLeft(find.text(anchorText!)).dy, dy, reason: 'nothing moved under the finger');
      expect(t.getSize(find.byKey(const Key('channel-new-pill'))).height, greaterThanOrEqualTo(44));

      await t.tap(find.byKey(const Key('channel-new-pill')));
      await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
      expect(find.byKey(const Key('channel-new-pill')), findsNothing);
      expect(find.text('message number 62'), findsOneWidget);
      expect(list.controller!.position.pixels, 0);
    });

    testWidgets('no poll while another route is on top or the app is in the background; Refresh asks at once', (t) async {
      phone(t);
      await t.pumpWidget(reader());
      await settle(t);
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('on top'))));
      await settle(t);
      await t.pump(channelPollEvery);
      await t.pump(channelPollEvery);
      expect(s.polls, 0);
      nav.pop();
      await settle(t);

      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump(channelPollEvery);
      expect(s.polls, 0);
      s.newer = [msg(4)];
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(t);
      expect(s.polls, 1, reason: 'catches up when it comes back to the front');
      expect(find.text('message number 4'), findsOneWidget);

      s.newer = [msg(5)];
      await t.tap(find.byKey(const Key('channel-refresh')));
      await settle(t);
      expect(s.polls, 2);
      expect(find.text('message number 5'), findsOneWidget);
    });

    testWidgets('no poll while its tab or section is not showing', (t) async {
      phone(t);
      var showing = false;
      late StateSetter set;
      await t.pumpWidget(app(Scaffold(
        body: StatefulBuilder(builder: (c, s) {
          set = s;
          return TickerMode(enabled: showing, child: ChannelReaderView(baseUrl: base, regionSlug: 'cmh', channelId: 'public', title: 'Public', onBack: () {}));
        }),
      )));
      await settle(t);
      await t.pump(channelPollEvery);
      await t.pump(channelPollEvery);
      expect(s.polls, 0);
      set(() => showing = true);
      await settle(t);
      await t.pump(channelPollEvery);
      await settle(t);
      expect(s.polls, 1);
    });

    testWidgets('the top of the list loads the older page', (t) async {
      phone(t);
      s.first = [for (var i = 60; i >= 11; i--) msg(i)];
      s.older = [for (var i = 10; i >= 1; i--) msg(i)];
      await t.pumpWidget(reader());
      await settle(t);
      final list = t.widget<ListView>(find.byKey(const Key('channel-messages')));
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await settle(t);
      expect(s.at('/v1/channels/public/messages').any((r) => r.url.queryParameters['cursor'] == 'OLDER'), isTrue);
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await settle(t);
      expect(find.text('message number 1'), findsOneWidget);
      expect(find.byKey(const Key('channel-start')), findsOneWidget);
    });

    testWidgets('an empty channel in a region with no feed says so; a private channel link explains itself', (t) async {
      phone(t);
      s.first = [];
      s.noFeed = true;
      await t.pumpWidget(reader());
      await settle(t);
      expect(find.byKey(const Key('no-packet-feed')), findsOneWidget);

      await t.pumpWidget(app(const ChannelReaderScreen(key: Key('p'), baseUrl: base, regionSlug: 'cmh', channelId: 'enc:fc')));
      await settle(t);
      expect(find.byKey(const Key('channel-private')), findsOneWidget);
      expect(find.text('Private channel fc'), findsOneWidget);
      expect(s.at('/v1/channels/enc%3Afc/messages'), isEmpty);
    });
  });

  group('report', () {
    Future<void> openReport(WidgetTester t) async {
      phone(t);
      await t.pumpWidget(app(const ChannelReaderScreen(baseUrl: base, regionSlug: 'cmh', channelId: 'public', title: 'Public')));
      await settle(t);
      await t.tap(find.byKey(const Key('channel-msg-more-m0003')));
      await settle(t);
      await t.tap(find.byKey(const Key('channel-msg-report')));
      await settle(t);
    }

    testWidgets('says what a report does, sends {reason, note} once and shows the receipt', (t) async {
      await openReport(t);
      expect(find.byKey(const Key('report-explainer')), findsOneWidget);
      expect(find.textContaining('you do not need an account'), findsOneWidget);
      await t.tap(find.byKey(const Key('report-reason-harassment')));
      await t.enterText(find.byKey(const Key('report-note')), 'rude');
      await t.ensureVisible(find.byKey(const Key('report-send')));
      await t.tap(find.byKey(const Key('report-send')));
      await settle(t);
      expect(find.byKey(const Key('report-received')), findsOneWidget);
      expect(find.text('Receipt: rep_01JD6A0B1C'), findsOneWidget);
      final req = s.seen.lastWhere((r) => r.method == 'POST');
      expect(req.url.path, '/v1/messages/m0003/report');
      expect(jsonDecode(req.body), {'reason': 'harassment', 'note': 'rude'});
      expect(s.reports, 1);
      expect(t.takeException(), isNull);
    });

    testWidgets('rate limited: says when to try again, nothing retried by itself', (t) async {
      s.reportStatus = 429;
      await openReport(t);
      await t.ensureVisible(find.byKey(const Key('report-send')));
      await t.tap(find.byKey(const Key('report-send')));
      await settle(t);
      expect(find.text('Too many reports from this connection. Try again in 1200 s.'), findsOneWidget);
      await t.pump(const Duration(minutes: 1));
      expect(s.reports, 1);
    });

    testWidgets('a server without reports says nothing was sent', (t) async {
      s.reportStatus = 404;
      await openReport(t);
      await t.ensureVisible(find.byKey(const Key('report-send')));
      await t.tap(find.byKey(const Key('report-send')));
      await settle(t);
      expect(find.text('Reports are not switched on yet. Nothing was sent.'), findsOneWidget);
    });
  });

  group('build 76', () {
    testWidgets('channel list: an intro line says what a tap does; several private channels sit in one closed row', (t) async {
      phone(t);
      s.channelRows = [
        ...channels,
        {...channels[1], 'id': 'enc:aa'},
        {...channels[1], 'id': 'enc:bb'},
      ];
      await t.pumpWidget(app(const Scaffold(body: ChannelsSection(baseUrl: base, regionSlug: 'cmh'))));
      await settle(t);
      expect(find.byKey(const Key('channels-intro')), findsOneWidget);
      expect(find.text('Private channels (3)'), findsOneWidget);
      expect(find.byKey(const Key('channel-row-enc:fc')), findsNothing, reason: 'closed until asked for');
      expect(find.byKey(const Key('channel-row-public')), findsOneWidget);
      await t.tap(find.text('Private channels (3)'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('channel-row-enc:fc')), findsOneWidget);
      expect(find.byKey(const Key('channel-private-enc:aa')), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('search: the count is on top, the clear button shows at once, and a one-channel search with no hit offers every channel', (t) async {
      phone(t);
      await t.pumpWidget(app(const ChannelSearchScreen(baseUrl: base, regionSlug: 'cmh', debounce: Duration(milliseconds: 10))));
      await settle(t);
      await t.enterText(find.byKey(const Key('channel-search-field')), 'test');
      await t.pump();
      expect(find.byKey(const Key('channel-search-clear')), findsOneWidget);
      await settle(t);
      expect(t.widget<Text>(find.byKey(const Key('channel-search-count'))).data, startsWith('1 result, newest first.'));
      expect(t.getTopLeft(find.byKey(const Key('channel-search-count'))).dy, lessThan(t.getTopLeft(find.byKey(const Key('channel-msg-m0007'))).dy));
    });

    testWidgets('search: an error has Try again', (t) async {
      phone(t);
      var asked = 0;
      channelsApiFactory = (b) => ChannelsApi(b,
          client: MockClient((r) async {
            if (r.url.path == '/v1/messages/search') asked++;
            return js({'error': {'code': 'internal', 'message': 'Search is busy.', 'requestId': 'r'}}, 500);
          }));
      await t.pumpWidget(app(const ChannelSearchScreen(baseUrl: base, regionSlug: 'cmh', debounce: Duration(milliseconds: 10))));
      await settle(t);
      await t.enterText(find.byKey(const Key('channel-search-field')), 'test');
      await settle(t);
      expect(find.byKey(const Key('channel-search-error')), findsOneWidget);
      final before = asked;
      await t.tap(find.byKey(const Key('channel-search-retry')));
      await settle(t);
      expect(asked, greaterThan(before), reason: 'Try again asks the server again');
    });
  });

  group('search', () {
    testWidgets('nothing is sent under 2 characters; a hit shows its channel and opens it', (t) async {
      phone(t);
      await t.pumpWidget(app(const ChannelSearchScreen(baseUrl: base, regionSlug: 'cmh', debounce: Duration(milliseconds: 10))));
      await settle(t);
      expect(find.byKey(const Key('channel-search-hint')), findsOneWidget);
      await t.enterText(find.byKey(const Key('channel-search-field')), 't');
      await settle(t);
      expect(s.at('/v1/messages/search'), isEmpty);

      await t.enterText(find.byKey(const Key('channel-search-field')), 'test');
      await settle(t);
      expect(s.at('/v1/messages/search').single.url.queryParameters, {'q': 'test', 'limit': '30'});
      expect(find.text('in #test'), findsOneWidget);
      final rich = t.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'a Test of things'));
      final bold = <String>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.w700) bold.add(span.text ?? '');
        return true;
      });
      expect(bold, ['Test']);
      expect(t.takeException(), isNull);

      await t.tap(find.byKey(const Key('channel-msg-more-m0007')));
      await settle(t);
      await t.tap(find.byKey(const Key('channel-msg-open-channel')));
      await settle(t);
      expect(find.byType(ChannelReaderScreen), findsOneWidget);
      expect(find.text('#test'), findsOneWidget);
    });

    testWidgets('inside a channel the search is narrowed to it', (t) async {
      phone(t);
      await t.pumpWidget(app(const ChannelSearchScreen(baseUrl: base, regionSlug: 'cmh', channelId: 'public', channelName: 'Public', debounce: Duration(milliseconds: 10))));
      await settle(t);
      await t.enterText(find.byKey(const Key('channel-search-field')), 'test');
      await settle(t);
      expect(s.at('/v1/messages/search').single.url.queryParameters['channel'], 'public');
      expect(find.textContaining('in #test'), findsNothing);
    });
  });
}
