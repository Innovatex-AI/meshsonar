// Screenshot flow for photo messages on the real app (simulator, debug), with no photo server yet: a stand-in photo
// controller (photo-config "enabled", an approved key, pictures drawn on the phone) replaces the live one. Also runs the
// REAL compressor (flutter_image_compress on iOS) over a JPEG carrying EXIF + XMP GPS and prints what is left
// ("STRIPCHECK ..."): the on-device proof that location never leaves the phone.
//
//   FLOW_TEST=integration_test/photo_visual_test.dart scripts/verify_sim.sh <checkout>
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/core/jpeg_meta.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/platform/photo_picker.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import 'gps_fixture_bytes.dart';
import 'screens.dart';

const _a = 'https://meshsonar.com/p/k3Xq9TzA';
const _b = 'https://meshsonar.com/p/Rm0ved99';

/// A landscape drawn on the phone: sky, sun, two ridges, a tower. Stands in for a real photo.
Future<Uint8List> _scene(int w, int h, {Color sky = const Color(0xFF6FA8DC)}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final r = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  c.drawRect(r, Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, h.toDouble()), [sky, const Color(0xFFF6D7A7)]));
  c.drawCircle(Offset(w * 0.78, h * 0.25), h * 0.09, Paint()..color = const Color(0xFFFFF1C1));
  Path ridge(double base, double amp, double phase) {
    final p = Path()..moveTo(0, h.toDouble());
    for (var x = 0; x <= w; x += 8) {
      p.lineTo(x.toDouble(), h * base - amp * h * (0.5 + 0.5 * ((x / w * 6 + phase) % 2 - 1).abs()));
    }
    return p
      ..lineTo(w.toDouble(), h.toDouble())
      ..close();
  }

  c.drawPath(ridge(0.75, 0.18, 0.3), Paint()..color = const Color(0xFF4F6D7A));
  c.drawPath(ridge(0.92, 0.14, 1.1), Paint()..color = const Color(0xFF2E4A3F));
  final tower = Paint()
    ..color = const Color(0xFF222222)
    ..strokeWidth = w / 160;
  c.drawLine(Offset(w * 0.3, h * 0.62), Offset(w * 0.3, h * 0.28), tower);
  c.drawLine(Offset(w * 0.27, h * 0.62), Offset(w * 0.3, h * 0.28), tower);
  c.drawLine(Offset(w * 0.33, h * 0.62), Offset(w * 0.3, h * 0.28), tower);
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

class _DemoTransport implements PhotoTransport {
  @override
  Future<PhotoConfig> photoConfig() async => const PhotoConfig(enabled: true);
  @override
  Future<PhotoUploadResult> uploadPhoto(String driverKey, List<int> bytes,
      {String contentType = 'image/jpeg', void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) async {
    // Bytes out in steps, then the body is out and the answer takes a moment ("Processing…").
    for (var i = 1; i <= 5; i++) {
      onProgress?.call(bytes.length * i ~/ 5, bytes.length);
      await Future<void>.delayed(Duration(milliseconds: i < 5 ? 400 : 2500));
    }
    return const PhotoUploadResult(id: 'Up10aded', url: 'https://meshsonar.com/p/Up10aded', thumbUrl: '', fullUrl: '');
  }

  @override
  Future<void> deletePhoto(String driverKey, String id) async {}
  @override
  Future<void> reportPhoto(String id, PhotoReportReason reason, {String? driverKey}) async {}
}

class _DemoSource implements PhotoSource {
  final Map<String, Uint8List> pics;
  _DemoSource(this.pics);
  @override
  Future<List<int>?> cached(String url, PhotoVariant v) async => pics[url];
  @override
  Future<bool> knownRemoved(String url) async => url == _b;
  @override
  Future<PhotoFetch> fetch(String url, PhotoVariant v) async {
    if (url == _b) return const PhotoFetch.removed();
    final p = pics[url];
    return p == null ? const PhotoFetch.failed() : PhotoFetch.ok(p);
  }

  @override
  Future<void> forget(String url) async {}
}

class _DemoPicker implements PhotoPicker {
  final Uint8List bytes;
  _DemoPicker(this.bytes);
  @override
  Future<PreparedPhoto?> pick(PhotoPickSource source, {int maxEdgePx = 2048}) async => PreparedPhoto(bytes, 960, 720);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('photo messages', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue);
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }

    // 1. The real compressor on this device, over a JPEG with GPS.
    final src = base64Decode(gpsFixtureJpegBase64);
    try {
      final p = await t.runAsync(() => preparePhotoBytes(src, maxEdgePx: 320));
      // ignore: avoid_print
      print('STRIPCHECK in gps=${jpegHasGps(src)} exif=${jpegHasExif(src)} | out ${p!.width}x${p.height} '
          'gps=${jpegHasGps(p.bytes)} exif=${jpegHasExif(p.bytes)} bytes=${p.bytes.length} '
          'model=${String.fromCharCodes(p.bytes).contains('iPhone 17 Pro')} street=${String.fromCharCodes(p.bytes).contains('Example St')}');
      final big = await t.runAsync(() async => preparePhotoBytes(await _scene(4032, 3024), maxEdgePx: 2048));
      // ignore: avoid_print
      print('STRIPCHECK resize 4032x3024 -> ${big!.width}x${big.height} bytes=${big.bytes.length}');
    } catch (e) {
      // ignore: avoid_print
      print('STEPFAIL stripcheck $e');
    }

    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    final scanner = state.services.simulatorScanner as SimulatedRadioScanner;
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    // First connect of a radio asks for its antenna: pick one and save (as dm_delivery_visual_test does).
    if (await waitFor(t, find.byKey(const Key('antenna-sheet')), timeout: const Duration(seconds: 6))) {
      final mount = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('mount-')).first;
      await t.tap(mount);
      await pumpFor(t, const Duration(milliseconds: 500));
      final height = find.byKey(const Key('antenna-height-field'));
      if (height.evaluate().isNotEmpty) {
        await t.ensureVisible(height);
        await t.enterText(height, '3');
      }
      final unknown = find.byKey(const Key('antenna-gain-unknown'));
      if (unknown.evaluate().isNotEmpty) {
        await t.ensureVisible(unknown);
        await t.tap(unknown);
        await pumpFor(t, const Duration(milliseconds: 500));
      }
      final save = find.byKey(const Key('antenna-save'));
      if (save.evaluate().isNotEmpty) {
        await t.ensureVisible(save);
        await t.tap(save);
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }

    // 2. The stand-in photo controller (no server yet).
    final chat = ChatWiring.controller.value!;
    final scene = (await t.runAsync(() => _scene(960, 720)))!;
    final scene2 = (await t.runAsync(() => _scene(720, 960, sky: const Color(0xFF8E7CC3))))!;
    PhotoWiring.controller.value = PhotoController(
      store: chat.store,
      transport: () => _DemoTransport(),
      driverKey: () => 'demo-key',
      keyApproved: () => true,
      source: _DemoSource({_a: scene, 'https://meshsonar.com/p/Up10aded': scene2}),
      picker: _DemoPicker(scene2),
    );

    await openShellTab(t, 'Chat');
    await pumpFor(t, const Duration(seconds: 2));
    final radio = scanner.lastTransport!;
    radio.injectChannelMessage(0, 'Maya', 'Sunrise from the tower $_a');
    await pumpFor(t, const Duration(seconds: 2));
    radio.injectChannelMessage(0, 'Dave', 'https://meshsonar.com/p/Zz00Aa11');
    await pumpFor(t, const Duration(seconds: 2));
    radio.injectChannelMessage(0, 'Ann', 'old one $_b');
    await pumpFor(t, const Duration(seconds: 5));
    await shot(t, 'photo-chats-list');

    // Open the channel the photos arrived on.
    final row = chat.conversationRows().firstWhere((r) => r.preview.contains('meshsonar.com/p/'), orElse: () => chat.conversationRows().first);
    ChatTabHost.openConversation!(t.element(find.byType(Scaffold).first), row.key);
    await pumpFor(t, const Duration(seconds: 3));
    final tip = find.byKey(const Key('tip-dismiss'));
    if (tip.evaluate().isNotEmpty) {
      await t.tap(tip.first);
      await pumpFor(t, const Duration(seconds: 1));
    }
    await shot(t, 'photo-conversation');

    // The composer's photo button and its sheet.
    if (await waitFor(t, find.byKey(const Key('composer-photo')), timeout: const Duration(seconds: 5))) {
      await t.tap(find.byKey(const Key('composer-photo')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'photo-source-sheet');
      await t.tap(find.byKey(const Key('photo-library')));
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot(t, 'photo-uploading');
      await pumpFor(t, const Duration(milliseconds: 1200));
      await shot(t, 'photo-processing');
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'photo-link-inserted');
      // Send it: the own bubble shows the photo.
      await t.enterText(find.byKey(const Key('composer-field')), 'From the trailhead https://meshsonar.com/p/Up10aded');
      await pumpFor(t, const Duration(milliseconds: 500));
      await t.tap(find.byKey(const Key('composer-send')));
      await pumpFor(t, const Duration(seconds: 3));
      // The first send offers alerts once: not now.
      if (await waitFor(t, find.text('Not now'), timeout: const Duration(seconds: 3))) {
        await t.tap(find.text('Not now').first);
        await pumpFor(t, const Duration(seconds: 1));
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'photo-sent');
    } else {
      // ignore: avoid_print
      print('STEPFAIL composer-photo button missing');
    }

    // The viewer.
    final thumb = find.byKey(const Key('photo-thumb-k3Xq9TzA'));
    // Older messages are above (the list is reversed): scroll back to Maya's photo.
    try {
      await t.scrollUntilVisible(thumb, 300,
          scrollable: find.descendant(of: find.byKey(const Key('conv-list')), matching: find.byType(Scrollable)).first, maxScrolls: 20);
    } catch (_) {}
    await pumpFor(t, const Duration(seconds: 1));
    if (await waitFor(t, thumb, timeout: const Duration(seconds: 5))) {
      await t.ensureVisible(thumb.first);
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'photo-received-thumbnail');
      await t.tap(thumb.first);
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'photo-viewer');
      final close = find.byKey(const Key('viewer-close'));
      if (close.evaluate().isEmpty) {
        // ignore: avoid_print
        print('STEPFAIL viewer did not open');
      } else {
        await t.tap(close);
        await pumpFor(t, const Duration(seconds: 1));
      }
    } else {
      // ignore: avoid_print
      print('STEPFAIL photo thumb missing');
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
