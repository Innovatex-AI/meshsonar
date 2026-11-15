// MQTT feed slots in settings.json and the broker presets (lib/core/mqtt_contract.dart; observer-everywhere-mqtt-plan
// sections 3.3 and 6): at most 10 slots, all off unless turned on, never a password in the file; presets parse one by one.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

void main() {
  test('a slot round-trips; defaults are not written; it starts off', () {
    const s = MqttSlotSettings(id: 'slot-1', name: 'Waev', host: 'mqtt.waev.app', wsPath: '/mqtt', iata: 'CMH');
    expect(s.enabled, isFalse);
    final j = s.toJson();
    expect(j, {'id': 'slot-1', 'name': 'Waev', 'host': 'mqtt.waev.app', 'port': 443, 'path': '/mqtt', 'iata': 'CMH', 'auth': 'jwt'});
    expect(MqttSlotSettings.tryParse(jsonDecode(jsonEncode(j))), s);
    expect(s.secretRef, 'mqtt.slot-1');
    final pw = s.copyWith(auth: MqttAuth.password, username: 'ann', enabled: true);
    expect(MqttSlotSettings.tryParse(pw.toJson()), pw);
    expect(jsonEncode(pw.toJson()).contains('password":'), isFalse, reason: 'the auth kind is written, never a password');
  });

  test('odd slot values take their defaults; a slot without an id or host is dropped', () {
    final s = MqttSlotSettings.tryParse({'id': 'x', 'host': 'h', 'port': 70000, 'path': 'mqtt', 'ttl_sec': 5, 'auth': 'nope'})!;
    expect(s.port, 443);
    expect(s.wsPath, '/');
    expect(s.ttlSec, MqttSlotSettings.defaultTtlSec);
    expect(s.auth, MqttAuth.jwt);
    expect(s.name, 'h');
    expect(MqttSlotSettings.tryParse({'host': 'h'}), isNull);
    expect(MqttSlotSettings.tryParse({'id': 'x'}), isNull);
    expect(MqttSlotSettings.tryParse('slot'), isNull);
  });

  test('Settings: slots are written only when there are some, at most 10, ids unique', () {
    expect(const Settings().toJson().containsKey('mqtt_slots'), isFalse, reason: 'a default settings.json is unchanged');
    final many = [for (var i = 0; i < 12; i++) MqttSlotSettings(id: 'slot-${i % 11}', name: 'n$i', host: 'h$i')];
    final s = const Settings().copyWith(mqttSlots: many);
    expect(s.mqttSlots, hasLength(Settings.maxMqttSlots));
    expect(s.mqttSlots.first.name, 'n0', reason: 'the first slot with an id wins');
    final back = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.mqttSlots, s.mqttSlots);
    final damaged = Settings.fromJson({
      'mqtt_slots': [
        {'id': 'a', 'host': 'h'},
        'junk',
        {'host': 'no id'},
      ],
    });
    expect(damaged.mqttSlots.map((m) => m.id), ['a']);
    expect(back.copyWith(units: back.units).mqttSlots, s.mqttSlots, reason: 'copyWith keeps the slots');
  });

  test('presets: every field, skipped one by one, a preset makes an OFF slot', () {
    final l = MqttPresetList.parse({
      'v': 1,
      'asOf': '2026-11-15T00:00:00Z',
      'presets': [
        {
          'id': 'meshmapper',
          'name': 'MeshMapper',
          'host': 'mqtt.meshmapper.net',
          'port': 443,
          'path': '/mqtt',
          'auth': 'jwt',
          'region': 'US',
          'needsOperatorOk': true,
          'caution': 'This site may only want fixed observers.',
          'needsRealIata': true,
        },
        {'name': 'no id'},
      ],
    });
    expect(l.asOf, DateTime.utc(2026, 11, 15));
    expect(l.presets, hasLength(1));
    final p = l.presets.single;
    expect(p.needsOperatorOk, isTrue);
    expect(p.caution, isNotNull);
    expect(p.verified, isFalse);
    final slot = p.toSlot('slot-3', iata: 'CMH');
    expect(slot.enabled, isFalse);
    expect(slot.presetId, 'meshmapper');
    expect(slot.wsPath, '/mqtt');
    expect(() => MqttPresetList.parse({'v': 1}), throwsFormatException);
    expect(const MqttPresetFetch.notModified(etag: 'x').notModified, isTrue);
  });
}
