// Contract items 9 and 10 in the app: region-rf `bucket`/`days`/`window` parsing and request URLs, one stored copy per
// window in the ETag cache (offline shows the right window), and `snrDaily` parsing and the 30-day trend numbers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/region_rf_api.dart';
import 'package:meshsonar/core/repeater_detail_api.dart';
import 'package:meshsonar/core/snr_trend.dart';

import 'region_rf_growth_api_test.dart' as fx;

Map<String, dynamic> windowed(String bucket, {int obsPoints = 3}) => {
      ...fx.rfBody(),
      'bucket': bucket,
      'window': {'from': '2026-09-25T00:00:00.000Z', 'to': '2026-10-25T00:00:00.000Z', 'histogramFrom': '2026-09-25T00:00:00.000Z'},
    };

DailySnr d(int day, double? mean, int n) => DailySnr(DateTime.utc(2026, 10, day), mean, n);

void main() {
  group('region-rf window', () {
    test('choices and URLs: plain without a window, bucket+days with one', () {
      final api = RegionRfApi('https://cmh.meshsonar.com');
      expect(api.uri.toString(), 'https://cmh.meshsonar.com/api/cmh/region-rf');
      expect(api.uriFor(RfWindowChoice.all[0]).toString(), 'https://cmh.meshsonar.com/api/cmh/region-rf?bucket=hour&days=1');
      expect(api.uriFor(RfWindowChoice.all[1]).query, 'bucket=hour&days=7');
      expect(api.uriFor(RfWindowChoice.all[2]).query, 'bucket=day&days=30');
      expect(api.uriFor(RfWindowChoice.all[3]).query, 'bucket=day&days=90');
      expect([for (final c in RfWindowChoice.all) c.id], ['24h', '7d', '30d', '90d']);
    });

    test('parses bucket and window; an older answer has neither; garbage window is ignored', () {
      final r = RegionRf.parse(windowed('day'));
      expect(r.daily, isTrue);
      expect(r.window!.from, DateTime.utc(2026, 9, 25));
      expect(r.window!.to, DateTime.utc(2026, 10, 25));
      final old = RegionRf.parse(fx.rfBody());
      expect(old.bucket, isNull);
      expect(old.window, isNull);
      expect(old.daily, isFalse);
      final bad = RegionRf.parse({...fx.rfBody(), 'bucket': 'week', 'window': {'from': 'x', 'to': 5}});
      expect(bad.bucket, isNull);
      expect(bad.window, isNull);
      final noHist = RegionRf.parse({
        ...fx.rfBody(),
        'window': {'from': '2026-10-24T00:00:00Z', 'to': '2026-10-25T00:00:00Z'}
      });
      expect(noHist.window!.histogramFrom, DateTime.utc(2026, 10, 24));
    });

    test('silent observers use the window length of a bucket', () {
      final r = RegionRf.parse(windowed('day'));
      final to = r.window!.to;
      // INNO-OB-2 last spoke 2026-10-21: more than 2 days before 2026-10-25.
      expect(r.silentObservers(to, after: const Duration(days: 2)).map((o) => o.name), ['INNO-OB-2']);
      expect(r.silentObservers(DateTime.utc(2026, 10, 22), after: const Duration(days: 2)), isEmpty);
    });

    test('each window has its own stored copy: offline shows the window that was asked', () async {
      final dir = Directory.systemTemp.createTempSync('rfwin');
      addTearDown(() => dir.deleteSync(recursive: true));
      var down = false;
      final asked = <String>[];
      final client = EtagClient(
        MockClient((req) async {
          if (down) throw const SocketException('down');
          asked.add(req.url.query);
          final b = windowed(req.url.queryParameters['bucket'] ?? 'hour');
          b['marker'] = req.url.query;
          return http.Response(jsonEncode(b), 200, headers: {'etag': '"${req.url.query}"'});
        }),
        RegionCache(dir, clock: () => DateTime.utc(2026, 10, 25)),
        staleAfter: const Duration(milliseconds: 200),
      );
      final api = RegionRfApi('https://cmh.meshsonar.com', client: client);
      expect((await api.fetch(RfWindowChoice.all[1])).body, contains('bucket=hour&days=7'));
      expect((await api.fetch(RfWindowChoice.all[2])).body, contains('bucket=day&days=30'));
      down = true;
      final seven = await api.fetch(RfWindowChoice.all[1]);
      final thirty = await api.fetch(RfWindowChoice.all[2]);
      expect(seven.offlineAsOf, isNotNull);
      expect(seven.body, contains('bucket=hour&days=7'));
      expect(thirty.body, contains('bucket=day&days=30'));
      expect((await api.fetch(RfWindowChoice.all[3])).ok, isFalse); // never fetched: nothing to show offline
      expect(asked, hasLength(2));
    });

    test('a 400 carries its status', () async {
      final api = RegionRfApi('https://cmh.meshsonar.com', client: MockClient((_) async => http.Response('{"error":"days must be 1..90"}', 400)));
      final r = await api.fetch(RfWindowChoice.all[3]);
      expect(r.ok, isFalse);
      expect(r.status, 400);
      expect(r.error, 'days must be 1..90');
    });
  });

  group('site-config capability flags', () {
    test('rfWindow and snrDaily read from capabilities; absent = off', () {
      final on = SiteConfig(region: const RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: parseCapabilities({'rfWindow': true, 'snrDaily': true}));
      expect(on.rfWindow && on.snrDaily, isTrue);
      final off = SiteConfig(region: const RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: parseCapabilities({'rfWindow': false}));
      expect(off.rfWindow || off.snrDaily, isFalse);
    });
  });

  group('snrDaily parser', () {
    Map<String, dynamic> body(Object? daily) => {
          'status': {'state': 'ready'},
          'row': null,
          'snrDaily': ?daily,
        };

    test('absent field = null (not shown), never an empty list of zeros', () {
      expect(RepeaterDetailData.parse(body(null)).snrDaily, isNull);
      expect(RepeaterDetailData.parse(body('x')).snrDaily, isNull);
    });

    test('sorted, deduped, garbage skipped, a mean without readings is a gap, unknown stays null', () {
      final r = RepeaterDetailData.parse(body([
        {'day': '2026-10-24', 'meanDb': 4.5, 'n': 3},
        {'day': '2026-10-22', 'meanDb': null, 'n': 0},
        {'day': '2026-10-23', 'meanDb': 9, 'n': 0}, // no readings behind it
        {'day': 'Oct 21', 'meanDb': 1, 'n': 1},
        {'day': '2026-10-20', 'meanDb': 'x', 'n': 2},
        7,
        {'meanDb': 2, 'n': 1},
        {'day': '2026-10-24', 'meanDb': 5.5, 'n': 4}, // duplicate: the later row wins
      ]));
      final s = r.snrDaily!;
      expect([for (final x in s) x.day.day], [20, 22, 23, 24]);
      expect(s[0].meanDb, isNull);
      expect(s[2].meanDb, isNull);
      expect(s.last.meanDb, 5.5);
      expect(s.last.n, 4);
    });

    test('keeps at most 30 days (the newest)', () {
      final rows = [for (var i = 0; i < 40; i++) {'day': DateTime.utc(2026, 9, 1).add(Duration(days: i)).toIso8601String().substring(0, 10), 'meanDb': 1.0, 'n': 1}];
      final s = RepeaterDetailData.parse(body(rows)).snrDaily!;
      expect(s, hasLength(30));
      expect(s.last.day, DateTime.utc(2026, 10, 10));
    });
  });

  group('SnrTrend', () {
    test('no data', () {
      final t = SnrTrend.of([d(1, null, 0), d(2, null, 0)]);
      expect(t.hasData, isFalse);
      expect(t.sentence, isNull);
      expect(SnrTrend.of(const []).hasData, isFalse);
    });

    test('summary numbers; no sentence under 7 days with readings', () {
      final t = SnrTrend.of([d(1, 2, 4), d(2, null, 0), d(3, 6, 1), d(4, -1, 2)]);
      expect(t.daysWithData, 3);
      expect(t.days, 4);
      expect(t.readings, 7);
      expect(t.minDb, -1);
      expect(t.maxDb, 6);
      expect(t.latest!.day.day, 4);
      expect(t.sentence, isNull);
    });

    test('trend: stronger, weaker, steady, with the compared window named', () {
      List<DailySnr> days(List<double> v) => [for (var i = 0; i < v.length; i++) d(i + 1, v[i], 2)];
      final up = SnrTrend.of(days([0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3]));
      expect(up.sentence, 'The last 7 days with readings against the 7 before: about 3.0 dB stronger.');
      final down = SnrTrend.of(days([9, 5, 5, 5, 2.5, 2.5, 2.5]));
      expect(down.compareDays, 3);
      expect(down.sentence, contains('about 2.5 dB weaker'));
      final flat = SnrTrend.of(days([4, 4, 4, 4.4, 4.2, 3.9, 4.1]));
      expect(flat.sentence, endsWith('steady within 1 dB.'));
    });
  });
}
