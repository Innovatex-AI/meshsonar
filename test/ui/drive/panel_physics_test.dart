// Pure panel tests: geometry per device (Drive plan table 4.13), detent chooser and fling table, rubber band, auto-collapse and
// the ping debounce.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/drive/panel/auto_collapse.dart';
import 'package:meshsonar/ui/drive/panel/panel_physics.dart';

PanelGeometry phone(double h, {required double navBar, required double safeBottom}) =>
    PanelGeometry.forScreen(screenHeight: h, navBar: navBar, safeBottom: safeBottom);

void main() {
  group('panel tops per device (table 4.13, tolerance 2 pt)', () {
    final cases = <(String, PanelGeometry, double, double, double)>[
      ('402x874', phone(874, navBar: 106, safeBottom: 34), 752, 680, 366),
      ('393x852', phone(852, navBar: 106, safeBottom: 34), 730, 658, 354),
      ('375x667 SE', phone(667, navBar: 49, safeBottom: 0), 579, 530, 285),
    ];
    for (final (name, g, imm, dock, med) in cases) {
      test(name, () {
        expect(g.topOf(PanelDetent.immersive), closeTo(imm, 2));
        expect(g.topOf(PanelDetent.dock), closeTo(dock, 2));
        expect(g.topOf(PanelDetent.medium), closeTo(med, 2));
      });
    }
    test('map share: >= 77% in Dock on 402x874 and 393x852', () {
      expect(cases[0].$2.mapShareAt(PanelDetent.dock), greaterThanOrEqualTo(0.77));
      expect(cases[1].$2.mapShareAt(PanelDetent.dock), greaterThanOrEqualTo(0.77));
      expect(cases[2].$2.mapShareAt(PanelDetent.dock), closeTo(0.79, 0.01));
      expect(cases[0].$2.mapShareAt(PanelDetent.immersive), closeTo(0.86, 0.01));
      expect(cases[0].$2.mapShareAt(PanelDetent.medium), closeTo(0.42, 0.01));
    });
    test('medium height: 0.46h on phones, 0.5h on short screens', () {
      expect(PanelGeometry.mediumHeightFor(874), closeTo(402, 1));
      expect(PanelGeometry.mediumHeightFor(852), closeTo(392, 1));
      expect(PanelGeometry.mediumHeightFor(667), closeTo(333.5, 1));
    });
    test('no tab bar: Immersive is not offered', () {
      final g = phone(800, navBar: 0, safeBottom: 0);
      expect(g.hasImmersive, isFalse);
      expect(g.detents, [PanelDetent.dock, PanelDetent.medium]);
      expect(g.extentOf(PanelDetent.immersive), g.dockExtent);
    });
  });

  group('detent chooser and fling table', () {
    final g = phone(874, navBar: 106, safeBottom: 34);
    PanelDetent pick(double extent, double v, PanelDetent from) => chooseDetent(extent: extent, velocity: v, geometry: g, from: from);
    final imm = g.immersiveExtent, dock = g.dockExtent, med = g.mediumExtent;

    test('slow release snaps to the nearest detent', () {
      expect(pick(dock + 10, 0, PanelDetent.dock), PanelDetent.dock);
      expect(pick(dock + (med - dock) * 0.4, 0, PanelDetent.dock), PanelDetent.dock);
      expect(pick(dock + (med - dock) * 0.6, 0, PanelDetent.dock), PanelDetent.medium);
      expect(pick(imm + 10, 0, PanelDetent.dock), PanelDetent.immersive);
      expect(pick(imm + (dock - imm) * 0.7, 0, PanelDetent.immersive), PanelDetent.dock);
    });
    test('projection: position + velocity * 0.15 s decides below the fling threshold', () {
      // 600 pt/s up from 30% of the way = +90 pt projected, past the midpoint.
      final start = dock + (med - dock) * 0.3;
      expect(pick(start, 600, PanelDetent.dock), PanelDetent.medium);
      expect(pick(start, 0, PanelDetent.dock), PanelDetent.dock);
      expect(pick(start, -600, PanelDetent.dock), PanelDetent.dock);
    });
    test('a fling over 700 pt/s moves exactly one detent in its direction', () {
      expect(pick(dock + 4, 701, PanelDetent.dock), PanelDetent.medium);
      expect(pick(dock + 4, -701, PanelDetent.dock), PanelDetent.immersive);
      expect(pick(imm + 4, 2000, PanelDetent.immersive), PanelDetent.dock, reason: 'one state, not two');
      expect(pick(med - 4, -2000, PanelDetent.medium), PanelDetent.dock);
      expect(pick(med, 3000, PanelDetent.medium), PanelDetent.medium, reason: 'clamped at the top');
      expect(pick(imm, -3000, PanelDetent.immersive), PanelDetent.immersive);
      expect(pick(dock + 4, 700, PanelDetent.dock), isNot(PanelDetent.immersive));
    });
  });

  group('rubber band', () {
    final g = phone(874, navBar: 106, safeBottom: 34);
    test('formula (1 - 1/(x*0.55/d + 1)) * d, d = 300', () {
      expect(rubberBand(0), 0);
      expect(rubberBand(100), closeTo((1 - 1 / (100 * 0.55 / 300 + 1)) * 300, 1e-9));
      expect(rubberBand(10000), lessThan(300));
      expect(rubberBand(50), lessThan(50));
    });
    test('banded past Medium and below Immersive, linear between', () {
      final hi = g.mediumExtent, lo = g.immersiveExtent;
      expect(bandedExtent(hi - 20, g), hi - 20);
      expect(bandedExtent(hi + 100, g), closeTo(hi + rubberBand(100), 1e-9));
      expect(bandedExtent(lo - 100, g), closeTo(lo - rubberBand(100), 1e-9));
      expect(unbandedExtent(bandedExtent(hi + 80, g), g), closeTo(hi + 80, 1e-6));
      expect(unbandedExtent(bandedExtent(lo - 80, g), g), closeTo(lo - 80, 1e-6));
    });
  });

  group('auto-collapse (5.3)', () {
    final t0 = DateTime.utc(2026, 11, 2, 12);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    test('motion needs 5 mph held for 3 s; cleared after 10 s below 0.5 m/s', () {
      final a = PanelAutoCollapse();
      a.onFix(3.0, at(0));
      expect(a.moving, isFalse);
      a.onFix(3.0, at(2));
      expect(a.moving, isFalse);
      a.onFix(3.0, at(3));
      expect(a.moving, isTrue);
      a.onFix(0.2, at(4));
      a.onFix(0.2, at(13));
      expect(a.moving, isTrue);
      a.onFix(0.2, at(14));
      expect(a.moving, isFalse);
    });
    test('a dip below 2.2 m/s restarts the 3 s hold', () {
      final a = PanelAutoCollapse();
      a.onFix(3.0, at(0));
      a.onFix(1.5, at(2));
      a.onFix(3.0, at(3));
      a.onFix(3.0, at(5));
      expect(a.moving, isFalse);
      a.onFix(3.0, at(6));
      expect(a.moving, isTrue);
    });
    test('collapses after 15 s without touch; every touch resets it; Passenger blocks it', () {
      final a = PanelAutoCollapse();
      a.onFix(5, at(0));
      a.onFix(5, at(3));
      a.touch(at(3));
      expect(a.shouldCollapse(at(17), PanelDetent.medium), isFalse);
      expect(a.shouldCollapse(at(18), PanelDetent.medium), isTrue);
      a.touch(at(17));
      expect(a.shouldCollapse(at(18), PanelDetent.medium), isFalse);
      expect(a.shouldCollapse(at(32), PanelDetent.medium), isTrue);
      expect(a.shouldCollapse(at(32), PanelDetent.dock), isFalse);
      a.passenger = true;
      expect(a.shouldCollapse(at(100), PanelDetent.medium), isFalse);
      a.reset();
      expect(a.passenger, isFalse);
      expect(a.moving, isFalse);
    });
    test('not moving: Medium stays open', () {
      final a = PanelAutoCollapse()..touch(at(0));
      expect(a.shouldCollapse(at(600), PanelDetent.medium), isFalse);
    });
  });

  test('ping debounce: ignored in flight and for 2 s after a tap', () {
    final d = PingDebounce();
    final t0 = DateTime.utc(2026, 11, 2, 12);
    expect(d.accept(t0, inFlight: true), isFalse);
    expect(d.accept(t0, inFlight: false), isTrue);
    expect(d.accept(t0.add(const Duration(milliseconds: 1999)), inFlight: false), isFalse);
    expect(d.accept(t0.add(const Duration(seconds: 2)), inFlight: false), isTrue);
  });
}
