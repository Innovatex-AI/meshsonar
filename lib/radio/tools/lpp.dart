// Cayenne LPP decoding for the Telemetry tool. MeshCore's sensor manager writes electroniccats/CayenneLPP records
// [channel][type][data], and the data is BIG endian (VERIFIED on hardware, Nov 1 2026: voltage 3.86 V and MCU temperature
// 45.0 C from a repeater; read little endian the same bytes give 332 V and -1843 C). Sizes and scales follow the library.
// Unknown type = stop (its size is unknown, so nothing after it can be trusted). Pure Dart.
import 'dart:typed_data';

enum LppKind { voltage, temperature, humidity, pressure, gps, altitude, current, power, luminosity, percentage, other }

class LppReading {
  final int channel;
  final int type;
  final LppKind kind;
  final String label;
  final double? value;
  final String unit;

  /// GPS only.
  final double? lat, lon, altitudeM;
  const LppReading(this.channel, this.type, this.kind, this.label, this.value, this.unit, {this.lat, this.lon, this.altitudeM});

  String get text {
    if (kind == LppKind.gps) return '${lat!.toStringAsFixed(5)}, ${lon!.toStringAsFixed(5)}';
    final v = value!;
    final digits = switch (kind) { LppKind.voltage => 2, LppKind.pressure => 1, LppKind.humidity => 1, LppKind.temperature => 1, _ => v == v.roundToDouble() ? 0 : 2 };
    return '${v.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}';
  }
}

const Map<int, int> lppSizes = {
  0: 1, 1: 1, 2: 2, 3: 2, 100: 4, 101: 2, 102: 1, 103: 2, 104: 1, 113: 6, 115: 2, 116: 2, 117: 2, 118: 4, 120: 1,
  121: 2, 125: 2, 128: 2, 130: 4, 131: 4, 132: 2, 133: 4, 134: 6, 135: 3, 136: 9, 142: 1,
};

int _s24(ByteData bd, int at) {
  final v = (bd.getUint8(at) << 16) | (bd.getUint8(at + 1) << 8) | bd.getUint8(at + 2);
  return v & 0x800000 != 0 ? v - 0x1000000 : v;
}

/// All readings in [lpp]; stops at the first unknown type, a truncated record, or the zero padding the radio adds (a
/// record on channel 0 type 0 with value 0 is padding when it is the last thing in the frame).
List<LppReading> decodeLpp(Uint8List lpp) {
  final out = <LppReading>[];
  final bd = ByteData.sublistView(lpp);
  var i = 0;
  while (i + 2 <= lpp.length) {
    final ch = lpp[i], type = lpp[i + 1];
    final size = lppSizes[type];
    if (size == null || i + 2 + size > lpp.length) break;
    final at = i + 2;
    i += 2 + size;
    // The reply is zero padded to 16-byte blocks: [0][0][0] runs are padding, not a digital input.
    if (ch == 0 && type == 0 && bd.getUint8(at) == 0 && lpp.sublist(i).every((b) => b == 0)) break;
    switch (type) {
      case 116:
        out.add(LppReading(ch, type, LppKind.voltage, 'Voltage', bd.getUint16(at, Endian.big) / 100, 'V'));
      case 103:
        out.add(LppReading(ch, type, LppKind.temperature, 'Temperature', bd.getInt16(at, Endian.big) / 10, '°C'));
      case 104:
        out.add(LppReading(ch, type, LppKind.humidity, 'Humidity', bd.getUint8(at) / 2, '%'));
      case 115:
        out.add(LppReading(ch, type, LppKind.pressure, 'Pressure', bd.getUint16(at, Endian.big) / 10, 'hPa'));
      case 136:
        out.add(LppReading(ch, type, LppKind.gps, 'Position', null, '',
            lat: _s24(bd, at) / 10000, lon: _s24(bd, at + 3) / 10000, altitudeM: _s24(bd, at + 6) / 100));
      case 121:
        out.add(LppReading(ch, type, LppKind.altitude, 'Altitude', bd.getInt16(at, Endian.big).toDouble(), 'm'));
      case 117:
        out.add(LppReading(ch, type, LppKind.current, 'Current', bd.getUint16(at, Endian.big) / 1000, 'A'));
      case 128:
        out.add(LppReading(ch, type, LppKind.power, 'Power', bd.getUint16(at, Endian.big).toDouble(), 'W'));
      case 101:
        out.add(LppReading(ch, type, LppKind.luminosity, 'Light', bd.getUint16(at, Endian.big).toDouble(), 'lx'));
      case 120:
        out.add(LppReading(ch, type, LppKind.percentage, 'Percentage', bd.getUint8(at).toDouble(), '%'));
      case 2:
        out.add(LppReading(ch, type, LppKind.other, 'Analog input', bd.getInt16(at, Endian.big) / 100, ''));
      case 3:
        out.add(LppReading(ch, type, LppKind.other, 'Analog output', bd.getInt16(at, Endian.big) / 100, ''));
      case 125:
        out.add(LppReading(ch, type, LppKind.other, 'Concentration', bd.getUint16(at, Endian.big).toDouble(), 'ppm'));
      case 130:
        out.add(LppReading(ch, type, LppKind.other, 'Distance', bd.getUint32(at, Endian.big) / 1000, 'm'));
      case 132:
        out.add(LppReading(ch, type, LppKind.other, 'Direction', bd.getUint16(at, Endian.big).toDouble(), '°'));
      case 118:
        out.add(LppReading(ch, type, LppKind.other, 'Frequency', bd.getUint32(at, Endian.big).toDouble(), 'Hz'));
      case 0 || 1 || 142:
        out.add(LppReading(ch, type, LppKind.other, type == 0 ? 'Digital input' : (type == 1 ? 'Digital output' : 'Switch'), bd.getUint8(at).toDouble(), ''));
      default:
        break; // known size, not worth a row (accelerometer, colour, time, energy ...)
    }
  }
  return out;
}

/// Encoders for fakes: a voltage record, a temperature record, a GPS record (channel [ch]).
List<int> lppVoltage(double v, {int ch = 1}) {
  final x = (v * 100).round();
  return [ch, 116, (x >> 8) & 0xff, x & 0xff];
}

List<int> lppTemperature(double c, {int ch = 1}) {
  final x = (c * 10).round() & 0xffff;
  return [ch, 103, (x >> 8) & 0xff, x & 0xff];
}

List<int> lppHumidity(double pct, {int ch = 2}) => [ch, 104, (pct * 2).round()];

List<int> lppGps(double lat, double lon, double altM, {int ch = 1}) {
  List<int> s24(int v) => [(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
  return [ch, 136, ...s24((lat * 10000).round()), ...s24((lon * 10000).round()), ...s24((altM * 100).round())];
}
