// A QR code for a meshcore:// link, drawn with the pure-Dart `qr` package (no image, no network). Always black on white with
// a quiet zone, in dark mode too, because scanners need the contrast.
import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

class QrView extends StatelessWidget {
  /// The text the code carries (a QR code for a MeshCore contact or channel carries exactly the link).
  final String data;
  final double size;

  /// Read by screen readers instead of the (meaningless to a listener) picture.
  final String semanticLabel;

  const QrView({super.key, required this.data, this.size = 240, this.semanticLabel = 'QR code'});

  @override
  Widget build(BuildContext context) {
    final QrImage? image = _make(data);
    return Semantics(
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Container(
          key: const Key('qr-view'),
          width: size,
          height: size,
          padding: EdgeInsets.all(size * 0.06),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          child: image == null
              ? const Center(child: Icon(Icons.qr_code_2_rounded, color: Colors.black26, size: 48))
              : CustomPaint(painter: _QrPainter(image)),
        ),
      ),
    );
  }

  static QrImage? _make(String data) {
    try {
      return QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    } catch (_) {
      return null; // too long for a QR code: show the placeholder, the link text is still on screen
    }
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;
  _QrPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = Colors.black;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) {
          // overdraw a hair so neighbouring cells never leave a seam at fractional sizes
          canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell + 0.5, cell + 0.5), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => !identical(old.image, image);
}
