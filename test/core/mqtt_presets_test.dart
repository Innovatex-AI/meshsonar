// The MQTT preset store (lib/core/mqtt_presets.dart): the bundled asset, the saved server copy, refresh with ETag, and
// that nothing a server or a disk does can leave the picker without a list.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/mqtt_presets.dart';

const _asset = 'assets/mqtt/mqtt-presets.json';

String _bundled() => File(_asset).readAsStringSync();

class _Server {
  MqttPresetList? list;
  String? etag;
  Object? error;
  final List<String?> asks = [];
  Future<MqttPresetFetch> fetch({String? ifNoneMatch}) async {
    asks.add(ifNoneMatch);
    if (error != null) throw error!;
    if (ifNoneMatch != null && ifNoneMatch == etag) return MqttPresetFetch.notModified(etag: etag);
    return MqttPresetFetch.fresh(list!, etag: etag);
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mqtt-presets'));
  tearDown(() => tmp.deleteSync(recursive: true));

  MqttPresetStore store(_Server srv, {DateTime Function()? clock, bool file = true}) => MqttPresetStore(
        loadBundled: () async => _bundled(),
        fetcher: () => srv.fetch,
        cacheFile: file ? File('${tmp.path}/mqtt/mqtt-presets.json') : null,
        clock: clock,
      );

  group('the bundled asset', () {
    test('is the server file: 35 presets, every one parses, three groups, no shared credentials or plain tcp', () {
      final raw = jsonDecode(_bundled()) as Map<String, dynamic>;
      final c = MqttPresetCatalog.parseFile(_bundled(), MqttPresetOrigin.bundled);
      expect((raw['presets'] as List).length, 35);
      expect(c.presets.length, 35, reason: 'every preset in the file parses');
      expect({for (final p in c.presets) c.groupOf(p)}, MqttPresetGroup.values.toSet());
      for (final p in raw['presets'] as List) {
        final m = p as Map;
        expect(m.containsKey('password'), isFalse, reason: '${m['id']}: no shared credentials are bundled');
        expect(m['auth'], isNot('password'), reason: '${m['id']}: password brokers are Custom only');
        expect(m['path'], startsWith('/'));
      }
      expect(c.presets.map((p) => p.id).toSet().length, 35, reason: 'ids are unique');
    });

    test('the bundled file carries no caution keys; a slot made from any preset is OFF', () {
      final c = MqttPresetCatalog.parseFile(_bundled(), MqttPresetOrigin.bundled);
      expect(_bundled(), isNot(contains('needsOperatorOk')));
      expect(_bundled(), isNot(contains('"caution"')));
      for (final p in c.presets) {
        expect(p.toSlot('slot-1').enabled, isFalse, reason: '${p.id}: all presets OFF until the person turns one on');
      }
    });

    test('pubspec lists the asset folder', () {
      expect(File('pubspec.yaml').readAsStringSync(), contains('    - assets/mqtt/\n'));
    });
  });

  group('search', () {
    final c = MqttPresetCatalog.parseFile(_bundled(), MqttPresetOrigin.bundled);
    test('matches name, host and region in any case, every word; empty = all', () {
      expect(c.search('').length, 35);
      expect(c.search('LETSMESH').map((p) => p.id), ['letsmesh-us', 'letsmesh-eu']);
      expect(c.search('letsmesh eu').map((p) => p.id), ['letsmesh-eu']);
      expect(c.search('okimesh.org').map((p) => p.id), ['okimesh-1', 'okimesh-2']);
      expect(c.search('canada nowhere'), isEmpty);
      expect(c.search('zzzz'), isEmpty);
    });
  });

  group('store', () {
    test('first launch, no network: the bundled copy; offline is said, nothing thrown', () async {
      final srv = _Server()..error = const CmatException('network error: no route');
      final s = store(srv);
      expect((await s.current()).origin, MqttPresetOrigin.bundled);
      expect(await s.isStale(), isTrue);
      expect(await s.refreshIfStale(), MqttPresetRefresh.offline);
      expect((await s.current()).presets.length, 35);
      expect(srv.asks, [null], reason: 'the bundled copy sends no ETag');
    });

    test('a 404 (endpoint not deployed) or a server error keeps the copy and says failed', () async {
      final srv = _Server()..error = const CmatException('server answered 404', status: 404);
      final s = store(srv);
      expect(await s.refreshIfStale(), MqttPresetRefresh.failed);
      expect((await s.current()).origin, MqttPresetOrigin.bundled);
      srv.error = StateError('anything else');
      expect(await s.refreshIfStale(force: true), MqttPresetRefresh.failed);
    });

    test('a fresh server list replaces it, keeps the groups by id, is saved, and is read back by a new store', () async {
      final now = DateTime.utc(2026, 11, 15, 12);
      final srv = _Server()
        ..etag = '"v2"'
        ..list = const MqttPresetList(version: 1, presets: [
          MqttPreset(id: 'letsmesh-us', name: 'LetsMesh US (new)', host: 'mqtt-us-v1.letsmesh.net'),
          MqttPreset(id: 'brand-new', name: 'Brand new', host: 'mqtt.new.example', region: 'US'),
        ]);
      final s = store(srv, clock: () => now);
      expect(await s.refreshIfStale(), MqttPresetRefresh.fresh);
      final c = await s.current();
      expect(c.origin, MqttPresetOrigin.server);
      expect(c.presets.map((p) => p.name), ['LetsMesh US (new)', 'Brand new']);
      expect(c.groupOf(c.byId('letsmesh-us')!), MqttPresetGroup.main, reason: 'group known from the bundled copy');
      expect(c.groupOf(c.byId('brand-new')!), MqttPresetGroup.more, reason: 'unknown id: the catch-all section');
      expect(await s.isStale(), isFalse);
      expect(await s.refreshIfStale(), isNull, reason: 'not stale: no request');

      final again = store(srv, clock: () => now.add(const Duration(hours: 7)));
      final saved = await again.current();
      expect(saved.origin, MqttPresetOrigin.saved);
      expect(saved.etag, '"v2"');
      expect(saved.presets.map((p) => p.id), ['letsmesh-us', 'brand-new']);
      expect(await again.isStale(), isTrue);
      expect(await again.refreshIfStale(), MqttPresetRefresh.notModified);
      expect(srv.asks.last, '"v2"', reason: 'conditional GET with the saved ETag');
      expect((await again.current()).origin, MqttPresetOrigin.server);
    });

    test('an empty server list never replaces a good one', () async {
      final srv = _Server()..list = const MqttPresetList(presets: []);
      final s = store(srv);
      expect(await s.refreshIfStale(), MqttPresetRefresh.failed);
      expect((await s.current()).presets.length, 35);
    });

    test('a damaged saved file is ignored (bundled copy); no cache file = memory only', () async {
      File('${tmp.path}/mqtt/mqtt-presets.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      expect((await store(_Server()).current()).origin, MqttPresetOrigin.bundled);
      final srv = _Server()..list = const MqttPresetList(presets: [MqttPreset(id: 'a', name: 'A', host: 'a.example')]);
      final mem = store(srv, file: false);
      expect(await mem.refreshIfStale(), MqttPresetRefresh.fresh);
      expect((await mem.current()).presets.single.id, 'a');
    });

    test('a broken bundled file is an error (the build test catches it), not a silent empty list', () async {
      final s = MqttPresetStore(loadBundled: () async => '[]', fetcher: () => _Server().fetch);
      expect(s.current(), throwsFormatException);
    });

    test('presetToJson is the inverse of MqttPreset.tryParse', () {
      final c = MqttPresetCatalog.parseFile(_bundled(), MqttPresetOrigin.bundled);
      for (final p in c.presets) {
        final back = MqttPreset.tryParse(presetToJson(p, c.groupOf(p)))!;
        expect(presetToJson(back, c.groupOf(p)), presetToJson(p, c.groupOf(p)), reason: p.id);
      }
    });
  });
}
