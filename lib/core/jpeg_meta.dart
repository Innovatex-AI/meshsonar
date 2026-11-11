// JPEG metadata guard for photo messages. The compressor already re-encodes without EXIF; this second pass makes the
// privacy line hold even if a plugin version starts copying metadata: it drops every APP1 (EXIF, GPS, XMP), APP3..APP13,
// APP15 and COM segment, keeping only what decoding needs (APP0 JFIF, APP2 ICC colour profile, APP14 Adobe colour flags).
// Pure Dart: no Flutter imports.
import 'dart:typed_data';

/// True when [b] starts like a JPEG.
bool isJpeg(List<int> b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

/// [b] with the metadata segments removed. Returns [b] unchanged when it is not a JPEG or cannot be walked safely.
Uint8List stripJpegMetadata(List<int> b) {
  final src = b is Uint8List ? b : Uint8List.fromList(b);
  if (!isJpeg(src)) return src;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 2;
  while (i + 4 <= src.length) {
    if (src[i] != 0xFF) return src; // not a marker where one must be: leave the file alone
    final marker = src[i + 1];
    // Fill bytes (0xFF 0xFF ...) before a marker.
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      out.add([0xFF, marker]);
      i += 2;
      continue;
    }
    if (marker == 0xD9) {
      out.add(const [0xFF, 0xD9]);
      return out.takeBytes();
    }
    final len = (src[i + 2] << 8) | src[i + 3];
    if (len < 2 || i + 2 + len > src.length) return src;
    final seg = Uint8List.sublistView(src, i, i + 2 + len);
    if (marker == 0xDA) {
      // Start of scan: the rest (entropy-coded data, more scans, EOI) is image data; copy it as is.
      out.add(Uint8List.sublistView(src, i));
      return out.takeBytes();
    }
    if (_keep(marker, seg)) out.add(seg);
    i += 2 + len;
  }
  return src;
}

bool _keep(int marker, Uint8List seg) {
  if (marker == 0xFE) return false; // COM
  if (marker < 0xE0 || marker > 0xEF) return true; // DQT, SOFn, DHT, DRI, ... : image data
  if (marker == 0xE0) return true; // APP0 JFIF / JFXX
  if (marker == 0xEE) return true; // APP14 Adobe (colour transform)
  if (marker == 0xE2) return _startsWith(seg, 4, 'ICC_PROFILE'); // APP2: the colour profile only (not MPF / FlashPix)
  return false; // APP1 EXIF/XMP, APP13 IPTC, the rest
}

bool _startsWith(Uint8List seg, int at, String s) {
  if (seg.length < at + s.length) return false;
  for (var k = 0; k < s.length; k++) {
    if (seg[at + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}

/// True when the JPEG carries an EXIF (APP1 "Exif") or XMP segment before its image data.
bool jpegHasExif(List<int> b) => _appSegments(b).any((s) => s.marker == 0xE1);

/// True when an EXIF block of the JPEG has a GPS IFD pointer (tag 0x8825), or an XMP packet names GPS fields.
bool jpegHasGps(List<int> b) {
  for (final s in _appSegments(b)) {
    if (s.marker != 0xE1) continue;
    final d = s.data;
    if (_startsWith(d, 4, 'Exif')) {
      if (_findTag(d, 10, 0x8825)) return true;
    } else if (String.fromCharCodes(d).contains('GPS')) {
      return true;
    }
  }
  return false;
}

class _Seg {
  final int marker;
  final Uint8List data;
  _Seg(this.marker, this.data);
}

List<_Seg> _appSegments(List<int> b) {
  final src = b is Uint8List ? b : Uint8List.fromList(b);
  final out = <_Seg>[];
  if (!isJpeg(src)) return out;
  var i = 2;
  while (i + 4 <= src.length && src[i] == 0xFF) {
    final m = src[i + 1];
    if (m == 0xDA || m == 0xD9) break;
    if (m == 0xFF) {
      i++;
      continue;
    }
    final len = (src[i + 2] << 8) | src[i + 3];
    if (len < 2 || i + 2 + len > src.length) break;
    if (m >= 0xE0 && m <= 0xEF) out.add(_Seg(m, Uint8List.sublistView(src, i, i + 2 + len)));
    i += 2 + len;
  }
  return out;
}

/// Looks for [tag] in IFD0 of the TIFF block starting at [t] (byte order from its header).
bool _findTag(Uint8List d, int t, int tag) {
  if (d.length < t + 8) return false;
  final le = d[t] == 0x49 && d[t + 1] == 0x49;
  int u16(int o) => le ? d[o] | (d[o + 1] << 8) : (d[o] << 8) | d[o + 1];
  int u32(int o) => le ? d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24) : (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
  final ifd = t + u32(t + 4);
  if (ifd + 2 > d.length) return false;
  final n = u16(ifd);
  for (var k = 0; k < n; k++) {
    final e = ifd + 2 + k * 12;
    if (e + 12 > d.length) return false;
    if (u16(e) == tag) return true;
  }
  return false;
}
