// QR code display (package:qr, pure Dart, MIT). The camera scanner is lib/ui/contacts/qr_scan_screen.dart
// (package:mobile_scanner; the camera is opened only on that screen and nothing is recorded); channels and contacts share it.
import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../contacts/qr_scan_screen.dart';

/// Opens the scanner and returns what it read (a `meshcore://` link), or null if cancelled. Tests replace it.
typedef QrScanLauncher = Future<String?> Function(BuildContext context);

Future<String?> defaultQrScan(BuildContext context) => QrScanScreen.scan(context);

/// A QR code for [data]: always black on white with a quiet zone, even in dark mode, because that is what scanners read.
class QrView extends StatelessWidget {
  final String data;
  final double size;

  /// What a screen reader says instead of the picture.
  final String semanticLabel;
  const QrView({super.key, required this.data, this.size = 240, this.semanticLabel = 'QR code. Scan it with MeshSonar or another MeshCore app to get the same channel.'});

  @override
  Widget build(BuildContext context) {
    QrImage? image;
    try {
      image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    } catch (_) {
      image = null;
    }
    return Semantics(
      label: semanticLabel,
      image: true,
      child: ExcludeSemantics(
        child: Container(
          key: const Key('qr-view'),
          width: size,
          height: size,
          color: Colors.white,
          child: image == null ? const Center(child: Text('Too long for a QR code', style: TextStyle(color: Colors.black))) : CustomPaint(painter: _QrPainter(image)),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;
  _QrPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 4;
    final n = image.moduleCount;
    final cell = size.shortestSide / (n + quiet * 2);
    final paint = Paint()..color = Colors.black;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) {
          canvas.drawRect(Rect.fromLTWH((c + quiet) * cell, (r + quiet) * cell, cell + 0.4, cell + 0.4), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
