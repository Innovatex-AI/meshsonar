import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/radio_presets.dart';

void main() {
  const preset = RadioPreset(name: 'US', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);

  test('all fields match, with float32-style read-back tolerance', () {
    final c = compareRegionPreset(const Radio(freqMhz: 910.5250244, bwKhz: 62.5, sf: 7, cr: 5), preset);
    expect(c.allMatch, isTrue);
  });

  test('differing fields are named', () {
    final c = compareRegionPreset(const Radio(freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 5), preset);
    expect(c.differing, ['Frequency', 'Spreading factor']);
    expect(c.allMatch, isFalse);
  });

  test('a field the radio did not report is unknown, never a match', () {
    final c = compareRegionPreset(const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7), preset);
    expect(c.allMatch, isFalse);
    expect(c.anyUnknown, isTrue);
    expect(c.fields.last.verdict, FieldVerdict.unknown);
  });

  test('no radio: everything unknown', () {
    expect(compareRegionPreset(null, preset).fields.every((f) => f.verdict == FieldVerdict.unknown), isTrue);
  });

  test('community config parses and drops bad entries', () {
    final list = CommunityPreset.parseConfig({
      'config': {
        'suggested_radio_settings': {
          'entries': [
            {'title': 'Australia', 'frequency': '915.800', 'spreading_factor': '10', 'bandwidth': '250', 'coding_rate': '5'},
            {'title': 'Broken', 'frequency': 'x', 'spreading_factor': '10', 'bandwidth': '250', 'coding_rate': '5'},
          ]
        }
      }
    });
    expect(list.length, 1);
    expect(list.single.sf, 10);
    expect(CommunityPreset.parseConfig('nope'), isEmpty);
  });
}
