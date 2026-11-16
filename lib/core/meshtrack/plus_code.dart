// Open Location Code ("Plus Code"), written in pure Dart from the published specification
// (github.com/google/open-location-code, docs/specification.md, Apache-2.0). Verified against the upstream test
// vectors copied to test/fixtures/olc/. Offline: nothing here calls any service.
//
// MeshTrack sends full (global) codes: 11 digits (about 3 x 3.5 m) by default, 8 digits (about 275 m) for the
// "Approximate" setting. The decoder takes any valid full code (2-15 digits, padded codes included).
//
// Pure Dart: no Flutter imports (lib/core layering rule).

/// The 20 characters of the code alphabet, in value order.
const String olcAlphabet = '23456789CFGHJMPQRVWX';
const String olcSeparator = '+';
const String olcPadding = '0';
const int _sepPos = 8;
const int _pairLen = 10;
const int _gridLen = 5;
const int _maxDigits = 15;
const int _base = 20;
const int _gridRows = 5;
const int _gridCols = 4;
const int _latMax = 90;
const int _lngMax = 180;
const int _pairPrecision = 8000; // base^3
const int _pairFirstPlace = 160000; // base^(pairLen/2 - 1)
const int _gridLatFirstPlace = 625; // rows^(gridLen - 1)
const int _gridLngFirstPlace = 256; // cols^(gridLen - 1)
const int _finalLatPrecision = 25000000; // pairPrecision * rows^gridLen
const int _finalLngPrecision = 8192000; // pairPrecision * cols^gridLen
const int _minTrimmable = 6;
const List<double> _pairResolutions = [20.0, 1.0, .05, .0025, .000125];

/// Digit count MeshTrack sends by default ("Exact").
const int kPlusCodeExactDigits = 11;

/// Digit count of the "Approximate" setting.
const int kPlusCodeApproxDigits = 8;

int _val(int codeUnit) {
  // Upper-case ASCII letters; anything else maps to -1.
  var c = codeUnit;
  if (c >= 0x61 && c <= 0x7a) c -= 0x20;
  return olcAlphabet.indexOf(String.fromCharCode(c));
}

/// The area a code stands for. [lat]/[lon] are its centre (the position MeshTrack shows); the size is the
/// uncertainty.
class PlusCodeArea {
  final double latLo;
  final double lonLo;
  final double latHi;
  final double lonHi;

  /// Significant digits (padding and the separator not counted).
  final int codeLength;
  const PlusCodeArea(this.latLo, this.lonLo, this.latHi, this.lonHi, this.codeLength);

  double get lat => (latLo + latHi) / 2 > _latMax ? _latMax.toDouble() : (latLo + latHi) / 2;
  double get lon => (lonLo + lonHi) / 2 > _lngMax ? _lngMax.toDouble() : (lonLo + lonHi) / 2;

  /// Height of the area in metres (latitude extent).
  double get heightM => (latHi - latLo) * 111320.0;

  @override
  String toString() => 'PlusCodeArea(len $codeLength)';
}

/// Plus Code functions. All static; never throws from [tryDecode] / [isValid] / [isFull] / [isShort].
abstract final class PlusCode {
  /// True when [code] is a syntactically valid code (full or short).
  static bool isValid(String code) {
    if (code.isEmpty) return false;
    final sep = code.indexOf(olcSeparator);
    if (sep == -1 || sep != code.lastIndexOf(olcSeparator)) return false;
    if (code.length == 1) return false;
    if (sep > _sepPos || sep.isOdd) return false;
    final pad = code.indexOf(olcPadding);
    if (pad > -1) {
      if (sep < _sepPos) return false;
      if (pad == 0) return false;
      // One run of padding, even length, ending at the separator, and nothing after the separator.
      var end = pad;
      while (end < code.length && code[end] == olcPadding) {
        end++;
      }
      final runLen = end - pad;
      if (code.indexOf(olcPadding, end) != -1) return false;
      if (runLen.isOdd || runLen > _sepPos - 2) return false;
      if (!code.endsWith(olcSeparator)) return false;
    }
    if (code.length - sep - 1 == 1) return false;
    for (var i = 0; i < code.length; i++) {
      final ch = code.codeUnitAt(i);
      if (ch == 0x2b || ch == 0x30) continue;
      if (_val(ch) < 0) return false;
    }
    return true;
  }

  /// True when [code] is valid and short (some leading digits removed; needs a reference to recover).
  static bool isShort(String code) {
    if (!isValid(code)) return false;
    final sep = code.indexOf(olcSeparator);
    return sep >= 0 && sep < _sepPos;
  }

  /// True when [code] is a valid full (global) code.
  static bool isFull(String code) {
    if (!isValid(code) || isShort(code)) return false;
    if (_val(code.codeUnitAt(0)) * _base >= _latMax * 2) return false;
    if (code.length > 1 && code[1] != olcSeparator && code[1] != olcPadding) {
      if (_val(code.codeUnitAt(1)) * _base >= _lngMax * 2) return false;
    }
    return true;
  }

  /// Latitude/longitude to the integer grid the spec encodes (clipped latitude, wrapped longitude).
  static (int, int) locationToIntegers(double lat, double lon) {
    var latVal = _toInt(lat * _finalLatPrecision);
    latVal += _latMax * _finalLatPrecision;
    if (latVal < 0) {
      latVal = 0;
    } else if (latVal >= 2 * _latMax * _finalLatPrecision) {
      latVal = 2 * _latMax * _finalLatPrecision - 1;
    }
    var lngVal = _toInt(lon * _finalLngPrecision);
    lngVal += _lngMax * _finalLngPrecision;
    const lngSpan = 2 * _lngMax * _finalLngPrecision;
    lngVal %= lngSpan; // Dart % is non-negative for a positive divisor
    return (latVal, lngVal);
  }

  /// Encodes [lat]/[lon] to a full code of [codeLength] digits (2, 4, 6, 8, or 10..15; longer is cut to 15).
  /// Throws [ArgumentError] for a bad length or a non-finite coordinate.
  static String encode(double lat, double lon, {int codeLength = kPlusCodeExactDigits}) {
    if (!lat.isFinite || !lon.isFinite) throw ArgumentError('coordinate not finite');
    final (la, lo) = locationToIntegers(lat, lon);
    return encodeIntegers(la, lo, codeLength);
  }

  /// Encodes the integer grid values from [locationToIntegers].
  static String encodeIntegers(int latVal, int lngVal, int codeLength) {
    if (codeLength < 2 || (codeLength < _pairLen && codeLength.isOdd)) {
      throw ArgumentError('invalid code length $codeLength');
    }
    final len = codeLength > _maxDigits ? _maxDigits : codeLength;
    final out = List<String>.filled(_maxDigits, '');
    var la = latVal, lo = lngVal;
    if (len > _pairLen) {
      for (var i = 0; i < _maxDigits - _pairLen; i++) {
        final latDigit = la % _gridRows;
        final lngDigit = lo % _gridCols;
        out[_maxDigits - 1 - i] = olcAlphabet[latDigit * _gridCols + lngDigit];
        la ~/= _gridRows;
        lo ~/= _gridCols;
      }
    } else {
      la ~/= 3125; // rows^gridLen
      lo ~/= 1024; // cols^gridLen
    }
    for (var i = 0; i < _pairLen ~/ 2; i++) {
      out[_pairLen - 1 - 2 * i] = olcAlphabet[lo % _base];
      out[_pairLen - 2 - 2 * i] = olcAlphabet[la % _base];
      la ~/= _base;
      lo ~/= _base;
    }
    final digits = out.join();
    final full = '${digits.substring(0, _sepPos)}$olcSeparator${digits.substring(_sepPos)}';
    if (len >= _sepPos) return full.substring(0, len + 1);
    return '${full.substring(0, len)}${olcPadding * (_sepPos - len)}$olcSeparator';
  }

  /// Decodes a full code; null when [code] is not a valid full code. Never throws.
  static PlusCodeArea? tryDecode(String code) {
    if (!isFull(code)) return null;
    final buf = StringBuffer();
    for (var i = 0; i < code.length; i++) {
      final ch = code[i];
      if (ch == olcSeparator || ch == olcPadding) continue;
      buf.write(ch.toUpperCase());
    }
    var clean = buf.toString();
    if (clean.length > _maxDigits) clean = clean.substring(0, _maxDigits);
    var normalLat = -_latMax * _pairPrecision;
    var normalLng = -_lngMax * _pairPrecision;
    var gridLat = 0, gridLng = 0;
    final pairDigits = clean.length < _pairLen ? clean.length : _pairLen;
    var pv = _pairFirstPlace;
    for (var i = 0; i < pairDigits; i += 2) {
      normalLat += _val(clean.codeUnitAt(i)) * pv;
      normalLng += _val(clean.codeUnitAt(i + 1)) * pv;
      if (i < pairDigits - 2) pv ~/= _base;
    }
    var latPrecision = pv / _pairPrecision;
    var lngPrecision = pv / _pairPrecision;
    if (clean.length > _pairLen) {
      var rowpv = _gridLatFirstPlace;
      var colpv = _gridLngFirstPlace;
      final digits = clean.length;
      for (var i = _pairLen; i < digits; i++) {
        final d = _val(clean.codeUnitAt(i));
        gridLat += (d ~/ _gridCols) * rowpv;
        gridLng += (d % _gridCols) * colpv;
        if (i < digits - 1) {
          rowpv ~/= _gridRows;
          colpv ~/= _gridCols;
        }
      }
      latPrecision = rowpv / _finalLatPrecision;
      lngPrecision = colpv / _finalLngPrecision;
    }
    final lat = normalLat / _pairPrecision + gridLat / _finalLatPrecision;
    final lng = normalLng / _pairPrecision + gridLng / _finalLngPrecision;
    double r(double v) => (v * 1e14).roundToDouble() / 1e14;
    return PlusCodeArea(r(lat), r(lng), r(lat + latPrecision), r(lng + lngPrecision), clean.length);
  }

  /// Recovers a short code (e.g. `Q2X5+7F`) to the full code nearest the reference point. A full code comes back
  /// upper-cased; null when [code] is neither.
  static String? recoverNearest(String code, double refLat, double refLon) {
    if (!isShort(code)) return isFull(code) ? code.toUpperCase() : null;
    if (!refLat.isFinite || !refLon.isFinite) return null;
    final rLat = refLat.clamp(-90.0, 90.0);
    var rLon = refLon;
    while (rLon < -180) {
      rLon += 360;
    }
    while (rLon >= 180) {
      rLon -= 360;
    }
    final up = code.toUpperCase();
    final paddingLength = _sepPos - up.indexOf(olcSeparator);
    final resolution = _pow20(2 - paddingLength ~/ 2);
    final half = resolution / 2.0;
    final area = tryDecode(encode(rLat, rLon).substring(0, paddingLength) + up);
    if (area == null) return null;
    var cLat = area.lat, cLon = area.lon;
    if (rLat + half < cLat && cLat - resolution >= -_latMax) {
      cLat -= resolution;
    } else if (rLat - half > cLat && cLat + resolution <= _latMax) {
      cLat += resolution;
    }
    if (rLon + half < cLon) {
      cLon -= resolution;
    } else if (rLon - half > cLon) {
      cLon += resolution;
    }
    return encode(cLat, cLon, codeLength: area.codeLength);
  }

  /// Removes as many leading digits as the reference point allows (the inverse of [recoverNearest]).
  /// Returns [code] unchanged when it cannot be shortened; null when it is not a full unpadded code.
  static String? shorten(String code, double lat, double lon) {
    if (!isFull(code) || code.contains(olcPadding)) return null;
    final up = code.toUpperCase();
    final area = tryDecode(up);
    if (area == null || area.codeLength < _minTrimmable) return null;
    final range = [(area.lat - lat.clamp(-90.0, 90.0)).abs(), (area.lon - lon).abs()].reduce((a, b) => a > b ? a : b);
    for (var i = _pairResolutions.length - 2; i >= 1; i--) {
      if (range < _pairResolutions[i] * 0.3) return up.substring((i + 1) * 2);
    }
    return up;
  }

  // floor(round(x * 1e6) / 1e6): the reference implementations round away float noise (40.6 * 2.5e7 =
  // 1014999999.9999999) before taking the floor, so every implementation lands on the same integer.
  static int _toInt(double x) => ((x * 1e6).roundToDouble() / 1e6).floor();

  static double _pow20(int e) {
    var v = 1.0;
    if (e >= 0) {
      for (var i = 0; i < e; i++) {
        v *= 20;
      }
    } else {
      for (var i = 0; i < -e; i++) {
        v /= 20;
      }
    }
    return v;
  }
}
