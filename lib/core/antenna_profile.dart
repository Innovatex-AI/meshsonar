// How one radio's antenna is set up (Q4.14), saved per companion radio in settings as `antenna_profiles`.
// Drives still upload the Drive Format v1 antenna ({type: internal|external, gain_dbi, height_m}); the mount itself is
// kept on the phone only. Ranges follow CMAT's validator (src/lib/drive/validate.ts).
// Pure Dart: no Flutter imports.
import 'model.dart';

enum AntennaMount {
  handheld('Handheld', 'internal'),
  insideCar('Inside car', 'internal'),
  roofMagMount('Roof mag-mount', 'external'),
  fixedMast('Fixed mast', 'external');

  /// What people see.
  final String label;

  /// Drive Format v1 `antenna.type` for this mount.
  final String wireType;
  const AntennaMount(this.label, this.wireType);
}

class AntennaProfile {
  static const double minGainDbi = -10, maxGainDbi = 20;
  static const double minHeightM = 0, maxHeightM = 300;

  final AntennaMount mount;

  /// Null = "Don't know".
  final double? gainDbi;

  /// Height of the antenna above the ground, in metres.
  final double heightM;
  final DateTime updatedAt;
  const AntennaProfile({required this.mount, this.gainDbi, required this.heightM, required this.updatedAt});

  static bool validGain(double v) => v.isFinite && v >= minGainDbi && v <= maxGainDbi;
  static bool validHeight(double v) => v.isFinite && v >= minHeightM && v <= maxHeightM;

  /// The Drive Format v1 antenna for drives made with this radio.
  Antenna toAntenna() => Antenna(type: mount.wireType, gainDbi: gainDbi, heightM: heightM);

  /// "Roof mag-mount · 5.8 dBi · 1.8 m" (gain left out when it isn't known).
  String get summary => [
    mount.label,
    if (gainDbi != null) '${formatAntennaNumber(gainDbi!)} dBi',
    '${formatAntennaNumber(heightM)} m',
  ].join(' · ');

  Map<String, dynamic> toJson() => {
    'mount': mount.name,
    'gain_dbi': gainDbi,
    'height_m': heightM,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  /// A profile from settings JSON, or null when anything in it is unknown or out of range (that profile is dropped,
  /// never the rest of the settings).
  static AntennaProfile? tryParse(Object? json) {
    if (json is! Map) return null;
    final mount = AntennaMount.values.asNameMap()[json['mount']];
    final gain = json['gain_dbi'];
    final height = json['height_m'];
    final updated = json['updated_at'] is String ? DateTime.tryParse(json['updated_at'] as String) : null;
    if (mount == null || updated == null) return null;
    if (height is! num || !validHeight(height.toDouble())) return null;
    if (gain != null && (gain is! num || !validGain(gain.toDouble()))) return null;
    return AntennaProfile(
      mount: mount,
      gainDbi: (gain as num?)?.toDouble(),
      heightM: height.toDouble(),
      updatedAt: updated.toUtc(),
    );
  }
}

/// 5.8 → "5.8", 6.0 → "6".
String formatAntennaNumber(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
