// The mini drive bar hosted the way the real shell hosts it on an iPhone (HomeShell, status-bar and home-indicator
// insets, the tab bar under it): Stop is whole and at least 12 pt from the screen edge at 320, 375, 402 and 430 pt, at
// 1.0x and 1.3x text; line 2 never repeats line 1; and with the phone's own font (SF, when this Mac has it) line 2 is
// not ellipsised at 375 pt. The older width tests only checked "no overflow error", and a Row with an Expanded never
// throws one: nothing measured where Stop ended.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';

import 'fakes.dart';

/// An iPhone in portrait: 62 pt status bar, 34 pt home indicator.
void iphone(WidgetTester tester, {required double w, double h = 874, double scale = 1.0}) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<Harness> startDriving(WidgetTester tester) async {
  final h = Harness()..approveKey();
  await h.pumpApp(tester);
  await h.state.connectSimulator();
  await tester.pumpAndSettle();
  while (find.byType(BottomSheet).evaluate().isNotEmpty || find.byKey(const Key('app-sheet')).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
  }
  await h.state.startDrive();
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

Future<void> finish(WidgetTester tester, Harness h) async {
  await h.state.stopDrive();
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

const _stop = Key('mini-bar-stop');
const _hero = Key('mini-bar-hero');
const _next = Key('mini-bar-next');

void main() {
  for (final scale in [1.0, 1.3]) {
    for (final width in [320.0, 375.0, 402.0, 430.0]) {
      testWidgets('in the shell at ${width.toInt()} pt, ${scale}x text: Stop is whole, 12 pt from the edge, 44 pt', (tester) async {
        iphone(tester, w: width, scale: scale);
        final h = await startDriving(tester);
        h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]));
        await tester.pump(const Duration(milliseconds: 100));
        for (final tab in ['Chat', 'Network', 'Plan', 'More']) {
          await tapShellTab(tester, tab);
          expect(tester.takeException(), isNull, reason: tab);
          final bar = tester.getRect(find.byKey(const Key('mini-drive-bar')));
          expect(bar.left, 0, reason: tab);
          expect(bar.right, width, reason: '$tab: the bar is exactly as wide as the screen');
          final stop = tester.getRect(find.byKey(_stop));
          expect(stop.right, lessThanOrEqualTo(width - 12), reason: '$tab: Stop ends at least 12 pt before the edge');
          expect(stop.left, greaterThan(width / 2), reason: tab);
          expect(stop.width, greaterThanOrEqualTo(44), reason: tab);
          expect(stop.height, greaterThanOrEqualTo(44), reason: tab);
          expect(find.byKey(_stop).hitTestable(), findsOneWidget, reason: tab);
          // The time and the text keep their places left of Stop.
          final time = tester.getRect(find.byKey(const Key('mini-bar-elapsed')));
          expect(time.right, lessThanOrEqualTo(stop.left), reason: tab);
          expect(tester.getRect(find.byKey(_hero)).right, lessThanOrEqualTo(time.left), reason: tab);
          expect(tester.getRect(find.byKey(_hero)).width, greaterThan(40), reason: '$tab: the headline keeps room');
          // Line 2 runs under the headline and the time, so it has the room of both.
          expect(tester.getRect(find.byKey(_next)).top, greaterThanOrEqualTo(time.bottom - 2), reason: tab);
          expect(bar.height, scale == 1.0 ? miniDriveBarHeight : lessThanOrEqualTo(72), reason: tab);
          // 320 pt at 1.3x is the one size where Stop is the icon alone and the chevron goes.
          final tight = width < 360 && scale >= 1.25;
          expect(find.descendant(of: find.byKey(_stop), matching: find.text('Stop')), tight ? findsNothing : findsOneWidget, reason: tab);
          expect(find.descendant(of: find.byKey(const Key('mini-bar-open')), matching: find.byIcon(Icons.chevron_right)),
              tight ? findsNothing : findsOneWidget, reason: tab);
        }
        await finish(tester, h);
      });
    }
  }

  testWidgets('landscape insets: Stop stays clear of the right inset', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(667 * 3, 375 * 3);
    tester.view.padding = const FakeViewPadding(left: 44 * 3, right: 44 * 3, bottom: 21 * 3);
    tester.view.viewPadding = const FakeViewPadding(left: 44 * 3, right: 44 * 3, bottom: 21 * 3);
    addTearDown(tester.view.reset);
    final h = await startDriving(tester);
    await tapShellTab(tester, 'More');
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(_stop)).right, lessThanOrEqualTo(667 - 44 - 12));
    expect(tester.getRect(find.byKey(const Key('mini-bar-open'))).left, 0, reason: 'the whole strip left of Stop still opens Drive');
    await finish(tester, h);
  });

  testWidgets('line 2 says only what line 1 does not: ping count and the next step, in few words', (tester) async {
    iphone(tester, w: 375);
    final h = await startDriving(tester);
    final e = h.engines.single;
    e.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]));
    await tester.pump(const Duration(milliseconds: 100));
    await tapShellTab(tester, 'Chat');
    String hero() => tester.widget<Text>(find.byKey(_hero)).data!;
    String next() => tester.widget<Text>(find.byKey(_next)).data!;
    Future<void> status(EngineStatus st) async {
      e.setStatus(st);
      await tester.pump(const Duration(milliseconds: 50));
    }

    final now = h.state.services.clock();
    await status(EngineStatus(EngineState.driving, nextPingAt: now.add(const Duration(seconds: 14)), waitingFor: PingWait.time));
    expect(hero(), '1 heard');
    expect(next(), '1 ping · Next ping 14 s');
    await status(const EngineStatus(EngineState.pinging));
    expect(next(), '1 ping · Listening');
    await status(const EngineStatus(EngineState.driving, waitingFor: PingWait.gps));
    expect(next(), '1 ping · No GPS fix');
    await status(const EngineStatus(EngineState.driving, waitingFor: PingWait.distance, metresToGo: 40));
    expect(next(), startsWith('1 ping · Move '));
    h.state.setPingsPaused(true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(next(), '1 ping · Paused');
    h.state.setPingsPaused(false);
    await status(const EngineStatus(EngineState.driving));
    for (final t in [hero(), next()]) {
      expect(RegExp('heard').allMatches('${hero()} ${next()}').length, 1, reason: '"heard" is said once: $t');
    }
    // The spoken sentence and the long words are unchanged.
    await status(const EngineStatus(EngineState.pinging));
    expect(miniBarSummary(h.state).waiting, 'Listening for echoes');
    expect(miniBarSummary(h.state).counts, '1 ping · 1 heard');
    await status(const EngineStatus(EngineState.driving));
    await finish(tester, h);
  });

  // The test font (every glyph a 1 em square) is about twice as wide as the phone's, so "fits" is measured with the
  // real system font. Skipped on a machine without it.
  final sf = File('/System/Library/Fonts/SFNS.ttf');
  for (final width in [375.0, 402.0]) {
    testWidgets('with the iPhone font at ${width.toInt()} pt, normal text: neither line is ellipsised, even at 120 pings', skip: !sf.existsSync(),
        (tester) async {
      iphone(tester, w: width);
      final h = await startDriving(tester);
      final e = h.engines.single;
      for (var i = 0; i < 120; i++) {
        e.emit(heardPing('p$i', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1), Echo(repeater: 'c3d4', snrDb: 2, hops: 1)]));
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tapShellTab(tester, 'Chat');
      final family = Theme.of(tester.element(find.byKey(_next))).textTheme.bodySmall!.fontFamily!;
      final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(sf.readAsBytesSync())));
      await tester.runAsync(loader.load);
      await tester.pump(const Duration(milliseconds: 100));
      final now = h.state.services.clock();
      for (final st in [
        EngineStatus(EngineState.driving, nextPingAt: now.add(const Duration(seconds: 114)), waitingFor: PingWait.time),
        const EngineStatus(EngineState.pinging),
        const EngineStatus(EngineState.driving, waitingFor: PingWait.gps),
        const EngineStatus(EngineState.driving, waitingFor: PingWait.distance, metresToGo: 140),
        const EngineStatus(EngineState.driving, waitingFor: PingWait.distance),
      ]) {
        e.setStatus(st);
        await tester.pump(const Duration(milliseconds: 50));
        final text = tester.widget<Text>(find.byKey(_next)).data!;
        expect(text, startsWith('120 pings · '));
        for (final k in [_hero, _next]) {
          final para = tester.renderObject<RenderParagraph>(find.descendant(of: find.byKey(k), matching: find.byType(RichText)));
          expect(para.didExceedMaxLines, isFalse, reason: '"$text" (${para.size.width.toStringAsFixed(0)} pt wide) is cut');
        }
      }
      expect(tester.getRect(find.byKey(_stop)).right, lessThanOrEqualTo(width - 12));
      e.setStatus(const EngineStatus(EngineState.driving));
      await finish(tester, h);
    });
  }
}
