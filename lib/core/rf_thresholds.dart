// RF thresholds shared by every chart and plain-language reading in the app. The SAME numbers as the website
// (meshcore-insights src/components/region/analysis-rf.ts and analysis-model.ts), so app and site agree on what
// "interference" means. Change them there and here together.
// Pure Dart: no Flutter imports.

/// A LoRa receiver in a quiet spot sits near -115 to -120 dBm. Above this it is hearing something loud that is not
/// MeshCore (a nearby transmitter, a bad power supply, a cheap charger): packets are being lost.
const double noiseFloorInterferenceDbm = -100;

/// Above this (but below interference) the floor is raised enough to cost range.
const double noiseFloorElevatedDbm = -110;

/// A packet at or below this SNR is at the edge of what the radio can decode.
const double snrWeakDb = 0;

/// Quiet-receiver baseline: noise bars start here so a taller bar is always a noisier hour.
const double noiseBaseDbm = -120;

enum NoiseVerdict { interference, elevated, normal }

NoiseVerdict? noiseVerdict(double? dbm) {
  if (dbm == null || !dbm.isFinite) return null;
  if (dbm > noiseFloorInterferenceDbm) return NoiseVerdict.interference;
  if (dbm > noiseFloorElevatedDbm) return NoiseVerdict.elevated;
  return NoiseVerdict.normal;
}

/// The website's wording for each verdict.
String noiseVerdictText(NoiseVerdict v) => switch (v) {
      NoiseVerdict.interference =>
        'Noise floor is above -100 dBm: likely interference. Distant nodes will be drowned out here.',
      NoiseVerdict.elevated => 'Noise floor is raised (above -110 dBm). Range is reduced; look for nearby electronics or other radios.',
      NoiseVerdict.normal => 'Noise floor looks healthy.',
    };

/// "-97.1" style dBm/dB text: one decimal, no unit.
String db1(double v) => v.toStringAsFixed(1);
