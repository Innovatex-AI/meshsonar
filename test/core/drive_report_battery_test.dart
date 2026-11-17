// The drive report's phone battery line (build 70): math, wording, the fewer-than-2-samples rule and the local mode file.
import 'dart:io';

import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_report_battery.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 17, 14);

  test('82% to 61% over 1 h 40 min is -21% and -12.6%/h', () {
    final b = batteryUseOf([(t0.add(const Duration(minutes: 100)), 61), (t0, 82), (t0.add(const Duration(minutes: 50)), 70)])!;
    expect(b.startPct, 82);
    expect(b.endPct, 61);
    expect(b.span, const Duration(minutes: 100));
    expect(b.changePct, -21);
    expect(b.perHour, closeTo(-12.6, 1e-9));
    expect(batteryLine(b, mode: BatteryMode.balanced),
        'Battery: 82% → 61% (−21% in 1 h 40 min, −12.6%/h), mode Balanced');
  });

  test('no mode (older drives) leaves it out; charging shows +; a short drive has no rate', () {
    final up = batteryUseOf([(t0, 40), (t0.add(const Duration(hours: 1)), 55)])!;
    expect(batteryLine(up), 'Battery: 40% → 55% (+15% in 1 h 00 min, +15.0%/h)');
    final short = batteryUseOf([(t0, 90), (t0.add(const Duration(minutes: 5)), 89)])!;
    expect(short.perHour, isNull);
    expect(batteryLine(short, mode: BatteryMode.saver), 'Battery: 90% → 89% (−1% in 5 min), mode Saver');
    final flat = batteryUseOf([(t0, 50), (t0.add(const Duration(minutes: 30)), 50)])!;
    expect(batteryLine(flat), 'Battery: 50% → 50% (0% in 30 min, 0%/h)');
  });

  test('fewer than 2 samples, or all at one time: no line', () {
    expect(batteryUseOf(const []), isNull);
    expect(batteryUseOf([(t0, 80)]), isNull);
    expect(batteryUseOf([(t0, 80), (t0, 79)]), isNull);
    expect(batteryLineFromSamples([DriveSample(ts: t0, src: SampleSource.phone, battPct: 80)]), isNull);
    expect(
        batteryLineFromSamples([
          DriveSample(ts: t0, src: SampleSource.phone, battPct: 80),
          DriveSample(ts: t0.add(const Duration(minutes: 20)), src: SampleSource.radio, battMv: 4000),
          DriveSample(ts: t0.add(const Duration(minutes: 30)), src: SampleSource.phone, battPct: 77),
        ], mode: BatteryMode.custom),
        'Battery: 80% → 77% (−3% in 30 min, −6.0%/h), mode Custom');
  });

  test('the mode at drive start is recorded once, beside the drive, and read back', () async {
    final root = await Directory.systemTemp.createTemp('ms_power_mode');
    addTearDown(() => root.delete(recursive: true));
    // No session folder: nothing written.
    await recordDrivePowerMode(root, 's1', BatteryMode.saver);
    expect(await readDrivePowerMode(root, 's1'), isNull);
    await Directory('${root.path}/sessions/s1').create(recursive: true);
    await recordDrivePowerMode(root, 's1', BatteryMode.balanced);
    await recordDrivePowerMode(root, 's1', BatteryMode.saver); // a reconnect mid-drive keeps the first
    expect(await readDrivePowerMode(root, 's1'), BatteryMode.balanced);
    expect(File('${root.path}/sessions/s1/$drivePowerModeFile').readAsStringSync(), 'balanced');
  });
}
