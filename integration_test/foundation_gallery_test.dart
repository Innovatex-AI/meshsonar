// DR0 screenshot sheet and spikes S1 / S4 for the shared foundation (WP0). Pumps the helper gallery on a simulator in
// light, dark and AX3, opens each helper, and prints `SCREEN <name>` lines for a script to screenshot, plus the spike
// measurements as `SPIKE_...` lines.
//
//   flutter test integration_test/foundation_gallery_test.dart -d <simulator udid>
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/core/offline_style.dart' show appLabelFont;
import 'package:meshsonar/ui/design/app_type.dart';
import 'package:meshsonar/ui/design/helper_gallery.dart';
import 'package:meshsonar/ui/theme.dart';

double _w(String text, TextStyle style) {
  final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling)..layout();
  return p.width;
}

Future<void> _settle(WidgetTester t, [int ms = 1600]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(Brightness b, double scale) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: meshSonarTheme(Brightness.light),
  darkTheme: meshSonarTheme(Brightness.dark),
  themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
  home: const HelperGallery(),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('spikes S1 and S4 on the system font', (t) async {
    await t.pumpWidget(_app(Brightness.light, 1));
    // S4: tabular numerals. With tnum, "1111111111" and "0000000000" are the same width; without, they differ.
    for (final size in [34.0, 13.0]) {
      final plain = TextStyle(fontSize: size);
      final tab = TextStyle(fontSize: size, fontFeatures: AppType.tabular);
      final w1p = _w('1111111111', plain), w0p = _w('0000000000', plain);
      final w1t = _w('1111111111', tab), w0t = _w('0000000000', tab);
      // ignore: avoid_print
      print('SPIKE_S4 size=$size plain1=$w1p plain0=$w0p tnum1=$w1t tnum0=$w0t tnumEqual=${(w1t - w0t).abs() < 0.01} proportionalDiffers=${(w1p - w0p).abs() > 0.01}');
    }
    // Weight 600 resolves to a distinct face.
    final reg = _w('Weights resolve', const TextStyle(fontSize: 17)), semi = _w('Weights resolve', const TextStyle(fontSize: 17, fontWeight: FontWeight.w600));
    // ignore: avoid_print
    print('SPIKE_S4 weight w400=$reg w600=$semi distinct=${(reg - semi).abs() > 0.01}');
    // Optical size: advance per point just below and above 20 pt (Text -> Display switch).
    final below = _w('Hamburgefonstiv', const TextStyle(fontSize: 19.5)) / 19.5, above = _w('Hamburgefonstiv', const TextStyle(fontSize: 20.5)) / 20.5;
    // ignore: avoid_print
    print('SPIKE_S4 opticalSwitch perPt19.5=$below perPt20.5=$above ratio=${above / below}');
    // S1: the family the offline style asks for resolves to the system font.
    const sample = 'Westerville Rd Cleveland Ave';
    final sys = _w(sample, const TextStyle(fontSize: 17));
    final cup = _w(sample, TextStyle(fontSize: 17, fontFamily: appLabelFont));
    final cupDisplay = _w(sample, const TextStyle(fontSize: 17, fontFamily: 'CupertinoSystemDisplay'));
    final menlo = _w(sample, const TextStyle(fontSize: 17, fontFamily: 'Menlo'));
    // ignore: avoid_print
    print('SPIKE_S1 system=$sys appLabelFont($appLabelFont)=$cup display=$cupDisplay menlo=$menlo resolvesToSystem=${(sys - cup).abs() < 0.5 && (sys - menlo).abs() > 1}');
    expect(ui.PlatformDispatcher.instance.views, isNotEmpty);
  });

  testWidgets('foundation gallery screenshot sheet', (t) async {
    Future<void> scene(String name, Brightness b, double scale) async {
      await t.pumpWidget(_app(b, scale));
      await _settle(t, 600);
      // ignore: avoid_print
      print('SCREEN gallery-$name-top');
      await _settle(t);
      final list = find.byType(ListView).first;
      for (var i = 1; i <= 3; i++) {
        await t.drag(list, const Offset(0, -500));
        await _settle(t, 500);
        // ignore: avoid_print
        print('SCREEN gallery-$name-scroll$i');
        await _settle(t);
      }
    }

    await scene('light', Brightness.light, 1);
    await scene('dark', Brightness.dark, 1);
    await scene('ax3', Brightness.light, 2.35);

    for (final b in Brightness.values) {
      await t.pumpWidget(_app(b, 1));
      await _settle(t, 500);
      final list = find.byType(ListView).first;
      await t.drag(list, const Offset(0, -2200));
      await _settle(t, 500);
      for (final k in ['g-sheet', 'g-action', 'g-alert', 'g-toast']) {
        await t.ensureVisible(find.byKey(Key(k)));
        await _settle(t, 300);
        await t.tap(find.byKey(Key(k)));
        await _settle(t, 900);
        // ignore: avoid_print
        print('SCREEN helper-$k-${b.name}');
        await _settle(t, 1500);
        if (k != 'g-toast') {
          final cancel = find.text('Cancel');
          final keep = find.text('Keep driving');
          final done = find.text('Done');
          if (done.evaluate().isNotEmpty) {
            await t.tap(done.last);
          } else if (keep.evaluate().isNotEmpty) {
            await t.tap(keep.last);
          } else if (cancel.evaluate().isNotEmpty) {
            await t.tap(cancel.last);
          }
          await _settle(t, 700);
        }
      }
    }
    // AX3 sheet.
    await t.pumpWidget(_app(Brightness.light, 2.35));
    await _settle(t, 500);
    await t.drag(find.byType(ListView).first, const Offset(0, -6000));
    await _settle(t, 500);
    await t.tap(find.byKey(const Key('g-sheet')), warnIfMissed: false);
    await _settle(t, 900);
    // ignore: avoid_print
    print('SCREEN helper-g-sheet-ax3');
    await _settle(t, 1500);
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
