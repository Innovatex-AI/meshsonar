import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/protocol.dart';

DeviceInfoFrame di(int code, {String? ver, int? mode}) => DeviceInfoFrame(firmwareVerCode: code, firmwareVersion: ver, pathHashMode: mode);

void main() {
  group('RadioCaps firmware gate matrix', () {
    // code, version text -> (pathHashMode, clientRepeat, localCli)
    final rows = <(int, String?, bool, bool, bool)>[
      (8, 'v1.12.0', false, false, false),
      (9, 'v1.13.0', false, true, false),
      (10, 'v1.14.0', true, true, false),
      (13, 'v1.17.1', true, true, false),
      (13, 'v1.18.0-sim', true, true, true),
      (14, 'v2.0.0', true, true, true),
      (10, null, true, true, false),
    ];
    for (final (code, ver, hash, repeat, cli) in rows) {
      test('fw code $code / $ver', () {
        final c = RadioCaps.fromDeviceInfo(di(code, ver: ver));
        expect(c.hasPathHashMode, hash);
        expect(c.hasClientRepeat, repeat);
        expect(c.hasLocalCli, cli);
        expect(c.maxHashSize, hash ? 3 : 1);
      });
    }

    test('baseline (no DEVICE_INFO) assumes nothing newer', () {
      const c = RadioCaps.baseline;
      expect(c.hasPathHashMode, isFalse);
      expect(c.hasClientRepeat, isFalse);
      expect(c.hasLocalCli, isFalse);
      expect(c.hasPathDiscovery, isTrue, reason: 'tried until the radio says UNSUPPORTED_CMD');
    });

    test('path discovery is hidden once refused, and the other fields survive', () {
      final c = RadioCaps.fromDeviceInfo(di(13, ver: 'v1.17.1', mode: 1)).copyWith(pathDiscovery: PathDiscoverySupport.no);
      expect(c.hasPathDiscovery, isFalse);
      expect(c.hasPathHashMode, isTrue);
      expect(c.pathHashModeByte, 1);
    });

    test('version parsing', () {
      expect(parseFirmwareVersion('v1.17.1'), (1, 17));
      expect(parseFirmwareVersion('1.18'), (1, 18));
      expect(parseFirmwareVersion('v1.18.0-observer-x'), (1, 18));
      expect(parseFirmwareVersion('ver 13'), isNull);
      expect(parseFirmwareVersion(null), isNull);
    });
  });

  group('RemoteCaps', () {
    test('guest: reads yes, CLI / ACL / writes no', () {
      final c = RemoteCaps.fromLogin(const RemoteLogin(isAdmin: false, firmwareLevel: 2, aclPermissions: 0));
      expect(c.canReadStatus && c.canReadTelemetry && c.canReadNeighbours, isTrue);
      expect(c.canUseCli || c.canReadAcl || c.canWrite, isFalse);
      expect(c.canPostToRoom, isFalse);
      expect(c.canReadOwnerInfo, isTrue);
    });
    test('admin: everything; level below 2 has no owner info', () {
      final c = RemoteCaps.fromLogin(const RemoteLogin(isAdmin: true, firmwareLevel: 1, aclPermissions: 3));
      expect(c.canUseCli && c.canReadAcl && c.canWrite && c.canPostToRoom, isTrue);
      expect(c.canReadOwnerInfo, isFalse);
    });
    test('read-write guest may post to a room; read-only may not; unknown level has no owner info', () {
      expect(const RemoteCaps(perms: 2).canPostToRoom, isTrue);
      expect(const RemoteCaps(perms: 1).canPostToRoom, isFalse);
      expect(RemoteCaps.none.canReadOwnerInfo, isFalse);
    });
  });
}
