import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/backup.dart';
import 'package:meshsonar/chat/backup_crypto.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/device_settings.dart';

import '../support/device_radio_fake.dart';

DeviceSettingsTool toolOf(DeviceRadioFake r) => DeviceSettingsTool(r, backupIterations: 1000, backupUseIsolate: false, clock: () => DateTime.utc(2026, 11, 2));

void main() {
  group('frame encoders (firmware layout)', () {
    test('SET_DEVICE_PIN is [37][pin u32 LE]; only 0 or 6 digits', () {
      expect(encodeSetDevicePin(123456), [37, 0x40, 0xE2, 0x01, 0x00]);
      expect(encodeSetDevicePin(999999), [37, 0x3F, 0x42, 0x0F, 0x00]);
      expect(encodeSetDevicePin(0), [37, 0, 0, 0, 0]);
      expect(() => encodeSetDevicePin(99999), throwsArgumentError);
      expect(() => encodeSetDevicePin(1000000), throwsArgumentError);
    });
    test('REBOOT and FACTORY_RESET carry the literal words', () {
      expect(encodeReboot(), [19, ...'reboot'.codeUnits]);
      expect(encodeFactoryReset(), [51, ...'reset'.codeUnits]);
    });
    test('private key export/import', () {
      expect(encodeExportPrivateKey(), [23]);
      final k = List.generate(64, (i) => i);
      expect(encodeImportPrivateKey(k), [24, ...k]);
      expect(() => encodeImportPrivateKey([1, 2, 3]), throwsArgumentError);
    });
    test('path hash mode is [61][0][mode], 3+ rejected on the phone', () {
      expect(encodeSetPathHashMode(2), [61, 0, 2]);
      expect(() => encodeSetPathHashMode(3), throwsArgumentError);
    });
    test('RUN_CLI_COMMAND [66][text], reply [29][text]', () {
      expect(encodeRunCliCommand('ver'), [66, 118, 101, 114]);
      expect(() => encodeRunCliCommand(''), throwsArgumentError);
      expect(() => encodeRunCliCommand('x' * 161), throwsArgumentError);
      final f = decodeFrame(Uint8List.fromList([29, ...utf8.encode('v1.18.0')]));
      expect(f, isA<CliReplyFrame>());
      expect((f as CliReplyFrame).text, 'v1.18.0');
    });
    test('PRIVATE_KEY decodes, and its toString never shows the key', () {
      final f = decodeFrame(encodePrivateKey(List.filled(64, 0xAB)));
      expect(f, isA<PrivateKeyFrame>());
      expect(f.toString(), isNot(contains('171')));
      expect(f.toString(), contains('redacted'));
      expect(decodeFrame(encodeDisabled()), isA<DisabledFrame>());
    });
    test('DEVICE_INFO carries the BLE pin and path hash mode', () {
      final f = decodeFrame(encodeDeviceInfo(firmwareVerCode: 14, maxChannels: 40, buildDate: 'b', manufacturer: 'm', firmwareVersion: 'v1.18.0', pathHashMode: 2, blePin: 424242)) as DeviceInfoFrame;
      expect(f.blePin, 424242);
      expect(f.pathHashMode, 2);
    });
    test('telemetry modes pack as env<<4 | location<<2 | base', () {
      const m = TelemetryModes(base: 2, location: 1, env: 2);
      expect(m.byte, 0x26);
      expect(TelemetryModes.fromByte(0x26), m);
    });
  });

  group('error mapping', () {
    test('ERR codes and DISABLED', () {
      expect(deviceErrorOf(const OkFrame()), isNull);
      expect(deviceErrorOf(const ErrFrame(1)), DeviceErrorKind.unsupported);
      expect(deviceErrorOf(const ErrFrame(6)), DeviceErrorKind.refused);
      expect(deviceErrorOf(const ErrFrame(5)), DeviceErrorKind.storage);
      expect(deviceErrorOf(const DisabledFrame()), DeviceErrorKind.disabled);
      expect(deviceErrorOf(const CliReplyFrame('x')), DeviceErrorKind.unexpected);
    });

    test('ERR 1 on the console hides it, with a reason', () async {
      final r = DeviceRadioFake()..cliSupported = false;
      final t = toolOf(r);
      await t.read();
      expect(t.available(DeviceFeature.console), isTrue);
      final res = await t.runCli('ver');
      expect(res.failure!.error, DeviceErrorKind.unsupported);
      expect(t.available(DeviceFeature.console), isFalse);
      expect(t.unavailable[DeviceFeature.console], contains('ERR 1'));
    });

    test('old firmware gates path hash size and console from the version', () async {
      final r = DeviceRadioFake()
        ..fwCode = 9
        ..fwVersion = 'v1.17.1-abc';
      final t = toolOf(r);
      await t.read();
      expect(t.available(DeviceFeature.pathHashMode), isFalse);
      expect(t.unavailable[DeviceFeature.pathHashMode], contains('code 9'));
      expect(t.available(DeviceFeature.console), isFalse);
      expect(t.unavailable[DeviceFeature.console], contains('1.18'));
      final res = await t.setPathHashSize(2);
      expect(res.ok, isFalse);
      expect(r.sent.where((s) => s.frame[0] == Cmd.setPathHashMode), isEmpty, reason: 'nothing sent to an old radio');
    });

    test('no battery command hides the battery row', () async {
      final r = DeviceRadioFake()..batterySupported = false;
      final t = toolOf(r);
      await t.read();
      expect(t.available(DeviceFeature.battery), isFalse);
      expect(t.snapshot!.battery, isNull);
    });

    test('no auto-add command hides it', () async {
      final r = DeviceRadioFake()..autoAddSupported = false;
      final t = toolOf(r);
      await t.read();
      expect(t.available(DeviceFeature.autoAdd), isFalse);
    });
  });

  group('read-back verification', () {
    test('telemetry sharing is written from a fresh SELF_INFO and verified', () async {
      final r = DeviceRadioFake()
        ..advertPolicy = 1
        ..multiAcks = 1;
      final t = toolOf(r);
      await t.read();
      r.advertPolicy = 0; // changed elsewhere after the screen read it: must not be clobbered back
      final res = await t.setTelemetryModes(const TelemetryModes(base: 2, location: 0, env: 1));
      expect(res.ok, isTrue);
      expect(res.verified, isTrue);
      expect(r.telemetry, 0x12);
      expect(r.advertPolicy, 0);
      expect(r.multiAcks, 1);
    });

    test('a radio that acknowledges but keeps the old value is reported as a mismatch', () async {
      final r = DeviceRadioFake()..lieAboutOther = true;
      final t = toolOf(r);
      await t.read();
      final res = await t.setMultiAcks(true);
      expect(res.ok, isFalse);
      expect(res.message, contains('reads back differently'));
    });

    test('undo puts the old value back', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      await t.read();
      expect((await t.setMultiAcks(true)).ok, isTrue);
      expect(r.multiAcks, 1);
      expect(t.canUndo, isTrue);
      expect((await t.undo()).ok, isTrue);
      expect(r.multiAcks, 0);
    });

    test('path hash size is written and read back from DEVICE_INFO', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      await t.read();
      final res = await t.setPathHashSize(3);
      expect(res.ok, isTrue);
      expect(r.pathHashMode, 2);
      expect(t.snapshot!.pathHashBytes, 3);
      expect(r.sent.last.frame[0], Cmd.deviceQuery, reason: 'the last frame is the read-back');
    });

    test('auto-add config is verified', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      await t.read();
      final res = await t.setAutoAdd(const ContactPolicy(askBeforeAdding: true, autoAddChat: true, overwriteOldest: true, maxHops: 3));
      expect(res.ok, isTrue);
      expect(r.autoAddCfg, AutoAddFlags.chat | AutoAddFlags.overwriteOldest);
      expect(r.autoAddHops, 3);
    });

    test('battery estimate is monotonic and bounded', () {
      expect(estimateBatteryPercent(3000), 0);
      expect(estimateBatteryPercent(4300), 100);
      expect(estimateBatteryPercent(3920), inInclusiveRange(70, 82));
      var last = -1;
      for (var mv = 3200; mv <= 4300; mv += 50) {
        final p = estimateBatteryPercent(mv);
        expect(p, greaterThanOrEqualTo(last));
        last = p;
      }
    });
  });

  group('PIN', () {
    test('validation', () {
      expect(PinCheck.problem('123456', '123456'), isNull);
      expect(PinCheck.problem('12345', '12345'), isNotNull);
      expect(PinCheck.problem('1234567', '1234567'), isNotNull);
      expect(PinCheck.problem('12345a', '12345a'), isNotNull);
      expect(PinCheck.problem('012345', '012345'), isNotNull);
      expect(PinCheck.problem('123456', '123457'), contains('different'));
      expect(PinCheck.weakness('123456'), isNotNull);
      expect(PinCheck.weakness('482913'), isNull);
    });

    test('an invalid PIN never reaches the radio; a valid one is read back', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      await t.read();
      final before = r.sent.length;
      expect((await t.setPin('12', '12')).ok, isFalse);
      expect(r.sent.length, before);
      final res = await t.setPin('482913', '482913');
      expect(res.ok, isTrue);
      expect(res.verified, isTrue);
      expect(r.blePin, 482913);
      expect(res.message, isNot(contains('482913')), reason: 'the PIN is never put in a message');
    });
  });

  group('typed confirmation gating', () {
    test('factory reset needs exactly RESET, checked in the tool', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      for (final bad in ['', 'reset', 'RESE', 'RESET NOW', 'yes']) {
        final res = await t.factoryReset(bad);
        expect(res.ok, isFalse, reason: bad);
      }
      expect(r.reset, isFalse);
      expect(r.sent.where((s) => s.frame[0] == Cmd.factoryReset), isEmpty);
      final ok = await t.factoryReset(' RESET ');
      expect(ok.ok, isTrue);
      expect(r.reset, isTrue);
    });

    test('importing an identity needs REPLACE', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      final data = RadioBackupData(radioName: 'a', publicKeyHex: '07' * 32, createdMs: 0, identityKey: Uint8List.fromList(List.filled(64, 9)));
      var res = await t.restoreBackup(data, replaceIdentity: true, typed: 'replace');
      expect(res.result.ok, isFalse);
      expect(r.importedKey, isNull);
      res = await t.restoreBackup(data, replaceIdentity: true, typed: 'REPLACE');
      expect(res.result.ok, isTrue);
      expect(r.importedKey, List.filled(64, 9));
      expect(res.report.identityReplaced, isTrue);
      expect(res.result.message, contains('Reboot'));
    });

    test('reboot treats a missing reply as success', () async {
      final r = DeviceRadioFake();
      final res = await toolOf(r).reboot();
      expect(res.ok, isTrue);
      expect(r.rebooted, isTrue);
    });
  });

  group('console', () {
    test('runs a line; dangerous lines never reach the radio', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      await t.read();
      expect((await t.runCli('ver')).reply, '> ok');
      for (final bad in ['reboot', 'erase', 'get prv.key', 'set prv.key abc', 'start ota', 'poweroff', 'factory reset']) {
        final x = await t.runCli(bad);
        expect(x.failure, isNotNull, reason: bad);
      }
      expect(r.cliLog, ['ver']);
    });
  });

  group('backup', () {
    final contacts = [
      RadioContact(publicKeyHex: 'ab' * 32, type: 2, outPathLen: 2, outPath: Uint8List.fromList([1, 2]), name: 'Rep', lat: 40.1, lon: -83.0, lastAdvert: 5, lastMod: 6),
    ];
    final channels = [RadioChannel(0, 'Public', Uint8List.fromList(List.filled(16, 3))), RadioChannel(1, '', Uint8List(16))];

    test('round trip through encrypt/decrypt, key included, nothing in clear', () async {
      final r = DeviceRadioFake()
        ..contactList = contacts
        ..channelList = channels;
      final t = toolOf(r);
      await t.read();
      final out = await t.exportBackup('correct horse battery');
      expect(out.result.ok, isTrue, reason: out.result.message);
      expect(out.identityIncluded, isTrue);
      final file = out.file!;
      final text = utf8.decode(file);
      expect(text, isNot(contains(base64.encode(r.key))));
      expect(text, isNot(contains('INNO-OB-1')));
      expect(BackupCrypto.looksEncrypted(jsonDecode(text) as Map<String, dynamic>), isTrue);

      final back = await t.openBackup(file, 'correct horse battery');
      expect(back.identityKey, r.key);
      expect(back.radioName, 'INNO-OB-1');
      expect(back.contacts.single.name, 'Rep');
      expect(back.contacts.single.outPath, [1, 2]);
      expect(back.channels.single.name, 'Public');
      expect(back.toString(), isNot(contains('1, 2, 3')));
    });

    test('wrong passphrase fails', () async {
      final r = DeviceRadioFake()..contactList = contacts;
      final t = toolOf(r);
      await t.read();
      final file = (await t.exportBackup('correct horse battery')).file!;
      await expectLater(t.openBackup(file, 'wrong passphrase!!'), throwsA(isA<BackupWrongPassphrase>()));
    });

    test('a weak passphrase is refused before anything is read', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      final out = await t.exportBackup('short');
      expect(out.file, isNull);
      expect(r.sent.where((s) => s.frame[0] == Cmd.exportPrivateKey), isEmpty);
    });

    test('a firmware that disables key export still backs up contacts and channels, and says so', () async {
      final r = DeviceRadioFake()
        ..keyExport = false
        ..contactList = contacts
        ..channelList = channels;
      final t = toolOf(r);
      await t.read();
      final out = await t.exportBackup('correct horse battery');
      expect(out.result.ok, isTrue);
      expect(out.identityIncluded, isFalse);
      expect(t.available(DeviceFeature.identityKeyExport), isFalse);
      final back = await t.openBackup(out.file!, 'correct horse battery');
      expect(back.hasIdentity, isFalse);
      expect(back.contacts, hasLength(1));
    });

    test('restore writes channels and contacts; no identity change without the flag', () async {
      final r = DeviceRadioFake()
        ..contactList = contacts
        ..channelList = channels;
      final t = toolOf(r);
      await t.read();
      final file = (await t.exportBackup('correct horse battery')).file!;
      final data = await t.openBackup(file, 'correct horse battery');
      final res = await t.restoreBackup(data);
      expect(res.report.channels, 1);
      expect(res.report.contacts, 1);
      expect(res.report.identityReplaced, isFalse);
      expect(r.importedKey, isNull);
      expect(r.added.single.name, 'Rep');
    });

    test('a chat backup or junk is not a radio backup', () async {
      final r = DeviceRadioFake();
      final t = toolOf(r);
      await expectLater(t.openBackup(Uint8List.fromList(utf8.encode('{"hello":1}')), 'whatever pass'), throwsA(isA<BackupFormatException>()));
      await expectLater(t.openBackup(Uint8List.fromList([1, 2, 3]), 'whatever pass'), throwsA(isA<BackupFormatException>()));
      // a validly encrypted payload with the wrong inner format
      final env = await BackupCrypto.encrypt(Uint8List.fromList(utf8.encode(jsonEncode({'format': ChatBackup.format, 'version': 1}))), 'whatever pass', iterations: 1000, useIsolate: false);
      await expectLater(t.openBackup(env, 'whatever pass'), throwsA(isA<BackupFormatException>()));
    });

    test('hostile contacts and channels are dropped and counted', () async {
      final bad = jsonEncode({
        'format': RadioBackup.format,
        'version': 1,
        'radio': {'name': 'x', 'publicKey': '07' * 32},
        'contacts': [
          {'key': 'zz', 'type': 1, 'name': 'a', 'outPath': '', 'outPathLen': 0},
          {'key': 'ab' * 32, 'type': 9, 'name': 'a', 'outPath': '', 'outPathLen': 0},
          'str',
        ],
        'channels': [
          {'index': 999, 'name': 'a', 'secret': '00' * 16},
          {'index': 1, 'name': 'a', 'secret': 'nothex'},
        ],
      });
      final env = await BackupCrypto.encrypt(Uint8List.fromList(utf8.encode(bad)), 'whatever pass', iterations: 1000, useIsolate: false);
      final d = await RadioBackup.open(env, 'whatever pass', useIsolate: false);
      expect(d.contacts, isEmpty);
      expect(d.channels, isEmpty);
      expect(d.skipped, 5);
    });
  });
}
