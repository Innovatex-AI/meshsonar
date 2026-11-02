import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/app_type.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  test('Apple tracking table is applied exactly at the table sizes', () {
    expect(AppType.tracking(34), closeTo(0.37, 1e-9));
    expect(AppType.tracking(22), closeTo(0.35, 1e-9));
    expect(AppType.tracking(17), -0.41);
    expect(AppType.tracking(16), -0.32);
    expect(AppType.tracking(15), -0.24);
    expect(AppType.tracking(13), -0.08);
    expect(AppType.tracking(12), 0);
    expect(AppType.largeTitle.letterSpacing, closeTo(0.37, 1e-9));
    expect(AppType.body.letterSpacing, -0.41);
    expect(AppType.footnote.letterSpacing, -0.08);
  });

  test('tracking interpolates between table sizes and clamps outside', () {
    final t = AppType.tracking(19.5);
    expect(t, lessThan(0.35));
    expect(t, greaterThan(-0.41));
    expect(AppType.tracking(60), AppType.tracking(34));
    expect(AppType.tracking(9), AppType.tracking(11));
  });

  test('numeric styles carry tabular figures; plain styles do not', () {
    expect(AppType.hero.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(AppType.num(15).fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(AppType.body.fontFeatures, isNull);
  });

  test('the theme sets no font family (system font), and tracking reaches the text theme', () {
    for (final b in Brightness.values) {
      final tt = meshSonarTheme(b).textTheme;
      final base = ThemeData(brightness: b).textTheme; // the platform default family (SF on iOS, Roboto in tests)
      expect(tt.bodyLarge!.fontFamily, base.bodyLarge!.fontFamily);
      expect(tt.titleMedium!.fontFamily, base.titleMedium!.fontFamily);
      expect(tt.labelLarge!.fontFamily, base.labelLarge!.fontFamily);
      expect(tt.displayLarge!.fontFamily, base.displayLarge!.fontFamily);
      for (final s in [tt.bodyLarge, tt.titleMedium, tt.labelLarge, tt.displayLarge]) {
        expect(s!.fontFamily ?? '', isNot(contains('Barlow')));
      }
      expect(tt.bodyLarge!.letterSpacing, AppType.tracking(17));
      expect(tt.bodySmall!.letterSpacing, AppType.tracking(13));
      expect(tt.displayLarge!.fontFeatures, contains(const FontFeature.tabularFigures()));
    }
  });

  test('pubspec declares no font families and keeps the two OFL Barlow TTFs as plain assets (D46)', () {
    final y = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^\s{2}fonts:', multiLine: true).hasMatch(y), isFalse, reason: 'no fonts: families');
    expect(RegExp(r'^\s*-?\s*family:', multiLine: true).hasMatch(y), isFalse);
    expect(y, contains('- assets/fonts/Barlow-Regular.ttf'));
    expect(y, contains('- assets/fonts/Barlow-SemiBold.ttf'));
    // No San Francisco font file anywhere in the repo's assets.
    final names = Directory('assets').listSync(recursive: true).map((e) => e.path.toLowerCase());
    expect(names.where((n) => n.contains('sf-pro') || n.contains('sfpro') || n.contains('sf_pro') || n.contains('sf-ui')), isEmpty);
  });

  testWidgets('numberStyle uses tabular figures and no fixed family', (tester) async {
    late TextStyle s;
    await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: Builder(builder: (c) {
      s = numberStyle(c);
      return const SizedBox();
    })));
    expect(s.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(s.fontFamily ?? '', isNot(contains('Barlow')));
  });

  testWidgets('PDF export still finds its two TTFs through the asset bundle', (tester) async {
    for (final path in [AppType.documentRegular, AppType.documentBold]) {
      final data = await rootBundle.load(path);
      expect(data.lengthInBytes, greaterThan(10000), reason: path);
      // TrueType magic: 0x00010000.
      expect(data.getUint32(0), 0x00010000, reason: '$path is a TTF');
    }
    expect(AppType.documentRegular, 'assets/fonts/Barlow-Regular.ttf');
    expect(AppType.documentBold, 'assets/fonts/Barlow-SemiBold.ttf');
  });
}
