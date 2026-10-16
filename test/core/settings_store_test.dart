import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('meshsonar_settings_'));
  tearDown(() async => tmp.delete(recursive: true));

  test('missing file gives defaults', () async {
    final s = await FileSettingsStore(File(p.join(tmp.path, 'nope', 'settings.json'))).load();
    expect(s.toJson(), const Settings().toJson());
  });

  test('corrupt file gives defaults', () async {
    final f = File(p.join(tmp.path, 'settings.json'))..writeAsStringSync('{"server_url": "x", trunc');
    expect((await FileSettingsStore(f).load()).toJson(), const Settings().toJson());
    f.writeAsStringSync('[1,2,3]');
    expect((await FileSettingsStore(f).load()).toJson(), const Settings().toJson());
    f.writeAsStringSync('{"interval_sec": "thirty"}');
    expect((await FileSettingsStore(f).load()).toJson(), const Settings().toJson());
  });

  test('save then load round-trips, creating the folder, no temp file left', () async {
    final f = File(p.join(tmp.path, 'a', 'b', 'settings.json'));
    final store = FileSettingsStore(f);
    const s = Settings(
      serverUrl: 'https://example.org',
      driverKey: 'ms_abcdefghijklmnopqrstuvwxyz',
      keyStatus: DriverKeyStatus.approved,
      display: 'KE4BFI',
      channel: '#test',
      intervalSec: 15,
      minDistanceM: 50,
      antenna: Antenna(type: 'mag-mount', gainDbi: 3, heightM: 1.5),
      autoSync: false,
    );
    await store.save(s);
    expect((await FileSettingsStore(f).load()).toJson(), s.toJson());
    expect(File('${f.path}.tmp').existsSync(), isFalse);
  });

  test('rapid saves are serialized; last one wins', () async {
    final f = File(p.join(tmp.path, 'settings.json'));
    final store = FileSettingsStore(f);
    await Future.wait([for (var i = 1; i <= 20; i++) store.save(Settings(intervalSec: i))]);
    expect((await store.load()).intervalSec, 20);
  });
}
