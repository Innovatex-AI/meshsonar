// Andy's colour contract: green (any coverage colour) means measured coverage; mapped with nothing heard is grey;
// heard with no signal reading is its own state, never green.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/theme.dart';

CoverageCell cell({int pings = 10, int heard = 0, double? best, double? noise}) => CoverageCell(
  lat: 40,
  lon: -83,
  pings: pings,
  heard: heard,
  bestSnr: best,
  medianSnr: best,
  repeaters: heard > 0 && best != null ? 1 : 0,
  lastAt: '2026-10-31T10:00:00Z',
  noiseFloor: noise,
);

void main() {
  test('mapped, nothing heard is grey (none) in every colour-by mode that is about hearing', () {
    final c = cell(heard: 0);
    expect(levelFor(c, CoverageColorBy.snr), CoverageLevel.none);
    expect(levelFor(c, CoverageColorBy.heard), CoverageLevel.none, reason: '0% heard is grey, not the red "weak" step');
  });

  test('heard with no SNR reading is "unknown", never a strength colour', () {
    final c = cell(heard: 4, best: null);
    expect(levelFor(c, CoverageColorBy.snr), CoverageLevel.unknown);
  });

  test('measured SNR still buckets as before', () {
    expect(levelFor(cell(heard: 3, best: 6), CoverageColorBy.snr), CoverageLevel.strong);
    expect(levelFor(cell(heard: 3, best: 1), CoverageColorBy.snr), CoverageLevel.good);
    expect(levelFor(cell(heard: 3, best: -3), CoverageColorBy.snr), CoverageLevel.fair);
    expect(levelFor(cell(heard: 3, best: -9), CoverageColorBy.snr), CoverageLevel.weak);
    expect(levelFor(cell(heard: 8), CoverageColorBy.heard), CoverageLevel.strong);
  });

  test('noise colouring is a measurement of its own, independent of hearing', () {
    expect(levelFor(cell(heard: 0, noise: -128), CoverageColorBy.noise), CoverageLevel.strong);
    expect(levelFor(cell(heard: 0), CoverageColorBy.noise), CoverageLevel.none);
  });

  for (final b in Brightness.values) {
    test('ping colours (${b.name}): nothing heard is grey, unknown SNR is not a green/teal strength colour', () {
      final mc = b == Brightness.dark ? MeshSonarColors.dark : MeshSonarColors.light;
      final grey = mc.forPing(heard: false);
      final hsl = HSLColor.fromColor(grey);
      expect(hsl.saturation, lessThan(0.2), reason: 'grey');
      final unknown = mc.forPing(heard: true);
      expect(unknown, mc.heardUnknown);
      expect(unknown, isNot(mc.snrMid));
      expect(unknown, isNot(mc.snrStrong));
      expect(mc.forPing(heard: true, snr: 9), isNot(grey));
    });
  }
}
