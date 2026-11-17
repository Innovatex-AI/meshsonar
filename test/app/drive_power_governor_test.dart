// Battery plan §3 / A10: drive GPS precision, pause when parked, cap with no radio, end a drive left open. Fake (monotonic) clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/drive_power_governor.dart';
import 'package:meshsonar/core/drive_gps_tuning.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/radio/radio_api.dart';

final t0 = DateTime.utc(2026, 11, 17, 12);
const lat0 = 39.76, lon0 = -84.19;
const mPerDegLat = 111320.0;

GeoFix fixAt(double northM, {double? speed}) =>
    GeoFix(lat: lat0 + northM / mPerDegLat, lon: lon0, accuracyM: 8, speedMps: speed, at: t0);

Duration min(num m) => Duration(milliseconds: (m * 60000).round());

void main() {
  test('precision follows the profile: best / high / standard', () {
    for (final (p, want) in [
      (PowerSettings.maxData, DriveGpsMode.best),
      (PowerSettings.balanced, DriveGpsMode.high),
      (PowerSettings.saver, DriveGpsMode.standard),
    ]) {
      final g = DrivePowerGovernor(settings: () => p)..start(Duration.zero);
      expect(g.tick(Duration.zero, radioConnected: true).mode, want);
    }
  });

  test('no radio caps the GPS at High (Best only); back to Best on reconnect', () {
    final g = DrivePowerGovernor(settings: () => PowerSettings.maxData)..start(Duration.zero);
    expect(g.tick(min(1), radioConnected: false).mode, DriveGpsMode.high);
    expect(g.tick(min(2), radioConnected: true).mode, DriveGpsMode.best);
    final s = DrivePowerGovernor(settings: () => PowerSettings.saver)..start(Duration.zero);
    expect(s.tick(min(1), radioConnected: false).mode, DriveGpsMode.standard, reason: 'standard is already below High');
  });

  test('parked: after pauseGpsParkedMin still the GPS drops to parked; jitter under 25 m keeps it parked; 50 m restores', () {
    final g = DrivePowerGovernor(settings: () => PowerSettings.balanced)..start(Duration.zero); // 3 min
    g.onFix(fixAt(0), Duration.zero);
    g.onFix(fixAt(10), min(1)); // jitter
    expect(g.tick(min(2.9), radioConnected: true).mode, DriveGpsMode.high);
    expect(g.tick(min(3), radioConnected: true).mode, DriveGpsMode.parked);
    g.onFix(fixAt(40), min(4)); // 40 m: under the 50 m resume distance
    expect(g.tick(min(4), radioConnected: true).mode, DriveGpsMode.parked);
    g.onFix(fixAt(60), min(5));
    expect(g.tick(min(5), radioConnected: true).mode, DriveGpsMode.high);
    expect(g.parked, isFalse);
  });

  test('moving keeps the GPS at the chosen precision; no fix at all is never "parked"', () {
    final g = DrivePowerGovernor(settings: () => PowerSettings.saver)..start(Duration.zero); // 1 min
    for (var i = 0; i < 20; i++) {
      g.onFix(fixAt(i * 30.0), min(i * 0.5));
      expect(g.tick(min(i * 0.5), radioConnected: true).mode, DriveGpsMode.standard);
    }
    final none = DrivePowerGovernor(settings: () => PowerSettings.saver)..start(Duration.zero);
    expect(none.tick(min(60), radioConnected: true).mode, DriveGpsMode.standard);
    expect(none.tick(min(60), radioConnected: true).end, isNull);
  });

  test('Max data never pauses and never ends a drive', () {
    final g = DrivePowerGovernor(settings: () => PowerSettings.maxData)..start(Duration.zero);
    g.onFix(fixAt(0), Duration.zero);
    final d = g.tick(min(600), radioConnected: false);
    expect(d.mode, DriveGpsMode.high); // capped for no radio, not parked
    expect(d.end, isNull);
  });

  test('end a drive left open: parked 30 min (Balanced), once', () {
    final g = DrivePowerGovernor(settings: () => PowerSettings.balanced)..start(Duration.zero);
    g.onFix(fixAt(0), Duration.zero);
    expect(g.tick(min(29.9), radioConnected: true).end, isNull);
    final d = g.tick(min(30), radioConnected: true);
    expect(d.end, const DriveAutoEnd(DriveAutoEndReason.parked, 30));
    expect(d.end!.message, 'Drive ended: parked 30 min');
    expect(g.tick(min(31), radioConnected: true).end, isNull, reason: 'fires once');
  });

  test('end a drive left open: no radio 15 min (Balanced); a reconnect resets the clock', () {
    final g = DrivePowerGovernor(settings: () => PowerSettings.balanced)..start(Duration.zero);
    var t = Duration.zero;
    // Moving all the time, so only the radio rule can fire.
    void at(num m, bool radio, {DriveAutoEnd? expectEnd}) {
      t = min(m);
      g.onFix(fixAt(m * 600.0), t);
      expect(g.tick(t, radioConnected: radio).end, expectEnd, reason: 'at $m min');
    }

    at(0, false);
    at(10, false);
    at(11, true); // back: clock reset
    at(12, false);
    at(26.9, false);
    at(27, false, expectEnd: const DriveAutoEnd(DriveAutoEndReason.noRadio, 15));
    expect(const DriveAutoEnd(DriveAutoEndReason.noRadio, 15).message, 'Drive ended: no radio for 15 min');
  });

  test('0 minutes = never (custom profile)', () {
    final s = PowerSettings.balanced.tweak((s) => s.copyWith(pauseGpsParkedMin: 0, endDriveParkedMin: 0, endDriveNoRadioMin: 0));
    final g = DrivePowerGovernor(settings: () => s)..start(Duration.zero);
    g.onFix(fixAt(0), Duration.zero);
    final d = g.tick(min(1000), radioConnected: false);
    expect(d.mode, DriveGpsMode.high);
    expect(d.end, isNull);
  });

  test('effectiveDriveGpsMode', () {
    expect(effectiveDriveGpsMode(chosen: GpsPrecision.best, radioConnected: true, parked: true), DriveGpsMode.parked);
    expect(effectiveDriveGpsMode(chosen: GpsPrecision.best, radioConnected: false, parked: false), DriveGpsMode.high);
    expect(effectiveDriveGpsMode(chosen: GpsPrecision.high, radioConnected: false, parked: false), DriveGpsMode.high);
  });
}
