import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/data_categories.dart';
import 'package:meshsonar/core/drive_context.dart';

PingContext fullCtx() => PingContext(
      altM: 251.3,
      altAccM: 6,
      courseDeg: 87,
      courseAccDeg: 12,
      speedAccMps: 0.6,
      pressureHpa: 987.42,
      phoneBattPct: 64,
      radioBattMv: 3912,
    );

DriveSample fullRadio() => DriveSample(
      ts: DateTime.utc(2026, 10, 24, 20, 11),
      src: SampleSource.radio,
      battMv: 3912,
      uptimeS: 86011,
      errFlags: 0,
      queue: 0,
      txAirS: 412,
      rxAirS: 1930,
      lastRssi: -88,
      lastSnr: 6.25,
      noiseDbm: -104,
      pkts: const PacketCounters(
          recv: 18233, sent: 412, floodTx: 400, directTx: 12, floodRx: 17001, directRx: 1232, recvErrors: 37),
      storageUsedKb: 120,
      storageTotalKb: 1984,
      bleRssi: -61,
      mcuTempC: 31.5,
    );

DriveSample fullPhone() => DriveSample(
      ts: DateTime.utc(2026, 10, 24, 20, 11),
      src: SampleSource.phone,
      battPct: 64,
      battState: PhoneBatteryState.charging,
      lowPower: false,
      pressureHpa: 987.4,
    );

SessionContext fullSession() => SessionContext(
      device: DeviceDetails(os: 'ios', osVersion: '18.6', model: 'iPhone15,2', appBuild: '23'),
      companionExt:
          CompanionDetails(model: 'Heltec V4.3 OLED', fwCode: 8, fwBuild: '12-Oct-2026', maxTxDbm: 22, pathHashMode: 0),
    );

void main() {
  group('categories', () {
    test('ids are unique, every entry defaults ON (opt-out, Andy Oct 24 2026), packet_headers is the live one', () {
      final ids = dataCategories.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, [
        'packet_headers',
        'motion',
        'barometer',
        'phone_battery',
        'device',
        'radio_health',
        'radio_config',
        'weather',
      ]);
      expect(dataCategories.every((c) => c.defaultOn), isTrue);
      expect(dataCategories.where((c) => c.availability != CategoryAvailability.live).map((c) => c.id), ['weather']);
      expect(dataCategory('barometer')!.permission, 'motion');
      expect(dataCategory('nope'), isNull);
    });

    test('packet_headers wording matches the live disclosure: no message text, no location', () {
      final d = dataCategory(CategoryId.packetHeaders)!.disclosure;
      for (final w in ['packet type', 'repeaters', 'SNR, RSSI', 'time and region', 'Never message text', 'never your location']) {
        expect(d, contains(w));
      }
      expect(dataCategory(CategoryId.packetHeaders)!.destination, CategoryDestination.telemetryFeed);
    });

    test('every key the context model can store belongs to exactly one category', () {
      Set<String> keys(String scope, Map<String, dynamic> j) => {for (final k in j.keys) '$scope.$k'};
      final stored = {
        ...keys('ctx', fullCtx().toJson()),
        ...keys('sample', fullRadio().toJson())..removeAll({'sample.ts', 'sample.src'}),
        ...keys('sample', fullPhone().toJson())..removeAll({'sample.ts', 'sample.src'}),
        ...keys('session', fullSession().toJson()),
      };
      expect(stored.difference(fieldCategory.keys.toSet()), isEmpty, reason: 'untagged stored key');
      expect(fieldCategory.keys.toSet().difference(stored), isEmpty, reason: 'category lists a key nothing stores');
      final all = [for (final c in dataCategories) ...c.fields];
      expect(all.toSet(), hasLength(all.length));
    });

    test('no coordinate ever appears in a sample or session context', () {
      const banned = {'lat', 'lon', 'latitude', 'longitude', 'lng', 'position', 'location', 'h3'};
      void scan(Object? v) {
        if (v is Map) {
          for (final e in v.entries) {
            expect(banned.contains(e.key), isFalse, reason: 'coordinate key ${e.key}');
            scan(e.value);
          }
        }
      }

      scan(fullRadio().toJson());
      scan(fullPhone().toJson());
      scan(fullSession().toJson());
      scan(fullCtx().toJson());
    });
  });

  group('PingContext', () {
    test('only measured keys; round trip', () {
      expect(fullCtx().toJson(), {
        'alt_m': 251.3,
        'alt_acc_m': 6.0,
        'course_deg': 87.0,
        'course_acc_deg': 12.0,
        'speed_acc_mps': 0.6,
        'pressure_hpa': 987.42,
        'phone_batt_pct': 64,
        'radio_batt_mv': 3912,
      });
      expect(PingContext.fromJson(fullCtx().toJson()).toJson(), fullCtx().toJson());
      expect(PingContext().toJson(), isEmpty);
      expect(PingContext().isEmpty, isTrue);
    });

    test('out of range or unknown -> null, never clamped', () {
      final c = PingContext(
        altM: 9001,
        altAccM: 0,
        courseDeg: 360,
        courseAccDeg: -1,
        speedAccMps: 0,
        pressureHpa: 1200,
        phoneBattPct: 101,
        radioBattMv: 0,
      );
      expect(c.toJson(), isEmpty);
      expect(PingContext(altM: double.nan, courseDeg: 0).toJson(), {'course_deg': 0.0});
      expect(PingContext.fromJson({'alt_m': '12', 'phone_batt_pct': 50.5, 'zzz': 1}).toJson(), isEmpty);
    });

    test('without() strips exactly the switched-off categories', () {
      expect(fullCtx().without({CategoryId.motion}).toJson().keys.toSet(), {'pressure_hpa', 'phone_batt_pct', 'radio_batt_mv'});
      expect(fullCtx().without({CategoryId.barometer, CategoryId.phoneBattery, CategoryId.radioHealth}).toJson().keys.toSet(),
          {'alt_m', 'alt_acc_m', 'course_deg', 'course_acc_deg', 'speed_acc_mps'});
      expect(fullCtx().without(const {}).toJson(), fullCtx().toJson());
    });
  });

  group('DriveSample', () {
    test('round trip, unknown keys dropped, bad line throws', () {
      expect(DriveSample.fromJson(fullRadio().toJson()).toJson(), fullRadio().toJson());
      expect(DriveSample.fromJson(fullPhone().toJson()).toJson(), fullPhone().toJson());
      final withJunk = {...fullPhone().toJson(), 'lat': 40.1, 'lon': -82.9};
      expect(DriveSample.fromJson(withJunk).toJson().containsKey('lat'), isFalse);
      expect(() => DriveSample.fromJson({'src': 'radio'}), throwsFormatException);
      expect(() => DriveSample.fromJson({'ts': '2026-10-24T00:00:00Z', 'src': 'gps'}), throwsFormatException);
    });

    test('ranges: storage used > total dropped, rssi 0 dropped, u32 overflow dropped', () {
      final s = DriveSample(
        ts: DateTime.utc(2026),
        src: SampleSource.radio,
        storageUsedKb: 3000,
        storageTotalKb: 2000,
        lastRssi: 0,
        uptimeS: 0x100000000,
        queue: 256,
        noiseDbm: 0,
        bleRssi: 0,
        errFlags: 0x10000,
      );
      expect(s.toJson().keys.toSet(), {'ts', 'src'});
      expect(s.isEmpty, isTrue);
      expect(PacketCounters.fromJson({'recv': 1}), isNull);
    });

    test('without(): radio_health off empties a radio sample; barometer off keeps phone battery', () {
      expect(fullRadio().without({CategoryId.radioHealth}).isEmpty, isTrue);
      expect(fullPhone().without({CategoryId.barometer}).toJson().keys.toSet(),
          {'ts', 'src', 'batt_pct', 'batt_state', 'low_power'});
      expect(fullPhone().without({CategoryId.phoneBattery}).toJson().keys.toSet(), {'ts', 'src', 'pressure_hpa'});
    });
  });

  group('SessionContext', () {
    test('round trip and strip', () {
      final j = fullSession().toJson();
      expect(j, {
        'device': {'os': 'ios', 'os_version': '18.6', 'model': 'iPhone15,2', 'app_build': '23'},
        'companion_ext': {
          'model': 'Heltec V4.3 OLED',
          'fw_code': 8,
          'fw_build': '12-Oct-2026',
          'max_tx_dbm': 22,
          'path_hash_mode': 0
        },
      });
      expect(SessionContext.fromJson(j).toJson(), j);
      expect(fullSession().without({CategoryId.device}).toJson().keys, ['companion_ext']);
      expect(fullSession().without({CategoryId.device, CategoryId.radioConfig}).isEmpty, isTrue);
    });

    test('device model must be a hardware identifier: free text such as a device name with an apostrophe is refused', () {
      expect(DeviceDetails(model: "Andy's iPhone").model, isNull);
      expect(DeviceDetails(os: 'iOS').os, isNull, reason: 'lower-case os id only');
      expect(DeviceDetails(osVersion: '   ').isEmpty, isTrue);
      expect(CompanionDetails(fwCode: 300, maxTxDbm: 41, pathHashMode: 4).isEmpty, isTrue);
    });
  });
}
