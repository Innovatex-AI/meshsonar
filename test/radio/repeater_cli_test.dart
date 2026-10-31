import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/repeater_cli.dart';
import 'package:meshsonar/radio/repeater_settings.dart';

void main() {
  group('classifyCommand: exact strings only', () {
    CliKind k(String c) => classifyCommand(c).kind;

    test('measured read commands are reads', () {
      for (final c in ['ver', 'board', 'clock', 'get name', 'get role', 'get radio', 'get tx', 'get flood.advert.interval', 'region', 'region home', 'region default', 'region list allowed', 'region get cmh', 'neighbors', 'get mqtt.status', 'get mqtt3.diag', 'get mqtt.ntp.diag', 'get lat']) {
        expect(k(c), CliKind.read, reason: c);
      }
    });

    test('actions', () {
      for (final c in ['advert', 'advert.zerohop', 'discover.neighbors', 'clock sync']) {
        expect(k(c), CliKind.action, reason: c);
      }
    });

    test('firmware prefix traps are not sent: only the exact word counts', () {
      for (final c in ['advertXYZ', 'advert now', 'rebootnow', 'reboot now', 'verbose', 'boardx', 'clockwork', 'neighborsx', 'regionx', 'advert.zerohopx', 'discover.neighbors now']) {
        expect(classifyCommand(c).sendable, isFalse, reason: c);
      }
      expect(classifyCommand('reboot').reason, 'reboot');
    });

    test('dangerous commands are blocked with a reason, whatever follows', () {
      for (final c in ['poweroff', 'shutdown', 'clkreboot', 'erase', 'start ota', 'stop ota', 'ota update', 'log erase', 'log start', 'tempradio 910,62.5,7,5,10', 'time 1', 'password abc', 'setperm ab 3', 'region load', 'region put x', 'region denyf *', 'set prv.key ' + 'ab' * 32, 'set freq 910', 'sensor set x 1', 'clear stats', 'neighbor.remove ab', 'room.post hi', 'gps on']) {
        final v = classifyCommand(c);
        expect(v.kind, CliKind.blocked, reason: c);
        expect(v.reason, isNotEmpty);
      }
    });

    test('secret keys are never read', () {
      for (final c in ['get guest.password', 'get prv.key', 'get mqtt1.password', 'get mqtt2.token', 'get mqtt.username', 'get acl']) {
        expect(classifyCommand(c).sendable, isFalse, reason: c);
      }
      expect(isSecretKey('guest.password'), isTrue);
      expect(isSecretKey('name'), isFalse);
    });

    test('writes carry the setting key and value; unknown get keys are not sent', () {
      final v = classifyCommand('set name Hilltop 2');
      expect(v.kind, CliKind.write);
      expect(v.settingKey, 'name');
      expect(v.value, 'Hilltop 2');
      expect(k('get nonsense'), CliKind.unknown);
      expect(k('set'), CliKind.unknown);
      expect(k(''), CliKind.unknown);
    });

    test('malformed input: control characters, double spaces, tag prefixes, overlong lines', () {
      expect(k('get name\n'), CliKind.read, reason: 'trailing whitespace is trimmed');
      expect(k('get\x00name'), CliKind.blocked);
      expect(k('get  name'), CliKind.unknown);
      expect(k('12|get name'), CliKind.blocked);
      expect(k('set owner.info ${'x' * 200}'), CliKind.blocked);
      expect(k('GET name'), CliKind.unknown);
    });
  });

  group('redaction', () {
    test('commands and replies lose their secrets', () {
      expect(redactCommand('set guest.password hunter2'), 'set guest.password ••••');
      expect(redactCommand('password hunter2'), 'password ••••');
      expect(redactCommand('set mqtt2.password abc'), 'set mqtt2.password ••••');
      expect(redactCommand('set name Hill'), 'set name Hill');
      expect(redactReply('password x', 'password now: x'), 'password now: ••••');
      expect(redactReply('get guest.password', '> hunter2'), '••••');
      expect(redactReply('get name', '> Hill'), '> Hill');
    });
  });

  group('replies', () {
    test('kinds', () {
      expect(parseReply('> 28').text, '28');
      expect(parseReply('> ').text, '');
      expect(parseReply('OK').isOk, isTrue);
      expect(parseReply('OK - reboot to apply').isOk, isTrue);
      expect(parseReply('Error, bad chars').kind, ReplyKind.error);
      expect(parseReply('Err - bad params').kind, ReplyKind.error);
      expect(parseReply('ERR: clock cannot go backwards').kind, ReplyKind.error);
      expect(parseReply('??: acl').kind, ReplyKind.unsupported);
      expect(parseReply('Unknown command').kind, ReplyKind.unsupported);
      expect(parseReply('Error: unsupported').kind, ReplyKind.unsupported);
      expect(parseReply('unknown config: x').kind, ReplyKind.unsupported);
    });
    test('measured clock reply parses', () {
      expect(parseClockReply('21:23 - 31/10/2026 UTC'), DateTime.utc(2026, 10, 31, 21, 23).millisecondsSinceEpoch ~/ 1000);
      expect(parseClockReply('nonsense'), isNull);
    });
    test('node names', () {
      expect(validateNodeName('INNO-OB-2'), isNull);
      expect(validateNodeName('a,b'), isNotNull);
      expect(validateNodeName('a?'), isNotNull);
      expect(validateNodeName('é' * 16), isNotNull, reason: '32 bytes');
      expect(validateNodeName('é' * 15), isNull);
    });
  });

  group('settings registry', () {
    const limits = BoardLimits(22);
    test('every setting has a reasoned danger, a consequence sentence and exact command', () {
      for (final d in repeaterSettings) {
        expect(d.label, isNotEmpty);
        expect(d.help, isNotEmpty);
        final sample = switch (d.kind) {
          SettingKind.toggle => 'on',
          SettingKind.choice => d.choices.first,
          SettingKind.radio => '910.525,62.5,7,5',
          SettingKind.text => d.key == 'name' ? 'Abc' : 'note',
          SettingKind.secret => 'abc12345',
          SettingKind.decimal => d.key == 'lat' ? '10.5' : d.key == 'lon' ? '10.5' : d.min?.toString() ?? '1',
          SettingKind.integer => (d.min ?? 0).toString(),
        };
        expect(d.validate(sample, limits), isNull, reason: '${d.key} accepts "$sample": ${d.validate(sample, limits)}');
        final n = d.normalize(sample);
        expect(d.consequence(null, n), isNotEmpty);
        final cmd = d.command(n);
        final v = classifyCommand(cmd);
        expect(v.kind == CliKind.write || d.key == 'password', isTrue, reason: '${d.key}: $cmd');
        if (d.key != 'password') expect(v.settingKey, d.key);
        expect(cmd.length, lessThanOrEqualTo(maxCliCommandChars));
        if (d.danger == Danger.bricking) expect(d.typedPhrase(null, n), isNotNull);
      }
    });

    test('keys are unique and expert settings are not the headline ones', () {
      final keys = repeaterSettings.map((d) => d.key).toList();
      expect(keys.toSet().length, keys.length);
      expect(settingFor('name')!.expert, isFalse);
      expect(settingFor('radio')!.expert, isFalse);
      expect(settingFor('af')!.expert, isTrue);
      expect(settingFor('nope'), isNull);
    });

    test('radio compare tolerates the repeater\'s float noise but not a different bandwidth', () {
      final d = settingFor('radio')!;
      expect(d.matches('910.5250244,62.5,7,5', '910.525,62.5,7,5'), isTrue);
      expect(d.matches('910.525,62.5,7,5', '910.525,125,7,5'), isFalse);
      expect(d.matches('910.525,62.5,7,5', '910.525,62.5,8,5'), isFalse);
    });

    test('advert interval rules', () {
      final d = settingFor('advert.interval')!;
      for (final ok in ['0', '60', '180', '240']) {
        expect(d.validate(ok, limits), isNull, reason: ok);
      }
      for (final bad in ['30', '59', '61', '241', '-2', 'x']) {
        expect(d.validate(bad, limits), isNotNull, reason: bad);
      }
      final f = settingFor('flood.advert.interval')!;
      expect(f.validate('2', limits), isNotNull);
      expect(f.validate('3', limits), isNull);
      expect(f.validate('0', limits), isNull);
      expect(f.validate('169', limits), isNotNull);
    });

    test('board limits', () {
      expect(BoardLimits.forBoard('Heltec V4.3 OLED').maxTxDbm, 28);
      expect(BoardLimits.forBoard('Heltec V3').maxTxDbm, 22);
      expect(BoardLimits.forBoard(null).maxTxDbm, 22);
      expect(parseRadioParams('910.525 62.5 7 5')!.sf, 7);
      expect(parseRadioParams('a,b,c,d'), isNull);
    });
  });
}
