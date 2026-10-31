// Full-screen QR scanner for MeshCore contact codes. The camera widget is injectable so tests (and desktops without a
// camera) never touch the plugin.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

typedef ScannerBuilder = Widget Function(BuildContext context, void Function(String code) onCode);

class QrScanScreen extends StatefulWidget {
  /// Called once with the first MeshCore code seen. The screen pops itself first, and also returns the code from the route.
  final void Function(String code)? onCode;
  final ScannerBuilder? scannerBuilder;

  /// "Paste instead": the screen pops and the caller shows its paste field.
  final VoidCallback? onPaste;
  const QrScanScreen({super.key, this.onCode, this.scannerBuilder, this.onPaste});

  /// Opens the scanner and returns the `meshcore://` text it read, or null when the person cancelled.
  static Future<String?> scan(BuildContext context, {ScannerBuilder? scannerBuilder, VoidCallback? onPaste}) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => QrScanScreen(scannerBuilder: scannerBuilder, onPaste: onPaste)));

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;
  String? _notice;
  Timer? _noticeTimer;
  String? _last;

  void _code(String raw) {
    if (_done) return;
    final c = raw.trim();
    if (c == _last) return; // the camera reports the same code many times a second
    _last = c;
    if (!c.toLowerCase().startsWith('meshcore://')) {
      setState(() => _notice = 'That is not a MeshCore code');
      _noticeTimer?.cancel();
      _noticeTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _notice = null;
            _last = null;
          });
        }
      });
      return;
    }
    _done = true;
    Navigator.of(context).pop(c);
    widget.onCode?.call(c);
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan a QR code'),
        leading: IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          (widget.scannerBuilder ?? _realScanner)(context, _code),
          IgnorePointer(
            child: Center(
              child: Container(
                key: const Key('scan-frame'),
                width: 240,
                height: 240,
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
              ),
            ),
          ),
          Positioned(
            left: Gap.l,
            right: Gap.l,
            bottom: Gap.xl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_notice != null)
                  Container(
                    key: const Key('scan-notice'),
                    padding: const EdgeInsets.all(Gap.m),
                    decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)),
                    child: Text(_notice!, style: TextStyle(color: t.colorScheme.onErrorContainer)),
                  )
                else
                  const Text('Point the camera at a MeshCore contact code.', style: TextStyle(color: Colors.white), textAlign: TextAlign.center),
                const SizedBox(height: Gap.m),
                OutlinedButton(
                  key: const Key('scan-paste'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(48, 48), side: const BorderSide(color: Colors.white70)),
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onPaste?.call();
                  },
                  child: const Text('Paste instead'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _realScanner(BuildContext context, void Function(String) onCode) => _RealScanner(onCode: onCode);
}

class _RealScanner extends StatefulWidget {
  final void Function(String) onCode;
  const _RealScanner({required this.onCode});
  @override
  State<_RealScanner> createState() => _RealScannerState();
}

class _RealScannerState extends State<_RealScanner> {
  final MobileScannerController _c = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _torch = false;

  @override
  void dispose() {
    unawaited(_c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _c,
          onDetect: (cap) {
            for (final b in cap.barcodes) {
              final v = b.rawValue;
              if (v != null) widget.onCode(v);
            }
          },
          errorBuilder: (context, error) => _problem(context, error),
        ),
        Positioned(
          right: Gap.l,
          top: Gap.m,
          child: IconButton.filledTonal(
            key: const Key('scan-torch'),
            tooltip: _torch ? 'Torch off' : 'Torch on',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: Icon(_torch ? Icons.flash_on_rounded : Icons.flash_off_rounded),
            onPressed: () async {
              await _c.toggleTorch();
              if (mounted) setState(() => _torch = !_torch);
            },
          ),
        ),
      ],
    );
  }

  Widget _problem(BuildContext context, MobileScannerException e) {
    final denied = e.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(
          denied
              ? 'Camera access is off. Turn it on in Settings, or paste a link instead.'
              : 'No camera is available here. Paste a link or key instead.',
          key: const Key('scan-problem'),
          style: const TextStyle(color: Colors.white, fontSize: 16),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
