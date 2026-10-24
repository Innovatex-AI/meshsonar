// Radio preset comparison + the MeshCore community preset list (api.meshcore.nz). READ-ONLY: this compares what the
// connected radio reports with a preset; nothing here writes to a radio. Pure Dart.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'model.dart';

enum FieldVerdict {
  matches,
  differs,

  /// The radio did not report this field (or no radio): never counted as a match.
  unknown,
}

class PresetField {
  final String label;
  final String? radioValue;
  final String presetValue;
  final FieldVerdict verdict;
  const PresetField(this.label, this.radioValue, this.presetValue, this.verdict);
}

class PresetComparison {
  final List<PresetField> fields;
  const PresetComparison(this.fields);

  bool get allMatch => fields.every((f) => f.verdict == FieldVerdict.matches);
  bool get anyDiffers => fields.any((f) => f.verdict == FieldVerdict.differs);
  bool get anyUnknown => fields.any((f) => f.verdict == FieldVerdict.unknown);
  List<String> get differing => [for (final f in fields) if (f.verdict == FieldVerdict.differs) f.label];
}

/// Frequency is compared to 1 kHz and bandwidth to 0.05 kHz: the radio stores float32 values and reports them back
/// rounded (plan section 2, "float truncation"), so an exact double compare would call identical settings different.
const double _freqTolMhz = 0.0011;
const double _bwTolKhz = 0.051;

FieldVerdict _num(double? radio, double preset, double tol) =>
    radio == null ? FieldVerdict.unknown : ((radio - preset).abs() <= tol ? FieldVerdict.matches : FieldVerdict.differs);

FieldVerdict _int(int? radio, int preset) =>
    radio == null ? FieldVerdict.unknown : (radio == preset ? FieldVerdict.matches : FieldVerdict.differs);

/// Compares [radio] (null = not connected) with a preset's four RF fields, field by field.
PresetComparison comparePreset(Radio? radio, {required double freqMhz, required double bwKhz, required int sf, required int cr}) {
  String? f(double? v, int d) => v?.toStringAsFixed(d);
  return PresetComparison([
    PresetField('Frequency', f(radio?.freqMhz, 3) == null ? null : '${f(radio?.freqMhz, 3)} MHz',
        '${freqMhz.toStringAsFixed(3)} MHz', _num(radio?.freqMhz, freqMhz, _freqTolMhz)),
    PresetField('Bandwidth', f(radio?.bwKhz, 1) == null ? null : '${f(radio?.bwKhz, 1)} kHz',
        '${bwKhz.toStringAsFixed(1)} kHz', _num(radio?.bwKhz, bwKhz, _bwTolKhz)),
    PresetField('Spreading factor', radio?.sf == null ? null : 'SF${radio!.sf}', 'SF$sf', _int(radio?.sf, sf)),
    PresetField('Coding rate', radio?.cr == null ? null : 'CR${radio!.cr}', 'CR$cr', _int(radio?.cr, cr)),
  ]);
}

PresetComparison compareRegionPreset(Radio? radio, RadioPreset p) =>
    comparePreset(radio, freqMhz: p.freqMhz, bwKhz: p.bwKhz, sf: p.sf, cr: p.cr);

/// One entry of the MeshCore community list.
class CommunityPreset {
  final String title;
  final double freqMhz;
  final double bwKhz;
  final int sf;
  final int cr;
  const CommunityPreset({required this.title, required this.freqMhz, required this.bwKhz, required this.sf, required this.cr});

  PresetComparison compare(Radio? radio) => comparePreset(radio, freqMhz: freqMhz, bwKhz: bwKhz, sf: sf, cr: cr);

  /// Entries with a missing or unparseable field are dropped, never guessed.
  static CommunityPreset? tryParse(Object? j) {
    if (j is! Map) return null;
    final title = j['title'];
    final freq = double.tryParse('${j['frequency']}');
    final bw = double.tryParse('${j['bandwidth']}');
    final sf = int.tryParse('${j['spreading_factor']}');
    final cr = int.tryParse('${j['coding_rate']}');
    if (title is! String || title.isEmpty || freq == null || bw == null || sf == null || cr == null) return null;
    return CommunityPreset(title: title, freqMhz: freq, bwKhz: bw, sf: sf, cr: cr);
  }

  static List<CommunityPreset> parseConfig(Object? body) {
    final entries = (body is Map ? body['config'] : null);
    final list = entries is Map ? (entries['suggested_radio_settings'] is Map ? (entries['suggested_radio_settings'] as Map)['entries'] : null) : null;
    if (list is! List) return const [];
    return [for (final e in list) if (CommunityPreset.tryParse(e) case final CommunityPreset p) p];
  }
}

/// Where the community list comes from. Tests inject a fake.
abstract class CommunityPresetSource {
  Future<List<CommunityPreset>> fetch();
}

class HttpCommunityPresetSource implements CommunityPresetSource {
  static const url = 'https://api.meshcore.nz/api/v1/config';
  final http.Client _client;
  HttpCommunityPresetSource({http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<List<CommunityPreset>> fetch() async {
    final r = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw http.ClientException('The community list answered ${r.statusCode}.');
    return CommunityPreset.parseConfig(jsonDecode(r.body));
  }
}
