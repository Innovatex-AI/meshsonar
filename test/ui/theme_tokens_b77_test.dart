// Build 77, package W1-A: one meaning per colour.
//   Round 2 N-V3 / Round 5 S4 / D-16: every selected control (chips, segments, tonal buttons, the status strip) is teal;
//   the theme value they share is no longer a blend of the amber.
//   Round 1 N4 / Round 5 decision 10 (tokens): amber is the warning colour only; repeaters, No reply, the link line,
//   friend pins, percent heard and packet types each have their own token, off the amber and off the signal hues.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/theme.dart';

import '../support/colour_science.dart';

double _hue(Color c) => HSLColor.fromColor(c).hue;
double _sat(Color c) => HSLColor.fromColor(c).saturation;

/// Teal as this app means it: the accent family.
bool _isTeal(Color c) => _hue(c) >= 160 && _hue(c) <= 185;

/// Red through green (0..150 deg) with real colour in it: the signal ramp and the amber.
bool _isSignalHue(Color c) => _sat(c) > 0.25 && (_hue(c) < 12 || _hue(c) > 348 || (_hue(c) >= 12 && _hue(c) <= 150));

/// Amber / orange.
bool _isAmber(Color c) => _sat(c) > 0.25 && _hue(c) >= 15 && _hue(c) <= 50;

Future<ThemeData> _pump(WidgetTester tester, Brightness b, Widget child) async {
  final theme = meshSonarTheme(b);
  await tester.pumpWidget(MaterialApp(theme: theme, home: Scaffold(body: Center(child: child))));
  await tester.pumpAndSettle();
  return theme;
}

/// Every fill colour painted by a Material under [finder].
Set<Color> _fills(WidgetTester tester, Finder finder) => {
      for (final m in tester.widgetList<Material>(find.descendant(of: finder, matching: find.byType(Material))))
        if (m.color != null && m.color!.a > 0) m.color!,
    };

void main() {
  for (final b in Brightness.values) {
    group('selected is teal (${b.name})', () {
      final theme = meshSonarTheme(b);
      final cs = theme.colorScheme;

      test('the shared selected fill is the teal container, not an amber blend', () {
        expect(cs.secondaryContainer, cs.primaryContainer);
        expect(cs.onSecondaryContainer, cs.onPrimaryContainer);
        expect(_isTeal(cs.secondaryContainer), isTrue, reason: 'hue ${_hue(cs.secondaryContainer)}');
        expect(_isAmber(cs.secondaryContainer), isFalse);
        expect(contrastRatio(cs.onSecondaryContainer, cs.secondaryContainer), greaterThanOrEqualTo(4.5));
        // The status strip puts the accent spinner and the error icon on this fill.
        expect(contrastRatio(cs.primary, cs.secondaryContainer), greaterThanOrEqualTo(3.0));
        expect(contrastRatio(cs.error, cs.secondaryContainer), greaterThanOrEqualTo(3.0));
      });

      test('chips: the theme sets the selected colour once', () {
        final chips = theme.chipTheme;
        expect(chips.selectedColor, cs.primaryContainer);
        expect(chips.secondarySelectedColor, cs.primaryContainer);
        expect(chips.checkmarkColor, cs.onPrimaryContainer);
        expect(chips.secondaryLabelStyle?.color, cs.onPrimaryContainer);
        expect(contrastRatio(theme.textTheme.labelLarge!.color!, chips.selectedColor!), greaterThanOrEqualTo(4.5));
      });

      test('segments: the theme sets the selected colour once', () {
        final style = theme.segmentedButtonTheme.style!;
        expect(style.backgroundColor!.resolve({WidgetState.selected}), cs.primaryContainer);
        expect(style.backgroundColor!.resolve({}), isNull);
        expect(style.foregroundColor!.resolve({WidgetState.selected}), cs.onPrimaryContainer);
        expect(style.foregroundColor!.resolve({}), cs.onSurface);
      });

      testWidgets('a selected segment (Chart / Table, Units, Battery mode) paints teal', (tester) async {
        await _pump(
          tester,
          b,
          SegmentedButton<int>(
            segments: const [ButtonSegment(value: 0, label: Text('Chart')), ButtonSegment(value: 1, label: Text('Table'))],
            selected: const {0},
            onSelectionChanged: (_) {},
          ),
        );
        final fills = _fills(tester, find.byType(SegmentedButton<int>));
        expect(fills, contains(cs.primaryContainer));
        expect(fills.where(_isAmber), isEmpty);
        final label = tester.widget<RichText>(find.descendant(of: find.text('Chart'), matching: find.byType(RichText)));
        expect(label.text.style?.color, cs.onPrimaryContainer);
      });

      testWidgets('a tonal button ("Allow notifications", "Open Settings") paints teal', (tester) async {
        await _pump(tester, b, FilledButton.tonal(onPressed: () {}, child: const Text('Open Settings')));
        final fills = _fills(tester, find.byType(FilledButton));
        expect(fills, {cs.primaryContainer});
      });

      testWidgets('selected filter and choice chips paint teal', (tester) async {
        await _pump(
          tester,
          b,
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilterChip(label: const Text('Repeaters'), selected: true, onSelected: (_) {}),
            ChoiceChip(label: const Text('1h'), selected: true, onSelected: (_) {}),
            ChoiceChip(label: const Text('24h'), selected: false, onSelected: (_) {}),
          ]),
        );
        Color? fill(String label) {
          final ink = tester.widget<Ink>(
            find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(RawChip)), matching: find.byType(Ink)),
          );
          return (ink.decoration as ShapeDecoration?)?.color;
        }

        expect(fill('Repeaters'), cs.primaryContainer);
        expect(fill('1h'), cs.primaryContainer);
        expect(fill('24h'), isNot(cs.primaryContainer));
      });
    });

    group('colour language tokens (${b.name})', () {
      for (final pal in ColourPalette.values) {
        final theme = meshSonarTheme(b, palette: pal);
        final cs = theme.colorScheme;
        final mc = theme.extension<MeshSonarColors>()!;
        final app = AppColors.fromTheme(theme);
        final sig = MapDefinition.bundled.signal(pal.id, dark: b == Brightness.dark);
        final bands = [for (final v in sig.bands) Color(v)];

        test('${pal.id}: amber is the warning token and nothing else', () {
          expect(_isAmber(mc.warning), isTrue);
          expect(app.warning, mc.warning);
          expect(contrastRatio(mc.warning, cs.surface), greaterThanOrEqualTo(4.5));
          expect(contrastRatio(mc.onWarning, mc.warning), greaterThanOrEqualTo(4.5));
          final others = <String, Color>{
            'repeater': mc.repeater,
            'repeaterTint': mc.repeaterTint,
            'noReply': mc.noReply,
            'linkNeutral': mc.linkNeutral,
            'friend': mc.friend,
            'packetOther': mc.packetType(null),
            for (var i = 0; i < mc.heardStops.length; i++) 'heard$i': mc.heardStops[i],
            for (var i = 0; i < 8; i++) 'packet$i': mc.packetType(i),
            'selected': app.selected,
          };
          others.forEach((name, c) {
            expect(_isAmber(c), isFalse, reason: '$name is amber');
            expect(bands, isNot(contains(c)), reason: '$name is a signal band colour');
          });
        });

        test('${pal.id}: repeaters are neutral, readable, and not the accent', () {
          expect(_sat(mc.repeater), lessThan(0.25));
          expect(_isTeal(mc.repeater) && _sat(mc.repeater) > 0.25, isFalse);
          expect(contrastRatio(mc.repeater, cs.surface), greaterThanOrEqualTo(3.0));
          expect(contrastRatio(mc.repeater, cs.surfaceDim), greaterThanOrEqualTo(3.0));
          expect(contrastRatio(mc.onRepeater, mc.repeater), greaterThanOrEqualTo(4.5));
          expect(contrastRatio(mc.repeater, mc.repeaterTint), greaterThanOrEqualTo(3.0));
          expect(app.repeater, mc.repeater);
          expect(app.repeaterTint, mc.repeaterTint);
        });

        test('${pal.id}: No reply is a neutral, not a red, and differs from "heard, no signal"', () {
          expect(_sat(mc.noReply), lessThan(0.2));
          expect(contrastRatio(mc.noReply, mc.mapBackground), greaterThanOrEqualTo(3.0));
          expect(deltaE(mc.noReply, mc.heardUnknown, Vision.normal), greaterThan(8));
        });

        test('${pal.id}: the link line is white over a dark casing', () {
          expect(mc.linkNeutral, const Color(0xFFFFFFFF));
          expect(contrastRatio(mc.linkNeutral, mc.linkNeutralCasing.withValues(alpha: 1)), greaterThanOrEqualTo(7.0));
          expect(mc.linkNeutralCasing.a, greaterThan(0.7));
        });

        test('${pal.id}: friend pins are not your-position teal', () {
          final d = (_hue(mc.friend) - _hue(cs.primary)).abs();
          expect(d > 180 ? 360 - d : d, greaterThan(90));
          expect(_isSignalHue(mc.friend), isFalse);
          expect(deltaE(mc.friend, cs.primary, Vision.normal), greaterThan(30));
          expect(contrastRatio(mc.friend, cs.surface), greaterThanOrEqualTo(3.0));
          expect(contrastRatio(mc.onFriend, mc.friend), greaterThanOrEqualTo(4.5));
          expect(app.friend, mc.friend);
        });

        test('${pal.id}: percent heard is one teal hue, stepping steadily to the accent', () {
          final s = mc.heardStops;
          expect(s, hasLength(5));
          expect(s.every(_isTeal), isTrue, reason: '${s.map(_hue).toList()}');
          expect(s.last, cs.primary);
          final towardsAccent = [for (final c in s) contrastRatio(c, cs.surface)];
          for (var i = 1; i < s.length; i++) {
            expect(towardsAccent[i], greaterThan(towardsAccent[i - 1]), reason: 'step $i');
          }
          expect(mc.heardAt(0), s.first);
          expect(mc.heardAt(1), s.last);
          expect(mc.heardAt(0.5), s[2]);
          expect(mc.heardAt(double.nan), s.first);
          expect(mc.heardAt(7), s.last);
        });

        test('${pal.id}: packet types are eight distinct colours off the signal hues', () {
          final p = [for (var i = 0; i < 8; i++) mc.packetType(i)];
          expect(p.toSet(), hasLength(8));
          for (final c in p) {
            expect(_isSignalHue(c), isFalse, reason: 'packet colour $c hue ${_hue(c)} sat ${_sat(c)}');
          }
          for (var i = 0; i < p.length; i++) {
            for (var j = i + 1; j < p.length; j++) {
              expect(deltaE(p[i], p[j], Vision.normal), greaterThan(10), reason: 'slots $i and $j');
            }
            expect(contrastRatio(p[i], mc.mapBackground), greaterThanOrEqualTo(3.0), reason: 'slot $i');
            // Against the Standard ramp (red to green). The colour-blind ramp is blue to yellow by design, so a blue
            // packet cannot be far from it; there the line style and the legend carry the difference.
            if (pal == ColourPalette.standard) {
              for (final band in bands) {
                expect(deltaE(p[i], band, Vision.normal), greaterThan(10), reason: 'slot $i vs a signal band');
              }
            }
          }
          expect(mc.packetType(-1), mc.packetType(null));
          expect(mc.packetType(8), mc.packetType(null));
        });
      }

      test('the tokens survive copyWith and lerp', () {
        final mc = MeshSonarColors.forPalette(ColourPalette.standard, b);
        expect(mc.language, ColourLanguage.of(b));
        expect(mc.copyWith(silent: Colors.black).language, mc.language);
        final other = MeshSonarColors.forPalette(ColourPalette.standard, b == Brightness.dark ? Brightness.light : Brightness.dark);
        expect(mc.lerp(other, 0.2).language, mc.language);
        expect(mc.lerp(other, 0.8).language, other.language);
      });
    });
  }
}
