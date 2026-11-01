import 'package:flutter/foundation.dart' show kDebugMode;

/// The built-in Simulator (a pretend radio and a drive around Westerville) exists for development and tests only. It is
/// off in release and profile builds, so the App Store / TestFlight app has no way to start a made-up drive. Switch it
/// on in a non-debug build with `--dart-define=MESHSONAR_SIMULATOR=true`. A `const`, so the simulator code is dropped
/// from builds that leave it off.
const bool simulatorAvailable =
    kDebugMode || bool.fromEnvironment('MESHSONAR_SIMULATOR');

/// A development build (debug, or a release build with the simulator switched on) is not a real person's phone.
const bool isDevelopmentBuild = simulatorAvailable;

/// Switches the production guard off: `--dart-define=MESHSONAR_ALLOW_PROD_KEY=true`. Only for a deliberate run of a dev
/// build against production that really should become a driver.
const bool allowProdKeyFromDevBuild = bool.fromEnvironment('MESHSONAR_ALLOW_PROD_KEY');

/// True when [serverUrl] is a MeshSonar production host (meshsonar.com or any subdomain).
bool isProductionServer(String serverUrl) {
  final host = Uri.tryParse(serverUrl.trim())?.host.toLowerCase() ?? '';
  return host == 'meshsonar.com' || host.endsWith('.meshsonar.com');
}

/// May the app create a driver key by itself on [serverUrl]. Always yes in a release build. A development build
/// (simulator QA runs, integration tests, debug runs) must not: every launch with a fresh install would create a
/// throwaway "Driver N" on production (18 did on Nov 1 2026, HANDOFF section 102). [devBuild] and [allowProd] exist for
/// tests; the defaults are the build's own flags. A key the person asks for in Settings is not affected.
bool mayAutoCreateDriverKey(String serverUrl, {bool devBuild = isDevelopmentBuild, bool allowProd = allowProdKeyFromDevBuild}) =>
    !devBuild || allowProd || !isProductionServer(serverUrl);
