// PlanApi: the Master Planner client methods behind the offline fallback, and plan-link's on-device fallback.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/plan_api.dart';
import 'package:meshsonar/core/plan/plan_store.dart';

Map<String, dynamic> _fx(String name) => jsonDecode(File('test/fixtures/plan_native/server/$name').readAsStringSync()) as Map<String, dynamic>;

/// A CmatClient whose planner calls do what the test says.
class _Client implements CmatClient {
  Object? Function()? onLink, onVerify, onSuggest;
  int calls = 0;
  _Client({this.onLink, this.onVerify, this.onSuggest});

  Future<T> _run<T>(Object? Function()? f, T Function(Map<String, dynamic>) parse) async {
    calls++;
    final r = f == null ? throw const CmatException('not supported by this client') : f();
    if (r is Exception) throw r;
    return parse(r as Map<String, dynamic>);
  }

  @override
  Future<PlanLinkResult> planLink(PlanLinkRequest request) => _run(onLink, PlanLinkResult.parse);
  @override
  Future<PlanVerifyResult> planVerify(PlanVerifyRequest request) => _run(onVerify, PlanVerifyResult.parse);
  @override
  Future<PlanSuggestResult> planSuggest(PlanSuggestRequest request) => _run(onSuggest, PlanSuggestResult.parse);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const req = PlanLinkRequest(a: PlanPoint(37.1, -80.2), b: PlanPoint(37.12, -80.14), haM: 10, hbM: 1.5);

ScoreLinkApi _score(PlanStore store, {bool up = true, int? status}) => ScoreLinkApi('https://cmh.example', store,
    client: () => MockClient((r) async {
          if (!up) throw const SocketException('offline');
          if (status != null) return http.Response('{"error":"nope"}', status);
          final res = _fx('plan-link.estimate.response.json');
          return http.Response(jsonEncode({'km': res['km'], 'profile': res['profile'], 'source': 'AWS Terrain Tiles (Terrarium)'}), 200);
        }));

void main() {
  late PlanStore store;
  setUp(() => store = PlanStore());
  final now = DateTime.utc(2026, 11, 15, 20);

  test('a good answer is returned and stored; offline it comes back from the store flagged', () async {
    final c = _Client(onLink: () => _fx('plan-link.measured.response.json'));
    final api = PlanApi(c, store, clock: () => now);
    final live = await api.link(req);
    expect(live.ok, isTrue);
    expect(live.offlineAsOf, isNull);
    expect(live.at, now);
    expect(live.data!.measured!.echoes, 41);
    c.onLink = () => const CmatException('network error: down');
    final off = await api.link(req);
    expect(off.ok, isTrue);
    expect(off.offlineAsOf, isNotNull);
    expect(off.onDevice, isFalse);
    expect(off.data!.verdict, live.data!.verdict);
    expect(off.data!.marginDb, live.data!.marginDb);
    expect(off.data!.measured!.meanSnr, 2.5);
    expect(off.data!.provenance.confidence, PlanConfidenceLevel.measured);
    expect(off.data!.ridge!.at, live.data!.ridge!.at);
    // A different request has no stored copy.
    final other = await api.link(const PlanLinkRequest(a: PlanPoint(1, 1), b: PlanPoint(1, 1.1)));
    expect(other.ok, isFalse);
    expect(other.unavailable, isTrue);
    expect(other.error, 'No connection to the server.');
  });

  test('server errors: 5xx and 501 fall back, 4xx and 429 are sentences that never fall back', () async {
    final c = _Client(onSuggest: () => _fx('plan-suggest.response.json'));
    final api = PlanApi(c, store);
    const s = PlanSuggestRequest(bounds: PlanBounds(south: 37, north: 37.5, west: -80.3, east: -79.8));
    expect((await api.suggest(s)).ok, isTrue);
    c.onSuggest = () => const CmatException('boom', status: 503);
    expect((await api.suggest(s)).offlineAsOf, isNotNull);
    c.onSuggest = () => const CmatException('not built', status: 501);
    expect((await api.suggest(s)).offlineAsOf, isNotNull);
    c.onSuggest = () => const CmatException('bounds must be inside the region', status: 400);
    final bad = await api.suggest(s);
    expect(bad.ok, isFalse);
    expect(bad.error, 'bounds must be inside the region');
    expect(bad.unavailable, isFalse);
    c.onSuggest = () => const CmatException('slow down', status: 429, retryAfterSec: 20);
    expect((await api.suggest(s)).error, 'Too many requests from this connection. Try again in 20 s.');
    c.onSuggest = () => const CmatException('timed out talking to x');
    final fresh = PlanApi(c, PlanStore());
    expect((await fresh.suggest(s)).error, 'The server took too long to answer.');
    c.onSuggest = () => const CmatException('not built', status: 501);
    expect((await fresh.suggest(s)).error, 'This server does not offer the planner yet.');
    c.onSuggest = () => const FormatException('x');
    expect((await fresh.suggest(s)).error, 'The server sent something unreadable.');
  });

  test('stored suggest and verify answers read back the same', () async {
    final c = _Client(onSuggest: () => _fx('plan-suggest.response.json'), onVerify: () => _fx('plan-verify.site.response.json'));
    final api = PlanApi(c, store);
    const s = PlanSuggestRequest(bounds: PlanBounds(south: 37, north: 37.5, west: -80.3, east: -79.8), goal: PlanGoal.coverage);
    const v = PlanVerifyRequest(site: PlanPoint(37.27, -79.94));
    final s1 = (await api.suggest(s)).data!, v1 = (await api.verify(v)).data!;
    c.onSuggest = c.onVerify = () => const CmatException('network error');
    final s2 = (await api.suggest(s)).data!, v2 = (await api.verify(v)).data!;
    expect(s2.sites.length, s1.sites.length);
    for (var i = 0; i < s1.sites.length; i++) {
      final a = s1.sites[i], b = s2.sites[i];
      expect((b.id, b.at, b.score, b.reason, b.kind, b.mount, b.deadZoneDrives), (a.id, a.at, a.score, a.reason, a.kind, a.mount, a.deadZoneDrives));
      expect(b.gain.newLinks.map((l) => l.key), a.gain.newLinks.map((l) => l.key));
      expect(b.gain.redundancy, a.gain.redundancy);
    }
    expect(s2.pool, s1.pool);
    expect(s2.provenance.confidence, s1.provenance.confidence);
    expect(v2.coveredKm2, v1.coveredKm2);
    expect(v2.newAreaKm2, v1.newAreaKm2);
    expect(v2.raw['footprint'], isNotNull, reason: 'the footprint layer still draws offline');
  });

  test('verifyMany verifies the top 5 one after the other', () async {
    var n = 0;
    final c = _Client(onVerify: () {
      n++;
      return _fx('plan-verify.site.response.json');
    });
    final out = await PlanApi(c, store).verifyMany([for (var i = 0; i < 8; i++) PlanVerifyRequest(site: PlanPoint(37 + i / 100, -80))]);
    expect(out.length, 5);
    expect(n, 5);
    expect(out.every((r) => r.ok), isTrue);
  });

  test('no planner on the server: plan-link is judged on the phone over score-link\'s profile', () async {
    final c = _Client(onLink: () => const CmatException('not built', status: 501));
    final api = PlanApi(c, store, scoreLink: _score(store));
    final r = await api.link(req);
    expect(r.ok, isTrue);
    expect(r.onDevice, isTrue);
    expect(r.data!.provenance.model, contains('on this phone'));
    expect(r.data!.verdict, PlanVerdict.unlikely, reason: 'the same verdict the server gave this pair');
    expect(r.data!.provenance.terrain, 'AWS Terrain Tiles (Terrarium)');
  });

  test('a client without the planner methods (older fake) also falls back to the phone', () async {
    final r = await PlanApi(_Client(), store, scoreLink: _score(store)).link(req);
    expect(r.onDevice, isTrue);
  });

  test('offline with only a stored score-link profile: still judged on the phone, flagged offline', () async {
    final c = _Client(onLink: () => const CmatException('not built', status: 501));
    await PlanApi(c, store, scoreLink: _score(store)).link(req); // stores the profile
    c.onLink = () => const CmatException('network error');
    final r = await PlanApi(c, store, scoreLink: _score(store, up: false)).link(const PlanLinkRequest(a: PlanPoint(37.1, -80.2), b: PlanPoint(37.12, -80.14), haM: 30, hbM: 8));
    expect(r.ok, isTrue);
    expect(r.onDevice, isTrue);
    expect(r.offlineAsOf, isNotNull);
  });

  test('a 4xx from plan-link is the server\'s verdict on the input: no on-device second guess', () async {
    final c = _Client(onLink: () => const CmatException('points more than 60 km apart', status: 400));
    final r = await PlanApi(c, store, scoreLink: _score(store)).link(req);
    expect(r.ok, isFalse);
    expect(r.error, 'points more than 60 km apart');
  });

  test('profile(): score-link first, else plan-link\'s own profile', () async {
    final c = _Client(onLink: () => _fx('plan-link.estimate.response.json'));
    final viaScore = await PlanApi(c, store, scoreLink: _score(store)).profile(req.a, req.b);
    expect(viaScore.data!.source, 'AWS Terrain Tiles (Terrarium)');
    expect(c.calls, 0);
    final viaLink = await PlanApi(c, PlanStore(), scoreLink: _score(PlanStore(), status: 404)).profile(req.a, req.b);
    expect(viaLink.ok, isTrue);
    expect(viaLink.data!.groundM.length, 101);
    expect(c.calls, 1);
  });

  test('cache keys are stable, file-name safe and differ by every field (radio included)', () {
    final k1 = PlanApi.linkKey(req);
    expect(k1, PlanApi.linkKey(const PlanLinkRequest(a: PlanPoint(37.1, -80.2), b: PlanPoint(37.12, -80.14), haM: 10, hbM: 1.5)));
    expect(RegExp(r'^plink_[0-9a-f]{16}$').hasMatch(k1), isTrue);
    final eu = PlanApi.linkKey(const PlanLinkRequest(
        a: PlanPoint(37.1, -80.2), b: PlanPoint(37.12, -80.14), haM: 10, hbM: 1.5, radio: PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8)));
    expect(eu, isNot(k1));
    expect(planKeyHash(''), 'cbf29ce484222325');
    expect(planKeyHash('a'), 'af63dc4c8601ec8c');
  });
}
