// iPhone Low Power Mode -> PowerProfile (battery plan §3). The native channel is mocked here.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/platform/low_power_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('meshsonar/power');
  const events = 'meshsonar/power/events';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    PowerProfile.debugReset();
    await LowPowerModeFollower.debugStop();
  });

  test('not iOS: a no-op (no channel call)', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(method, (_) async {
      calls++;
      return true;
    });
    await LowPowerModeFollower.start(isIOS: false);
    expect(calls, 0);
    expect(PowerProfile.lowPowerMode, isFalse);
    messenger.setMockMethodCallHandler(method, null);
  });

  test('iOS: reads the state and follows change events; Saver while on (followLowPower)', () async {
    messenger.setMockMethodCallHandler(method, (c) async => c.method == 'isOn' ? true : null);
    messenger.setMockStreamHandler(const EventChannel(events), MockStreamHandler.inline(onListen: (_, sink) {}));
    await LowPowerModeFollower.start(isIOS: true);
    expect(PowerProfile.lowPowerMode, isTrue);
    expect(PowerProfile.current.mode, BatteryMode.saver);
    // A change notification from iOS.
    await messenger.handlePlatformMessage(events, const StandardMethodCodec().encodeSuccessEnvelope(false), (_) {});
    expect(PowerProfile.lowPowerMode, isFalse);
    expect(PowerProfile.current.mode, BatteryMode.balanced);
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(const EventChannel(events), null);
  });

  test('a missing channel (tests, other platforms) is harmless', () async {
    await LowPowerModeFollower.start(isIOS: true);
    expect(PowerProfile.lowPowerMode, isFalse);
  });
}
