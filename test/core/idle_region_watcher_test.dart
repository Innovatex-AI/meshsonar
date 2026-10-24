import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/idle_region_watcher.dart';
import 'package:meshsonar/radio/radio_api.dart';

class _Src implements IdleLocationSource {
  bool always = false, allowed = true;
  final List<bool> subscribedBackground = [];
  StreamController<GeoFix>? ctl;
  @override
  Stream<GeoFix> fixes({required bool background}) {
    subscribedBackground.add(background);
    final c = ctl = StreamController<GeoFix>();
    return c.stream;
  }

  @override
  Future<bool> hasAlways() async => always;
  @override
  Future<bool> permitted() async => allowed;
}

GeoFix fix(int sec, {double lat = 40, double lon = -83}) => GeoFix(lat: lat, lon: lon, at: DateTime.utc(2026, 10, 24, 12).add(Duration(seconds: sec)));
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late _Src src;
  late List<GeoFix> got;
  late IdleRegionWatcher w;
  setUp(() {
    src = _Src();
    got = [];
    w = IdleRegionWatcher(source: src, onFix: got.add);
  });

  test('does nothing until started; start opens one foreground stream; stop closes it', () async {
    expect(w.listening, isFalse);
    await w.start();
    expect(w.listening, isTrue);
    expect(src.subscribedBackground, [false]);
    await w.start();
    expect(src.subscribedBackground.length, 1, reason: 'no duplicate subscription');
    await w.stop();
    expect(w.listening, isFalse);
  });

  test('fixes reach the app, thinned to one per minGap', () async {
    await w.start();
    src.ctl!.add(fix(0));
    src.ctl!.add(fix(5));
    src.ctl!.add(fix(19));
    src.ctl!.add(fix(21));
    await pump();
    expect(got.map((f) => f.at.second), [0, 21]);
  });

  test('no stream during a drive; it comes back after', () async {
    await w.start();
    await w.setDriving(true);
    expect(w.listening, isFalse);
    await w.setDriving(false);
    expect(w.listening, isTrue);
    expect(src.subscribedBackground.length, 2);
  });

  test('backgrounded without Always: paused; resumes in the foreground', () async {
    await w.start();
    await w.setForeground(false);
    expect(w.listening, isFalse);
    await w.setForeground(true);
    expect(w.listening, isTrue);
  });

  test('backgrounded with Always: keeps running, and a stream opened in the background asks for background updates', () async {
    src.always = true;
    await w.start();
    expect(src.subscribedBackground, [true]);
    await w.setForeground(false);
    expect(w.listening, isTrue);
    await w.stop();
    await w.setForeground(false);
    await w.start();
    expect(w.listening, isTrue);
    expect(src.subscribedBackground.last, isTrue);
  });

  test('no location permission: never subscribes (it never prompts)', () async {
    src.allowed = false;
    await w.start();
    expect(w.listening, isFalse);
  });

  test('the last known fix is persisted and read back', () async {
    final dir = Directory.systemTemp.createTempSync('lk');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = LastKnownStore(File('${dir.path}/last.json'));
    expect(await store.load(), isNull);
    final w2 = IdleRegionWatcher(source: src, onFix: got.add, store: store);
    await w2.start();
    src.ctl!.add(fix(0, lat: 39.96, lon: -82.99));
    GeoFix? back;
    for (var i = 0; i < 40 && back == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      back = await store.load();
    }
    expect(back!.lat, 39.96);
    expect(back.lon, -82.99);
    expect(back.at, fix(0).at);
    File('${dir.path}/last.json').writeAsStringSync('garbage');
    expect(await store.load(), isNull);
  });
}
