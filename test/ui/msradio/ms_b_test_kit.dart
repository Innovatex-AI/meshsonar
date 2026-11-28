// Shared rig for builder B's MeshSonar radio screen tests: a paired FakeMsRadio behind a recording client (every request
// body kept, per-route overrides for error and edge-case replies), a fake file picker, and pumping in light / dark, phone
// size and large text.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/msradio/msradio.dart';
import 'package:meshsonar/platform/file_pick.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/ui/theme.dart';

RadioCaps msBCaps() =>
    RadioCaps.fromDeviceInfo(DeviceInfoFrame(firmwareVerCode: 10, firmwareVersion: 'v1.18.0-ms0.1.0', manufacturer: 'Heltec V4 TFT'));

class MsBRig {
  final FakeMsRadio r;
  late final MsRadioController c;

  /// Every request body as text (form fields, multipart), in order.
  final List<String> bodies = [];

  /// `METHOD /path` -> (status, JSON text): answered instead of the fake radio.
  final Map<String, (int, String)> overrides = {};

  MsBRig._(this.r);

  static Future<MsBRig> paired(WidgetTester t) async {
    final rig = MsBRig._(FakeMsRadio());
    final client = MockClient((req) async {
      rig.bodies.add(utf8.decode(req.bodyBytes, allowMalformed: true));
      final o = rig.overrides['${req.method} ${req.url.path}'];
      if (o != null) {
        rig.r.requests.add('${req.method} ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''}');
        return http.Response(o.$2, o.$1, headers: {'content-type': 'application/json'});
      }
      return rig.r.handle(req);
    });
    final kv = InMemoryMsSecretKv();
    // in the test's fake zone (not runAsync): the controller's request queue must belong to the zone the screens run in
    await MsTokenStore(kv).save(rig.r.keyHex, rig.r.issueToken());
    rig.c = MsRadioController.forCaps(msBCaps(), radioKey: rig.r.keyHex, secrets: kv, client: client, browser: rig.r.browser, sign: rig.r.sign)!;
    final s = await rig.c.connect();
    expect(s.step, MsLinkStep.paired);
    rig.r.requests.clear();
    rig.bodies.clear();
    return rig;
  }

  /// Requests to the app API, without the prefix (`POST /ota/check`).
  List<String> get api => [for (final q in r.requests) q.replaceFirst('/api/app/v1', '')];

  void dispose() => c.dispose();
}

/// A picker that hands out one prepared file (or throws [refuse]).
class FakeFilePick implements FilePick {
  PickedFile? file;
  Object? refuse;
  List<String>? lastExtensions;
  FakeFilePick({this.file, this.refuse});

  static PickedFile bytes(String name, List<int> b) => PickedFile(name: name, size: b.length, openRead: () => Stream<List<int>>.value(b));

  @override
  Future<PickedFile?> pickFile({List<String> extensions = const []}) async {
    lastExtensions = extensions;
    if (refuse != null) throw refuse!;
    return file;
  }
}

/// Phone width (390 points), tall by default so every row of the list is built (an overflow anywhere fails the test, and
/// a row scrolled out of the cache is not missed).
void msBPhone(WidgetTester t, {double height = 2400, double width = 390}) {
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = Size(width * 3, height * 3);
  addTearDown(t.view.reset);
}

Future<void> msBPump(WidgetTester t, Widget screen, {Brightness b = Brightness.light, double textScale = 1}) async {
  await t.pumpWidget(MaterialApp(
    theme: meshSonarTheme(b),
    builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: screen,
  ));
  await msBSettle(t);
}

/// Lets the fake radio answer (no pumpAndSettle: progress bars animate forever).
Future<void> msBSettle(WidgetTester t, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> msBTap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await msBSettle(t);
}

/// Unmounts the screen (stops its timers) and closes the controller.
Future<void> msBEnd(WidgetTester t, MsBRig rig) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
  rig.dispose();
}

/// Captures debugPrint while [body] runs.
Future<List<String>> msBCapturePrints(Future<void> Function() body) async {
  final out = <String>[];
  final old = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) => out.add(m ?? '');
  try {
    await body();
  } finally {
    debugPrint = old;
  }
  return out;
}

/// Runs [body] for light and dark.
void forBothThemes(void Function(Brightness b) body) {
  for (final b in Brightness.values) {
    body(b);
  }
}
