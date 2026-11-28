// MeshSonar Firmware detection from DEVICE_INFO (brief section A; meshsonar-firmware docs/APP-INTEGRATION.md section 1).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/msradio/fake_radio_api.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/simulator.dart';

DeviceInfoFrame di(String? ver, {String? board, int code = 10}) => DeviceInfoFrame(firmwareVerCode: code, firmwareVersion: ver, manufacturer: board);

void main() {
  group('MeshSonarFw.tryParse', () {
    test('stock v1.18.0 is not MeshSonar', () {
      expect(MeshSonarFw.tryParse(di('v1.18.0', board: 'Heltec V3')), isNull);
    });

    test('v1.18.0-ms0.1.0 on a Heltec V4 TFT', () {
      final f = MeshSonarFw.tryParse(di('v1.18.0-ms0.1.0', board: 'Heltec V4 TFT'))!;
      expect(f.msVersion, '0.1.0');
      expect(f.coreVersion, 'v1.18.0');
      expect(f.boardName, 'Heltec V4 TFT');
      expect(f.msVersionParts, (0, 1, 0));
    });

    test('1.18-ms0.2.10 (no v, no patch)', () {
      final f = MeshSonarFw.tryParse(di('1.18-ms0.2.10', board: 'Heltec V4 R8 TFT'))!;
      expect(f.msVersion, '0.2.10');
      expect(f.coreVersion, '1.18');
      expect(f.boardName, 'Heltec V4 R8 TFT');
    });

    test('v1.17.1-observer-x is stock', () {
      expect(MeshSonarFw.tryParse(di('v1.17.1-observer-x')), isNull);
    });

    test('empty and missing strings are stock', () {
      expect(MeshSonarFw.tryParse(di('')), isNull);
      expect(MeshSonarFw.tryParse(di('   ')), isNull);
      expect(MeshSonarFw.tryParse(di(null)), isNull);
      expect(MeshSonarFw.tryParse(di('v1.18.0-ms')), isNull);
      expect(MeshSonarFw.tryParse(di('ms0.1.0')), isNull);
      expect(MeshSonarFw.tryParse(di('xv1.18.0-ms0.1.0')), isNull, reason: 'anchored at the start');
    });

    test('a missing board name is empty', () {
      expect(MeshSonarFw.tryParse(di('v1.18.0-ms0.1.0'))!.boardName, '');
    });
  });

  group('RadioCaps', () {
    test('stock radio: isMeshSonar false, meshSonar null, other gates unchanged', () {
      final c = RadioCaps.fromDeviceInfo(di('v1.18.0', code: 13));
      expect(c.isMeshSonar, isFalse);
      expect(c.meshSonar, isNull);
      expect(c.hasLocalCli, isTrue);
      expect(RadioCaps.baseline.isMeshSonar, isFalse);
    });

    test('MeshSonar radio: set from DEVICE_INFO, the MeshCore gates still read 1.18, kept by copyWith', () {
      final c = RadioCaps.fromDeviceInfo(di('v1.18.0-ms0.1.0', board: 'Heltec V4 TFT', code: 13));
      expect(c.isMeshSonar, isTrue);
      expect(c.meshSonar!.msVersion, '0.1.0');
      expect(c.fwVersion, (1, 18));
      expect(c.hasLocalCli, isTrue);
      final d = c.copyWith(pathDiscovery: PathDiscoverySupport.no);
      expect(d.isMeshSonar, isTrue);
      expect(d.meshSonar, c.meshSonar);
      expect(d.hasPathDiscovery, isFalse);
    });
  });

  group('Simulator', () {
    test('the stock simulator is unchanged: v1.18.0-sim, MeshSonar Simulator, not MeshSonar', () async {
      final radio = SimulatedTransport(seed: 1, timeScale: 50);
      final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
      addTearDown(link.close);
      final self = await link.start();
      expect(self.firmware, 'v1.18.0-sim');
      expect(link.radioCaps.isMeshSonar, isFalse);
      expect(radio.publicKey, sha256(utf8.encode('meshsonar-sim-companion')));
      expect(SimulatedRadioScanner().meshSonar, isFalse);
    });

    test('meshSonar: reports MeshSonar 0.1.0 on Heltec V4 TFT, stays a Simulator drive, key = the test vector', () async {
      final radio = SimulatedTransport(seed: 1, timeScale: 50, meshSonar: true);
      final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
      addTearDown(link.close);
      final self = await link.start();
      expect(self.firmware, simMeshSonarFirmware);
      expect(self.firmware, startsWith('v1.18.0-ms0.1.0'));
      expect(Companion(firmware: self.firmware).isSimulated, isTrue, reason: 'never uploaded as a real drive');
      final caps = link.radioCaps;
      expect(caps.isMeshSonar, isTrue);
      expect(caps.meshSonar!.msVersion, '0.1.0');
      expect(caps.meshSonar!.boardName, 'Heltec V4 TFT');
      expect(self.publicKey, MsTestVector.key);
    });

    test('meshSonar: CMD_SIGN_* over the companion link signs with the radio key (real Ed25519)', () async {
      final radio = SimulatedTransport(seed: 1, timeScale: 50, meshSonar: true);
      final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
      addTearDown(link.close);
      await link.start();
      final sig = await link.sign(Uint8List.fromList(utf8.encode(MsTestVector.pair)));
      expect(toHex(sig), MsTestVector.pairSig);
      final ok = await cr.Ed25519().verify(utf8.encode(MsTestVector.pair),
          signature: cr.Signature(sig, publicKey: cr.SimplePublicKey(fromHex(MsTestVector.key), type: cr.KeyPairType.ed25519)));
      expect(ok, isTrue);
    });

    test('the scanner passes the flag on', () async {
      final s = SimulatedRadioScanner(meshSonar: true);
      final t = await s.connect(SimulatedRadioScanner.device) as SimulatedTransport;
      expect(t.meshSonar, isTrue);
      expect(t.firmwareVersion, simMeshSonarFirmware);
      await t.disconnect();
    });
  });
}
