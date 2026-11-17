// The drive-context hook for AppState (stream 7 WP2): builds one DriveContextSession per drive from the app's services
// and the connected link, and reads the versioned disclosure flag. Kept out of app_state.dart so that file only gains
// a few lines (start with the drive, stop with it, feed fixes and saved pings, refresh on a settings change).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/drive_context.dart';
import '../core/drive_context_recorder.dart';
import '../core/drive_context_session.dart';
import '../core/drive_report_battery.dart' show recordDrivePowerMode;
import '../core/drive_store.dart' show JsonlDriveStore;
import '../core/power_profile.dart';
import '../radio/companion_link.dart';
import '../radio/radio_session_impl.dart';
import 'services.dart';

/// The disclosure version that lists every collection category (stream 7 section 4.6). Every existing user sees it
/// once; nothing of the drive-context categories is collected before it has been seen. 3 (release 0.38): rewritten for
/// observer everywhere (the phone observes whenever a radio is connected and the app is open; no Home observer).
const int collectionDisclosureVersion = 3;

/// The ui_prefs.json key holding the disclosure version last seen (lib/ui/onboarding/ui_prefs.dart writes it).
const String collectionDisclosedKey = 'collection_disclosed_v';

/// Whether the ui prefs file says the current collection disclosure was seen. A missing or damaged file = not seen.
bool collectionDisclosureSeenIn(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    final v = j is Map ? j[collectionDisclosedKey] : null;
    return v is num && v >= collectionDisclosureVersion;
  } catch (_) {
    return false;
  }
}

/// The context storage beside the drives, or null when the drive store has none.
DriveContextLedger? contextLedgerOf(AppServices services) {
  final s = services.store;
  return s is DriveContextLedger ? s as DriveContextLedger : null;
}

/// A new, not yet started, context session for drive [sessionId] on [link]; null when the store keeps no context.
DriveContextSession? newDriveContext({
  required AppServices services,
  required String sessionId,
  required LinkRadioSession session,
  required bool Function(String categoryId) isOn,
  required bool Function() pingBusy,
  void Function()? onStatus,
}) {
  final store = services.store;
  // The battery mode at drive start, for the drive report's battery line (local only, never uploaded). The first call
  // of a drive wins; a reconnect mid-drive keeps it.
  if (store is JsonlDriveStore) unawaited(recordDrivePowerMode(store.root, sessionId, PowerProfile.current.mode));
  final ledger = contextLedgerOf(services);
  if (ledger == null) return null;
  final details = services.deviceDetails;
  return DriveContextSession(
    recorder: DriveContextRecorder(ledger: ledger, sessionId: sessionId, isOn: isOn),
    pingBusy: pingBusy,
    radio: session.hasStats ? session : null,
    barometer: services.barometer,
    battery: services.phoneBattery,
    deviceDetails: details?.read,
    companion: session.link is MeshCoreCompanionLink ? () => session.companionDetails : null,
    clock: services.clock,
    onStatus: onStatus,
  );
}
