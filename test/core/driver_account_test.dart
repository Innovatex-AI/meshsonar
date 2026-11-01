// Parsing and key-shape rules of lib/core/driver_account.dart (the driver-key account endpoints).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/driver_account.dart';
import 'package:meshsonar/core/node_claim.dart';

void main() {
  test('newDriverKey is ms_ + 43 url-safe characters, different every time, and passes the server shape', () {
    final a = newDriverKey(), b = newDriverKey();
    expect(isDriverKeyShape(a), isTrue);
    expect(a, isNot(b));
    expect(a.length, 46);
    expect(isDriverKeyShape(newDriverKey(Random(1))), isTrue);
    expect(isDriverKeyShape('ms_short'), isFalse);
    expect(isDriverKeyShape('mm_${'a' * 43}'), isFalse);
  });

  test('devices: linked account, siblings, MeshMapper keys; never a key', () {
    final d = DriverDevices.tryParse({
      'v': 1,
      'linked': true,
      'driver': {'id': 'd1', 'display': 'KE4BFI', 'status': 'approved', 'createdAt': '2026-10-01T00:00:00Z', 'keyHint': 'abcd', 'revealable': true},
      'devices': [
        {'id': 'd1', 'display': 'KE4BFI', 'status': 'approved'},
        {'id': 'd2', 'display': 'iPad', 'status': 'banned'},
        'junk',
      ],
      'mm': {
        'linked': true,
        'keys': [
          {'id': 'm1', 'keyHint': 'wxyz', 'items': 40, 'items24h': 4, 'revealable': true},
          {'id': 'm2', 'keyHint': 'oldd', 'revokedAt': '2026-10-03T00:00:00Z'},
        ]
      }
    })!;
    expect(d.linked, isTrue);
    expect(d.driver.revealable, isTrue);
    expect(d.devices.map((e) => e.id), ['d1', 'd2']);
    expect(d.devices[1].status, DriverKeyStatus.revoked);
    expect(d.mmKeys.length, 2);
    expect(d.activeMm!.id, 'm1');
    expect(d.mmKeys[1].active, isFalse);
  });

  test('devices: an unlinked key lists itself; a wrong version or no driver is not accepted', () {
    final d = DriverDevices.tryParse({'v': 1, 'linked': false, 'driver': {'id': 'd7', 'display': 'x', 'status': 'approved'}, 'devices': [], 'mm': {'linked': false, 'keys': []}})!;
    expect(d.devices.single.id, 'd7');
    expect(d.mmKeys, isEmpty);
    expect(DriverDevices.tryParse({'v': 2, 'driver': {'id': 'd7'}}), isNull);
    expect(DriverDevices.tryParse({'v': 1}), isNull);
  });

  test('drive detail: pings sorted, bad rows counted, totals computed', () {
    final x = ServerDriveDetail.tryParse({
      'drive': {'id': 's1', 'startedAt': '2026-10-30T10:00:00Z', 'km': 2.5},
      'pings': [
        {'id': 'b', 'at': '2026-10-30T10:02:00Z', 'lat': 39.9, 'lon': -83.0, 'heard': false, 'echoes': []},
        {
          'id': 'a', 'at': '2026-10-30T10:01:00Z', 'lat': 39.9, 'lon': -83.0, 'heard': true,
          'echoes': [{'repeaterId': 'ab12', 'name': 'Hill', 'snr': 4.5, 'rssi': -90}, {'repeaterId': 'cd34', 'snr': 7.0}]
        },
        {'id': 'bad', 'at': 'nope', 'lat': 1, 'lon': 1},
        {'id': 'far', 'at': '2026-10-30T10:03:00Z', 'lat': 99, 'lon': 1},
      ],
    })!;
    expect(x.pings.map((p) => p.id), ['a', 'b']);
    expect(x.skipped, 2);
    expect(x.heardCount, 1);
    expect(x.repeaterCount, 2);
    expect(x.bestSnr, 7.0);
    expect(ServerDriveDetail.tryParse({'pings': []}), isNull);
  });

  test('reports parse with plain-words status and category', () {
    final rows = ReportRow.parseList({
      'reports': [
        {'id': 'r1', 'createdAt': '2026-10-31T00:00:00Z', 'status': 'triaged', 'category': 'gps', 'source': 'app', 'summary': 'No fix'},
        {'id': 'r2'},
      ]
    });
    expect(rows.length, 1);
    expect(rows.single.statusWords, contains('working on it'));
    expect(rows.single.categoryWords, 'GPS or location');
  });

  test('delete counts', () {
    final c = DriverDeleteCounts.parse({'deleted': {'sessions': 3, 'pings': 120, 'reports': 1}});
    expect((c.sessions, c.pings, c.reports, c.samples), (3, 120, 1, 0));
  });

  test('observer claim health: states, battery, unknown states ignored', () {
    final key = 'a' * 64;
    final c = NodeClaim.parse({
      'pubkey': key, 'nodeType': 'observer', 'method': 'signature',
      'health': {'state': 'deaf', 'flatMinutes': 95, 'battery': {'mv': 3300, 'low': true, 'trend': 'falling'}},
    });
    expect(c.health!.state, 'deaf');
    expect(c.health!.batteryLow, isTrue);
    expect(c.health!.batteryMv, 3300);
    expect(c.health!.words, startsWith('Deaf'));
    expect(NodeClaim.parse({'pubkey': key, 'health': {'state': 'weird'}}).health, isNull);
    expect(NodeClaim.parse({'pubkey': key}).health, isNull);
    expect(ObserverHealth.tryParse({'state': 'quiet', 'flatMinutes': 75})!.words, contains('1 h 15 min'));
  });
}
