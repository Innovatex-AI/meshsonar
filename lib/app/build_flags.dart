import 'package:flutter/foundation.dart' show kDebugMode;

/// The built-in Simulator (a pretend radio and a drive around Westerville) exists for development and tests only. It is
/// off in release and profile builds, so the App Store / TestFlight app has no way to start a made-up drive. Switch it
/// on in a non-debug build with `--dart-define=MESHSONAR_SIMULATOR=true`. A `const`, so the simulator code is dropped
/// from builds that leave it off.
const bool simulatorAvailable =
    kDebugMode || bool.fromEnvironment('MESHSONAR_SIMULATOR');
