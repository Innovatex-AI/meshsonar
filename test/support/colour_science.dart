// Colour-vision simulation and colour difference for the palette tests. Method (also written in docs/FEATURES.md):
// sRGB -> linear RGB -> the Machado, Oliveira & Fernandes (2009) severity-1.0 matrix for protanopia, deuteranopia or
// tritanopia (applied in linear RGB, clipped to 0..1) -> CIE Lab (D65) -> CIEDE2000 (Sharma, Wu & Dalal 2005).
import 'dart:math' as math;
import 'dart:ui' show Color;

enum Vision { normal, protan, deutan, tritan }

const _matrices = <Vision, List<double>>{
  Vision.normal: [1, 0, 0, 0, 1, 0, 0, 0, 1],
  Vision.protan: [0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998],
  Vision.deutan: [0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881],
  Vision.tritan: [1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900],
};

double _lin(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// CIE Lab (D65) of [c] as seen with [v].
List<double> labOf(Color c, Vision v) {
  final rgb = [_lin(c.r), _lin(c.g), _lin(c.b)];
  final m = _matrices[v]!;
  final s = [
    for (var i = 0; i < 3; i++) (m[i * 3] * rgb[0] + m[i * 3 + 1] * rgb[1] + m[i * 3 + 2] * rgb[2]).clamp(0.0, 1.0),
  ];
  final x = 0.4124564 * s[0] + 0.3575761 * s[1] + 0.1804375 * s[2];
  final y = 0.2126729 * s[0] + 0.7151522 * s[1] + 0.0721750 * s[2];
  final z = 0.0193339 * s[0] + 0.1191920 * s[1] + 0.9503041 * s[2];
  double f(double t) => t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (24389 / 27 * t + 16) / 116;
  final fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

double _deg(double r) => r * 180 / math.pi;
double _rad(double d) => d * math.pi / 180;

/// CIEDE2000 between two Lab triples.
double ciede2000(List<double> a, List<double> b) {
  final l1 = a[0], a1 = a[1], b1 = a[2];
  final l2 = b[0], a2 = b[1], b2 = b[2];
  final c1 = math.sqrt(a1 * a1 + b1 * b1), c2 = math.sqrt(a2 * a2 + b2 * b2);
  final cb = (c1 + c2) / 2;
  final g = 0.5 * (1 - math.sqrt(math.pow(cb, 7) / (math.pow(cb, 7) + math.pow(25, 7))));
  final a1p = (1 + g) * a1, a2p = (1 + g) * a2;
  final c1p = math.sqrt(a1p * a1p + b1 * b1), c2p = math.sqrt(a2p * a2p + b2 * b2);
  double hue(double bb, double ap) => (bb == 0 && ap == 0) ? 0 : (_deg(math.atan2(bb, ap)) + 360) % 360;
  final h1 = hue(b1, a1p), h2 = hue(b2, a2p);
  final dl = l2 - l1, dc = c2p - c1p;
  var dh = 0.0;
  if (c1p * c2p != 0) {
    dh = h2 - h1;
    if (dh > 180) dh -= 360;
    if (dh < -180) dh += 360;
  }
  final dH = 2 * math.sqrt(c1p * c2p) * math.sin(_rad(dh / 2));
  final lb = (l1 + l2) / 2, cbp = (c1p + c2p) / 2;
  var hb = h1 + h2;
  if (c1p * c2p != 0) {
    hb = (h1 + h2) / 2;
    if ((h1 - h2).abs() > 180) hb += h1 + h2 < 360 ? 180 : -180;
  }
  final t = 1 -
      0.17 * math.cos(_rad(hb - 30)) +
      0.24 * math.cos(_rad(2 * hb)) +
      0.32 * math.cos(_rad(3 * hb + 6)) -
      0.2 * math.cos(_rad(4 * hb - 63));
  final dth = 30 * math.exp(-math.pow((hb - 275) / 25, 2));
  final rc = 2 * math.sqrt(math.pow(cbp, 7) / (math.pow(cbp, 7) + math.pow(25, 7)));
  final sl = 1 + 0.015 * math.pow(lb - 50, 2) / math.sqrt(20 + math.pow(lb - 50, 2));
  final sc = 1 + 0.045 * cbp, sh = 1 + 0.015 * cbp * t;
  final rt = -math.sin(_rad(2 * dth)) * rc;
  return math.sqrt(math.pow(dl / sl, 2) + math.pow(dc / sc, 2) + math.pow(dH / sh, 2) + rt * (dc / sc) * (dH / sh));
}

/// CIEDE2000 between two colours as seen with [v].
double deltaE(Color a, Color b, Vision v) => ciede2000(labOf(a, v), labOf(b, v));

double _relLum(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

/// WCAG contrast ratio between two opaque colours.
double contrastRatio(Color a, Color b) {
  final la = _relLum(a), lb = _relLum(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}
