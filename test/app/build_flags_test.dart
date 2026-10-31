// The Simulator is a development tool: on in debug builds (so tests and `flutter run` have it), off in release and
// profile builds unless --dart-define=MESHSONAR_SIMULATOR=true. This test runs in debug mode, so it pins the debug side;
// the release side is checked by scripts/verify_release_no_sim.sh against a built app.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/build_flags.dart';
import 'package:meshsonar/radio/radio_api.dart';

void main() {
  test('debug builds have the simulator', () => expect(simulatorAvailable, isTrue));

  test('the stand-in scanner finds nothing and cannot connect', () async {
    const s = NoRadioScanner();
    expect(await s.scan().toList(), isEmpty);
    expect(() => s.connect(const RadioDevice(id: 'x', name: 'x')), throwsStateError);
  });
}
