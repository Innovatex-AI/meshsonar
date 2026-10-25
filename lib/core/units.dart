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

/// Millimetres in an inch (rain depth in imperial).
const double mmPerInch = 25.4;

/// Inches of mercury per hectopascal (1 inHg = 33.8638866667 hPa, at 0 °C).
const double inHgPerHpa = 1 / 33.8638866667;

/// Millimetres of mercury per hectopascal (1 mmHg = 1.33322387415 hPa).
const double mmHgPerHpa = 1 / 1.33322387415;

/// A per-quantity override of the Units setting (Settings > Units & display > "More unit choices"). [follow] = use
/// the Units setting (Auto / Metric / Imperial); the default for every quantity.
enum UnitChoice {
  follow,
  metric,
  imperial;

  static UnitChoice parse(Object? v) => UnitChoice.values.firstWhere((e) => e.name == v, orElse: () => UnitChoice.follow);
}

/// The air-pressure unit a reading is shown in.
enum PressureUnit { hPa, inHg, mmHg }

/// The pressure override: [follow] = hPa for metric, inHg for imperial; or one fixed unit.
enum PressureChoice {
  follow,
  hPa,
  inHg,
  mmHg;

  static PressureChoice parse(Object? v) =>
      PressureChoice.values.firstWhere((e) => e.name == v, orElse: () => PressureChoice.follow);
}

/// Per-quantity unit overrides. Stored in settings.json as `unit_overrides`, an object holding only the quantities
/// that do not follow the Units setting (`{"speed": "imperial", "pressure": "mmHg"}`); missing keys, unknown keys
/// and unknown values all mean "follow", so old and newer files load.
class UnitOverrides {
  /// Distances and short lengths (km/mi, m/ft): drive distance, GPS accuracy, "move N more", range rings.
  final UnitChoice distance;
  final UnitChoice speed;

  /// Heights and altitudes (antenna height, GPS altitude): m or ft.
  final UnitChoice height;
  final UnitChoice temperature;
  final PressureChoice pressure;

  const UnitOverrides({
    this.distance = UnitChoice.follow,
    this.speed = UnitChoice.follow,
    this.height = UnitChoice.follow,
    this.temperature = UnitChoice.follow,
    this.pressure = PressureChoice.follow,
  });

  /// True when every quantity follows the Units setting.
  bool get isEmpty =>
      distance == UnitChoice.follow &&
      speed == UnitChoice.follow &&
      height == UnitChoice.follow &&
      temperature == UnitChoice.follow &&
      pressure == PressureChoice.follow;

  UnitOverrides copyWith({UnitChoice? distance, UnitChoice? speed, UnitChoice? height, UnitChoice? temperature, PressureChoice? pressure}) =>
      UnitOverrides(
        distance: distance ?? this.distance,
        speed: speed ?? this.speed,
        height: height ?? this.height,
        temperature: temperature ?? this.temperature,
        pressure: pressure ?? this.pressure,
      );

  Map<String, String> toJson() => {
        if (distance != UnitChoice.follow) 'distance': distance.name,
        if (speed != UnitChoice.follow) 'speed': speed.name,
        if (height != UnitChoice.follow) 'height': height.name,
        if (temperature != UnitChoice.follow) 'temperature': temperature.name,
        if (pressure != PressureChoice.follow) 'pressure': pressure.name,
      };

  /// Anything that is not a JSON object (missing, null, a string) is "no overrides".
  factory UnitOverrides.fromJson(Object? raw) {
    if (raw is! Map) return const UnitOverrides();
    return UnitOverrides(
      distance: UnitChoice.parse(raw['distance']),
      speed: UnitChoice.parse(raw['speed']),
      height: UnitChoice.parse(raw['height']),
      temperature: UnitChoice.parse(raw['temperature']),
      pressure: PressureChoice.parse(raw['pressure']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UnitOverrides &&
      other.distance == distance &&
      other.speed == speed &&
      other.height == height &&
      other.temperature == temperature &&
      other.pressure == pressure;

  @override
  int get hashCode => Object.hash(distance, speed, height, temperature, pressure);
}

/// "a", "a and b", "a, b and c".
String joinAnd(List<String> parts) => parts.length <= 1
    ? parts.join()
    : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';

class Units {
  /// The Units setting resolved (Auto already turned into metric or imperial). Quantities without an override use it.
  final UnitSystem system;

  /// Per-quantity overrides; empty by default, so `Units(UnitSystem.imperial)` is all-imperial as before.
  final UnitOverrides overrides;
  const Units(this.system, [this.overrides = const UnitOverrides()]);

  static const Units metric = Units(UnitSystem.metric);
  static const Units imperial = Units(UnitSystem.imperial);

  /// Resolves a [UnitsPreference] against the device's [localeName] (e.g. `Platform.localeName`), then applies the
  /// per-quantity [overrides].
  factory Units.resolve(UnitsPreference pref, {String? localeName, UnitOverrides overrides = const UnitOverrides()}) =>
      Units(
          switch (pref) {
            UnitsPreference.metric => UnitSystem.metric,
            UnitsPreference.imperial => UnitSystem.imperial,
            UnitsPreference.auto => unitSystemForCountry(countryFromLocaleName(localeName)),
          },
          overrides);

  UnitSystem _pick(UnitChoice c) => switch (c) {
        UnitChoice.follow => system,
        UnitChoice.metric => UnitSystem.metric,
        UnitChoice.imperial => UnitSystem.imperial,
      };

  /// True when distances show in miles and feet, the headline quantity (with no overrides: the Units setting).
  /// Existing call sites use it for distance wording ("Miles driven", range-ring labels). The Units setting itself is
  /// [system]; "Units: ..." labels use [description].
  bool get isImperial => distanceImperial;

  bool get _baseImperial => system == UnitSystem.imperial;

  /// Distances and short lengths in miles / feet.
  bool get distanceImperial => _pick(overrides.distance) == UnitSystem.imperial;
  bool get speedImperial => _pick(overrides.speed) == UnitSystem.imperial;

  /// Heights and altitudes in feet.
  bool get heightImperial => _pick(overrides.height) == UnitSystem.imperial;
  bool get temperatureImperial => _pick(overrides.temperature) == UnitSystem.imperial;

  /// The unit air pressure is shown in.
  PressureUnit get pressureUnitKind => switch (overrides.pressure) {
        PressureChoice.follow => _baseImperial ? PressureUnit.inHg : PressureUnit.hPa,
        PressureChoice.hPa => PressureUnit.hPa,
        PressureChoice.inHg => PressureUnit.inHg,
        PressureChoice.mmHg => PressureUnit.mmHg,
      };

  /// Short distances (GPS accuracy, "move N more"): m or ft.
  String get lengthUnit => distanceImperial ? 'ft' : 'm';
  String get speedUnit => speedImperial ? 'mph' : 'km/h';
  String get longDistanceUnit => distanceImperial ? 'mi' : 'km';

  /// Heights and altitudes: m or ft.
  String get heightUnit => heightImperial ? 'ft' : 'm';

  /// Metres per [longDistanceUnit] (1000 or a mile), for charts that plot distances as plain numbers.
  double get metresPerLongUnit => distanceImperial ? metresPerMile : 1000;

  /// The quantities shown differently from the Units setting, as "speed in mph" phrases; empty when none.
  List<String> get exceptions => [
        if (distanceImperial != _baseImperial) 'distance in $longDistanceUnit',
        if (speedImperial != _baseImperial) 'speed in $speedUnit',
        if (heightImperial != _baseImperial) 'height in $heightUnit',
        if (temperatureImperial != _baseImperial) 'temperature in $temperatureUnit',
        if (pressureUnitKind != (_baseImperial ? PressureUnit.inHg : PressureUnit.hPa)) 'pressure in $pressureUnit',
      ];

  /// True when at least one quantity is shown in a different system than the Units setting.
  bool get isMixed => exceptions.isNotEmpty;

  /// "metric", "imperial", or "metric, with speed in mph and temperature in °F" for reports and exports.
  String get description {
    final base = _baseImperial ? 'imperial' : 'metric';
    final ex = exceptions;
    if (ex.isEmpty) return base;
    return '$base, with ${joinAnd(ex)}';
  }

  static String _trim(double v, int dp) {
    final s = v.toStringAsFixed(dp);
    return dp == 0 || !s.contains('.') ? s : s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// A distance: metric under 1 km in whole metres, then km (1 decimal below 10 km, none above). Imperial under
  /// 0.1 mi (528 ft) in feet rounded to 10, then miles (1 decimal below 10 mi). [approx] rounds metres to 10 for
  /// map labels and moves to km from 950 m.
  String distance(double metres, {bool approx = false}) {
    final m = metres.isFinite ? metres.abs() : 0.0;
    if (distanceImperial) {
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
    return distanceImperial ? '${group((m / metresPerMile).round())} mi' : '${group((m / 1000).round())} km';
  }

  /// A speed given in metres per second, whole numbers.
  String speed(double mps) {
    final v = mps.isFinite ? mps : 0.0;
    return speedImperial ? '${(v * mphPerMps).round()} mph' : '${(v * kmhPerMps).round()} km/h';
  }

  /// A speed as a plain number in the speed unit ([speedUnit]: km/h or mph), for chart axes.
  double speedValue(double mps) => speedImperial ? mps * mphPerMps : mps * kmhPerMps;

  /// Rain / melted-snow depth follows the distance choice: millimetres, or inches.
  String get precipitationUnit => distanceImperial ? 'in' : 'mm';

  /// Depth stored in millimetres as a plain number in [precipitationUnit].
  double precipitationValue(double mm) => distanceImperial ? mm / mmPerInch : mm;

  /// Precipitation over an hour or a drive, stored in mm: "0 mm", "0.4 mm" (1 decimal, trimmed) or "0.02 in" (2 decimals).
  String precipitation(double mm) {
    final v = mm.isFinite && mm > 0 ? mm : 0.0;
    return distanceImperial ? '${(v / mmPerInch).toStringAsFixed(2)} in' : '${_trim(v, 1)} mm';
  }

  /// A short length such as GPS accuracy or "move N more": whole metres or whole feet, never switching to km/mi.
  String shortLength(double metres) {
    final m = metres.isFinite ? metres : 0.0;
    return distanceImperial ? '${(m / metresPerFoot).round()} ft' : '${m.round()} m';
  }

  /// Antenna height / elevation: metres (up to 2 decimals, trimmed) or whole feet.
  String height(double metres) =>
      heightImperial ? '${(metres / metresPerFoot).round()} ft' : '${_trim(metres, 2)} m';

  /// The height as the plain number a text field shows in this system.
  String heightNumber(double metres) => heightImperial ? '${(metres / metresPerFoot).round()}' : _trim(metres, 2);

  /// Parses typed text to metres: `6ft`, `6 ft`, `1.8m`, `1,8`, or a bare number in this system's unit. Null when it
  /// is not a number.
  double? parseHeightToM(String text) {
    final t = text.trim().toLowerCase().replaceAll(',', '.');
    final m = RegExp(r'^(-?\d+(?:\.\d+)?|-?\.\d+)\s*(ft|feet|foot|m|meters|metres|meter|metre)?$').firstMatch(t);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || !v.isFinite) return null;
    final unit = m.group(2);
    final feet = unit == null ? heightImperial : unit.startsWith('f');
    return feet ? v * metresPerFoot : v;
  }

  String get pressureUnit => pressureUnitKind.name;
  String get temperatureUnit => temperatureImperial ? '°F' : '°C';

  /// Air pressure, stored in hPa: "987.4 hPa" (1 decimal), "29.16 inHg" (2 decimals) or "741 mmHg" (whole).
  String pressure(double hPa) {
    final v = hPa.isFinite ? hPa : 0.0;
    return switch (pressureUnitKind) {
      PressureUnit.hPa => '${v.toStringAsFixed(1)} hPa',
      PressureUnit.inHg => '${(v * inHgPerHpa).toStringAsFixed(2)} inHg',
      PressureUnit.mmHg => '${(v * mmHgPerHpa).round()} mmHg',
    };
  }

  /// A pressure DIFFERENCE (no sign), stored in hPa: "1.3 hPa", "0.04 inHg" or "1.0 mmHg".
  String pressureDelta(double hPa) {
    final v = hPa.isFinite ? hPa.abs() : 0.0;
    return switch (pressureUnitKind) {
      PressureUnit.hPa => '${v.toStringAsFixed(1)} hPa',
      PressureUnit.inHg => '${(v * inHgPerHpa).toStringAsFixed(2)} inHg',
      PressureUnit.mmHg => '${(v * mmHgPerHpa).toStringAsFixed(1)} mmHg',
    };
  }

  /// The pressure as a plain number in the pressure unit ([pressureUnit]: hPa, inHg or mmHg), for chart axes.
  double pressureValue(double hPa) => switch (pressureUnitKind) {
        PressureUnit.hPa => hPa,
        PressureUnit.inHg => hPa * inHgPerHpa,
        PressureUnit.mmHg => hPa * mmHgPerHpa,
      };

  /// A height as a plain number in the height unit (metres or feet), for chart axes; [heightUnit] names it.
  double heightValue(double metres) => heightImperial ? metres / metresPerFoot : metres;

  /// A temperature as a plain number in the temperature unit (°C or °F), for chart axes.
  double temperatureValue(double celsius) => temperatureImperial ? celsius * 9 / 5 + 32 : celsius;

  /// A temperature, stored in °C: whole degrees, "11 °C" or "52 °F".
  String temperature(double celsius) {
    final c = celsius.isFinite ? celsius : 0.0;
    final n = (temperatureImperial ? c * 9 / 5 + 32 : c).round(); // an int: never "-0"
    return '$n ${temperatureImperial ? '°F' : '°C'}';
  }

  /// Range rings drawn around the phone: 1 km and 2 km, or half a mile and a mile.
  List<double> get rangeRingMetres => distanceImperial ? const [metresPerMile / 2, metresPerMile] : const [1000, 2000];
  List<String> get rangeRingLabels => distanceImperial ? const ['0.5 mi', '1 mi'] : const ['1 km', '2 km'];

  /// The min-distance slider's stops, in whole metres: metric as-is, imperial as the nearest metre to round feet.
  List<int> minDistanceStops(List<int> metricStops) => distanceImperial
      ? const [50, 100, 150, 250, 300, 400, 500, 650, 800, 1000, 1300, 1600].map((ft) => (ft * metresPerFoot).round()).toList()
      : metricStops;

  /// Label for a stored distance in metres on the slider ("328 ft" or "100 m").
  String sliderDistance(int metres) {
    if (!distanceImperial) return '$metres m';
    final ft = metres / metresPerFoot;
    final snapped = ft < 1000 ? (ft / 10).round() * 10 : (ft / 100).round() * 100;
    return '$snapped ft';
  }
}
