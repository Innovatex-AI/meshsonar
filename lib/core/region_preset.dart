// Does the connected radio already use a region's suggested preset? Used by the border-crossing flow: same preset =
// notify and follow; different = ask. The app never writes RF parameters to the radio. Pure Dart.
import 'api.dart';
import 'model.dart';
import 'region_lookup.dart';

/// True when [radio] matches [preset] (frequency within 5 kHz, bandwidth within 0.5 kHz, same SF and CR). A radio
/// reading that is unknown (null) never counts as a mismatch: we only ask when we can prove the difference.
bool presetMatchesRadio(RadioPreset preset, Radio radio) {
  if (radio.freqMhz != null && (radio.freqMhz! - preset.freqMhz).abs() > 0.005) return false;
  if (radio.bwKhz != null && (radio.bwKhz! - preset.bwKhz).abs() > 0.5) return false;
  if (radio.sf != null && radio.sf != preset.sf) return false;
  if (radio.cr != null && radio.cr != preset.cr) return false;
  return true;
}

/// The question shown when a border crossing lands in a region with a different radio preset.
class RegionPresetPrompt {
  final RegionIndexEntry from;
  final RegionIndexEntry to;
  final RadioPreset preset;
  final Radio radio;
  const RegionPresetPrompt({required this.from, required this.to, required this.preset, required this.radio});
}
