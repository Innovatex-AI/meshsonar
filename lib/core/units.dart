// The one place that turns SI numbers (metres, m/s, hPa, °C) into text for the screen, in metric or imperial.
// Storage and the wire stay SI forever (docs/MESHSONAR_DRIVE_FORMAT.md: antenna.height_m, speed in m/s); conversion
// happens only at the edge, in display and in text input. Spec: app-website-parity-and-region-spec section D.
// Pure Dart: no Flutter imports.

enum UnitSystem { metric, imperial }

/// What the person picked in Settings. [auto] follows the phone's region (US, Liberia and Myanmar use imperial).
enum UnitsPreference {
  auto,
  metric,
  imperial;

  static UnitsPreference parse(Object? v) => UnitsPreference.values.firstWhere((e) => e.name == v, orElse: () => UnitsPreference.auto);
}

/// Countries whose road signs and everyday speech are imperial.
const Set<String> imperialCountries = {'US', 'LR', 'MM'};

/// The system for a device country code (e.g. "US" from the locale "en_US"); metric when unknown.
UnitSystem unitSystemForCountry(String? countryCode) =>
    imperialCountries.contains(countryCode?.toUpperCase()) ? UnitSystem.imperial : UnitSystem.metric;

/// Country code from a locale name such as `en_US`, `en-US`, `fr_CA.UTF-8`, `zh_Hans_CN`; null when there is none.
String? countryFromLocaleName(String? locale) {
  if (locale == null) return null;
  final parts = locale.split('.').first.split(RegExp(r'[_\-]'));
  for (final p in parts.skip(1)) {
    if (p.length == 2 && p == p.toUpperCase() && RegExp(r'^[A-Z]{2}$').hasMatch(p)) return p;
  }
  return null;
}

const double metresPerMile = 1609.344;
const double metresPerFoot = 0.3048;
const double kmhPerMps = 3.6;
const double mphPerMps = 2.236936;

/// Inches of mercury per hectopascal (1 inHg = 33.8638866667 hPa, at 0 °C).
const double inHgPerHpa = 1 / 33.8638866667;

class Units {
  final UnitSystem system;
  const Units(this.system);

  static const Units metric = Units(UnitSystem.metric);
  static const Units imperial = Units(UnitSystem.imperial);

  /// Resolves a [UnitsPreference] against the device's [localeName] (e.g. `Platform.localeName`).
  factory Units.resolve(UnitsPreference pref, {String? localeName}) => switch (pref) {
        UnitsPreference.metric => metric,
        UnitsPreference.imperial => imperial,
        UnitsPreference.auto => Units(unitSystemForCountry(countryFromLocaleName(localeName))),
      };

  bool get isImperial => system == UnitSystem.imperial;
  String get lengthUnit => isImperial ? 'ft' : 'm';
  String get speedUnit => isImperial ? 'mph' : 'km/h';
  String get longDistanceUnit => isImperial ? 'mi' : 'km';

  static String _trim(double v, int dp) {
    final s = v.toStringAsFixed(dp);
    return dp == 0 || !s.contains('.') ? s : s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// A distance: metric under 1 km in whole metres, then km (1 decimal below 10 km, none above). Imperial under
  /// 0.1 mi (528 ft) in feet rounded to 10, then miles (1 decimal below 10 mi). [approx] rounds metres to 10 for
  /// map labels and moves to km from 950 m.
  String distance(double metres, {bool approx = false}) {
    final m = metres.isFinite ? metres.abs() : 0.0;
    if (isImperial) {
      if (m < metresPerMile / 10) {
        final ft = (m / metresPerFoot / 10).round() * 10;
        if (ft < 530) return '$ft ft';
      }
      final mi = m / metresPerMile;
      return mi < 10 ? '${mi.toStringAsFixed(1)} mi' : '${mi.round()} mi';
    }
    if (approx) {
      if (m < 950) return '${(m / 10).round() * 10} m';
    } else if (m.round() < 1000) {
      return '${m.round()} m';
    }
    final km = m / 1000;
    final km1 = (km * 10).round() / 10; // round half up on the tenth (0.95 -> 1.0, not 0.9)
    return km < 9.95 ? '${km1.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  /// A large total (lifetime distance driven) as whole km or miles, digits grouped by [group] ("12,345 km").
  String total(double metres, String Function(int) group) {
    final m = metres.isFinite ? metres : 0.0;
    return isImperial ? '${group((m / metresPerMile).round())} mi' : '${group((m / 1000).round())} km';
  }

  /// A speed given in metres per second, whole numbers.
  String speed(double mps) {
    final v = mps.isFinite ? mps : 0.0;
    return isImperial ? '${(v * mphPerMps).round()} mph' : '${(v * kmhPerMps).round()} km/h';
  }

  /// A short length such as GPS accuracy or "move N more": whole metres or whole feet, never switching to km/mi.
  String shortLength(double metres) {
    final m = metres.isFinite ? metres : 0.0;
    return isImperial ? '${(m / metresPerFoot).round()} ft' : '${m.round()} m';
  }

  /// Antenna height / elevation: metres (up to 2 decimals, trimmed) or whole feet.
  String height(double metres) =>
      isImperial ? '${(metres / metresPerFoot).round()} ft' : '${_trim(metres, 2)} m';

  /// The height as the plain number a text field shows in this system.
  String heightNumber(double metres) => isImperial ? '${(metres / metresPerFoot).round()}' : _trim(metres, 2);

  /// Parses typed text to metres: `6ft`, `6 ft`, `1.8m`, `1,8`, or a bare number in this system's unit. Null when it
  /// is not a number.
  double? parseHeightToM(String text) {
    final t = text.trim().toLowerCase().replaceAll(',', '.');
    final m = RegExp(r'^(-?\d+(?:\.\d+)?|-?\.\d+)\s*(ft|feet|foot|m|meters|metres|meter|metre)?$').firstMatch(t);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || !v.isFinite) return null;
    final unit = m.group(2);
    final feet = unit == null ? isImperial : unit.startsWith('f');
    return feet ? v * metresPerFoot : v;
  }

  String get pressureUnit => isImperial ? 'inHg' : 'hPa';
  String get temperatureUnit => isImperial ? '°F' : '°C';

  /// Air pressure, stored in hPa: metric "987.4 hPa" (1 decimal), imperial "29.16 inHg" (2 decimals).
  String pressure(double hPa) {
    final v = hPa.isFinite ? hPa : 0.0;
    return isImperial ? '${(v * inHgPerHpa).toStringAsFixed(2)} inHg' : '${v.toStringAsFixed(1)} hPa';
  }

  /// The pressure as a plain number in this system's unit (hPa or inHg), for chart axes.
  double pressureValue(double hPa) => isImperial ? hPa * inHgPerHpa : hPa;

  /// A height as a plain number in this system's unit (metres or feet), for chart axes; [heightUnit] names it.
  double heightValue(double metres) => isImperial ? metres / metresPerFoot : metres;
  String get heightUnit => isImperial ? 'ft' : 'm';

  /// A temperature as a plain number in this system's unit (°C or °F), for chart axes.
  double temperatureValue(double celsius) => isImperial ? celsius * 9 / 5 + 32 : celsius;

  /// A temperature, stored in °C: whole degrees, "11 °C" or "52 °F".
  String temperature(double celsius) {
    final c = celsius.isFinite ? celsius : 0.0;
    final n = (isImperial ? c * 9 / 5 + 32 : c).round(); // an int: never "-0"
    return '$n ${isImperial ? '°F' : '°C'}';
  }

  /// Range rings drawn around the phone: 1 km and 2 km, or half a mile and a mile.
  List<double> get rangeRingMetres => isImperial ? const [metresPerMile / 2, metresPerMile] : const [1000, 2000];
  List<String> get rangeRingLabels => isImperial ? const ['0.5 mi', '1 mi'] : const ['1 km', '2 km'];

  /// The min-distance slider's stops, in whole metres: metric as-is, imperial as the nearest metre to round feet.
  List<int> minDistanceStops(List<int> metricStops) => isImperial
      ? const [50, 100, 150, 250, 300, 400, 500, 650, 800, 1000, 1300, 1600].map((ft) => (ft * metresPerFoot).round()).toList()
      : metricStops;

  /// Label for a stored distance in metres on the slider ("328 ft" or "100 m").
  String sliderDistance(int metres) {
    if (!isImperial) return '$metres m';
    final ft = metres / metresPerFoot;
    final snapped = ft < 1000 ? (ft / 10).round() * 10 : (ft / 100).round() * 100;
    return '$snapped ft';
  }
}
