// A stateful scripted radio for the device-settings tests: it keeps SELF_INFO / DEVICE_INFO state, applies the writes the
// firmware would, and can play the firmware variants (old, no key export, console missing).
import 'dart:async';
import 'dart:typed_data';

import 'package:meshsonar/radio/protocol.dart';

import 'tools_rig.dart';

class DeviceRadioFake extends FakeToolsRadio {
  int manualAdd = 0, telemetry = 0, advertPolicy = 0, multiAcks = 0;
  int fwCode = 14;
  String fwVersion = 'v1.18.0';
  int pathHashMode = 0;
  int blePin = 123456;
  int autoAddCfg = 0, autoAddHops = 0;
  bool autoAddSupported = true, batterySupported = true, keyExport = true, keyImport = true, cliSupported = true;
  Uint8List key = Uint8List.fromList(List.generate(64, (i) => i + 1));
  Uint8List? importedKey;
  bool rebooted = false, reset = false;
  bool dropAfterReboot = true;
  final cliLog = <String>[];

  /// A radio that acknowledges SET_OTHER_PARAMS but keeps the old values.
  bool lieAboutOther = false;

  DeviceRadioFake() {
    selfInfo = _self();
    onSend = _handle;
  }

  SelfInfoFrame _self() => SelfInfoFrame(
        advType: 1,
        txPowerDbm: 14,
        maxTxPowerDbm: 22,
        publicKey: Uint8List.fromList(List.filled(32, 7)),
        advLat: 0,
        advLon: 0,
        freqKhz: 910525,
        bwHz: 62500,
        sf: 7,
        cr: 5,
        name: 'INNO-OB-1',
        multiAcks: multiAcks,
        advertLocPolicy: advertPolicy,
        telemetryModes: telemetry,
        manualAdd: manualAdd,
      );

  @override
  Future<SelfInfoFrame?> readSelfInfo() async => _self();

  Frame _handle(Uint8List f) {
    switch (f[0]) {
      case Cmd.setOtherParams:
        if (!lieAboutOther) {
          manualAdd = f[1];
          telemetry = f[2];
          advertPolicy = f[3];
          multiAcks = f[4];
        }
        return const OkFrame();
      case Cmd.deviceQuery:
        return DeviceInfoFrame(
            firmwareVerCode: fwCode, maxContacts: 350, maxChannels: 40, firmwareVersion: fwVersion, pathHashMode: fwCode >= 10 ? pathHashMode : null, blePin: blePin);
      case Cmd.setPathHashMode:
        if (f[2] > 2) return const ErrFrame(ErrCode.illegalArg);
        pathHashMode = f[2];
        return const OkFrame();
      case Cmd.setDevicePin:
        final v = ByteData.sublistView(f).getUint32(1, Endian.little);
        if (v != 0 && (v < 100000 || v > 999999)) return const ErrFrame(ErrCode.illegalArg);
        blePin = v;
        return const OkFrame();
      case Cmd.getBattAndStorage:
        return batterySupported ? const BattAndStorageFrame(batteryMv: 3920, storageUsedKb: 100, storageTotalKb: 1000) : const ErrFrame(ErrCode.unsupportedCmd);
      case Cmd.getAutoAddConfig:
        return autoAddSupported ? AutoAddConfigFrame(autoAddCfg, autoAddHops) : const ErrFrame(ErrCode.unsupportedCmd);
      case Cmd.setAutoAddConfig:
        autoAddCfg = f[1];
        autoAddHops = f.length > 2 ? f[2] : 0;
        return const OkFrame();
      case Cmd.reboot:
        rebooted = true;
        if (dropAfterReboot) throw TimeoutException('no reply');
        return const OkFrame();
      case Cmd.factoryReset:
        reset = true;
        return const OkFrame();
      case Cmd.exportPrivateKey:
        return keyExport ? PrivateKeyFrame(Uint8List.fromList(key)) : const DisabledFrame();
      case Cmd.importPrivateKey:
        if (!keyImport) return const DisabledFrame();
        importedKey = Uint8List.fromList(f.sublist(1));
        return const OkFrame();
      case Cmd.setChannel:
        return const OkFrame();
      case Cmd.runCliCommand:
        cliLog.add(String.fromCharCodes(f.sublist(1)));
        return cliSupported ? CliReplyFrame('> ok') : const ErrFrame(ErrCode.unsupportedCmd);
    }
    return const ErrFrame(ErrCode.unsupportedCmd);
  }
}
