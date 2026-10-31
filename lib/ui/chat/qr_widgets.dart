// QR code display (package:qr, pure Dart, MIT) and the camera scanner (package:mobile_scanner, BSD-3, actively maintained,
// Apple Vision on iOS / ML Kit on Android; the camera is opened only on this screen and nothing is recorded).
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart';

import '../theme.dart';

/// Opens the scanner and returns what it read (a `meshcore://` link), or null if cancelled. Tests replace it.
typedef QrScanLauncher = Future<String?> Function(BuildContext context);

Future<String?> defaultQrScan(BuildContext context) => Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScannerScreen()));

/// A QR code for [data]: always black on white with a quiet zone, even in dark mode, because that is what scanners read.
class QrView extends StatelessWidget {
  final String data;
  final double size;
  const QrView({super.key, required this.data, this.size = 240});

  @override
  Widget build(BuildContext context) {
    QrImage? image;
    try {
      image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    } catch (_) {
      image = null;
    }
    return Semantics(
      label: 'QR code. Scan it with MeshSonar or another MeshCore app to get the same channel.',
      image: true,
      child: ExcludeSemantics(
        child: Container(
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

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});
  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;
  String? _notMeshcore;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v == null) continue;
      if (v.trim().toLowerCase().startsWith('meshcore://')) {
        _done = true;
        Navigator.of(context).pop(v.trim());
        return;
      }
      setState(() => _notMeshcore = 'That QR code is not a MeshCore code. Point the camera at a MeshCore channel or contact code.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR code')),
      body: Stack(
        children: [
          MobileScanner(
            key: const Key('qr-camera'),
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, e) {
              final denied = e.errorCode == MobileScannerErrorCode.permissionDenied;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.no_photography_outlined, size: 40),
                    const SizedBox(height: Gap.m),
                    Text(denied ? 'The camera is turned off for MeshSonar' : 'The camera could not start', style: t.textTheme.titleMedium, textAlign: TextAlign.center),
                    const SizedBox(height: Gap.s),
                    Text(
                      denied
                          ? 'Allow the camera in the Settings app, under MeshSonar, or go back and paste the channel link instead.'
                          : 'Go back and paste the channel link instead.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Gap.l),
                    FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.of(context).pop(), child: const Text('Go back')),
                  ]),
                ),
              );
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.all(Gap.l),
                child: Text(
                  _notMeshcore ?? 'Point the camera at a MeshCore QR code. The camera is only on while this screen is open.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
