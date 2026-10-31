// What MeshSonar collects, one entry per switchable category (stream 7, "data collected").
//
// This is the metadata the Settings category registry and the first-run disclosure render: a stable id, the switch
// title, the exact disclosure sentence, the stored field keys that belong to the category, and the default. Owner
// decision (Andy, Oct 24 2026): every category is OPT-OUT, i.e. on by default, with a first-run disclosure that lists
// exactly what is collected, a visible switch per category, and turning one off stops it, clears its unsent data and
// offers erase of what was already shared. Nothing here is silent: if it is not listed below, it is not collected.
//
// Design: meshsonar-infra planning stream-7-data-collection.md section 4.1 / 4.6. The field keys are the JSON keys
// written by lib/core/drive_context.dart (per-ping `ctx`, per-session `samples.jsonl`, per-session `context.json`);
// every stored key belongs to exactly one category so a category opt-out can strip or delete it
// (drive_context_test.dart pins that).
//
// Pure Dart: no Flutter imports.

/// Where a category's data goes once collected.
enum CategoryDestination {
  /// The shared live packet feed (`POST /api/cmh/telemetry`). Never carries coordinates.
  telemetryFeed,

  /// Recorded with the driver's own drive on this phone; uploaded with that drive only when the server advertises
  /// that it accepts it (stream 7 section 4.4). Until then it never leaves the phone except in the driver's own export.
  ownDrive,

  /// The phone sends nothing extra; the server derives it from the drive it already holds.
  serverDerived,
}

/// How far the app can collect the category today. The Settings / disclosure UI must not present a category as
/// collecting when it is not ([live] is the only state that collects). Every phone/radio category is [live] since
/// stream 7 WP2/WP3 (recorded during drives, on this phone); weather waits for the server.
enum CategoryAvailability {
  /// Collected by the app today.
  live,

  /// Depends on what the connected server does (weather: `site-config.capabilities.driveEnv` plus v1.2). The Settings
  /// UI shows whether it is active for the server the app uploads to right now (lib/ui/settings/data_sharing.dart
  /// `weatherLive`); the app collects nothing for it either way.
  needsServer,
}

class DataCategory {
  /// Stable id: persisted in settings, used as the server erase key (`DELETE /api/cmh/drive-context?category=<id>`).
  final String id;

  /// The Settings switch title.
  final String title;

  /// The exact sentence the disclosure sheet and the Settings subtitle show: what is collected and where it goes.
  final String disclosure;

  /// Stored JSON keys that belong to this category, each as `<scope>.<key>` where scope is `ctx` (per ping), `sample`
  /// (samples.jsonl) or `session` (context.json). Empty for categories that store nothing on the phone.
  final List<String> fields;

  /// On unless the person turns it off (true for every entry, Andy Oct 24 2026).
  final bool defaultOn;
  final CategoryDestination destination;
  final CategoryAvailability availability;

  /// OS permission the category needs at first use, e.g. 'motion' (iOS Motion & Fitness for the barometer). Null
  /// when none beyond what the app already has.
  final String? permission;
  const DataCategory({
    required this.id,
    required this.title,
    required this.disclosure,
    required this.fields,
    required this.destination,
    required this.availability,
    this.defaultOn = true,
    this.permission,
  });
}

abstract final class CategoryId {
  static const packetHeaders = 'packet_headers';
  static const motion = 'motion';
  static const barometer = 'barometer';
  static const phoneBattery = 'phone_battery';
  static const device = 'device';
  static const radioHealth = 'radio_health';
  static const radioConfig = 'radio_config';
  static const weather = 'weather';
}

/// Shown under the list on the disclosure sheet: what "Saved with your drive" means.
const String savedWithDriveNote =
    '"Saved with your drive" means: on this phone, and uploaded with the drive only when the server you upload to '
    "accepts it (Settings > Privacy & data sharing says which). Your drive's location is handled by your drive privacy "
    'settings (start/end trim, privacy zones), as today.';

/// Heading line of the disclosure sheet.
const String collectionDisclosureHeading =
    'What MeshSonar collects (on unless you turn it off; change it any time in Settings > Privacy)';

/// Every category, in disclosure order.
const List<DataCategory> dataCategories = [
  DataCategory(
    id: CategoryId.packetHeaders,
    title: 'Share packet headers',
    // Same facts as lib/ui/telemetry_sheet.dart (telemetryHelp and its "Shared" / "Never shared" bullets).
    disclosure: 'Packet headers your radio hears: packet type, the repeaters it passed through, signal strength '
        '(SNR, RSSI), time and region. Shared to the live packet feed. Never message text or any message content, '
        'never private channels or direct messages, never your location.',
    fields: [],
    destination: CategoryDestination.telemetryFeed,
    availability: CategoryAvailability.live,
  ),
  DataCategory(
    id: CategoryId.motion,
    title: 'Motion and altitude',
    disclosure: 'Motion and altitude during a drive: height, direction of travel, GPS accuracy. Saved with your drive.',
    fields: ['ctx.alt_m', 'ctx.alt_acc_m', 'ctx.course_deg', 'ctx.course_acc_deg', 'ctx.speed_acc_mps'],
    destination: CategoryDestination.ownDrive,
    availability: CategoryAvailability.live,
  ),
  DataCategory(
    id: CategoryId.barometer,
    title: 'Air pressure',
    disclosure: "Air pressure from your phone's barometer during a drive. Saved with your drive. "
        'iPhone will ask for Motion & Fitness access.',
    fields: ['ctx.pressure_hpa', 'sample.pressure_hpa'],
    destination: CategoryDestination.ownDrive,
    availability: CategoryAvailability.live,
    permission: 'motion',
  ),
  DataCategory(
    id: CategoryId.phoneBattery,
    title: 'Phone battery',
    disclosure: 'Phone battery level and charging during a drive. Saved with your drive.',
    fields: ['ctx.phone_batt_pct', 'sample.batt_pct', 'sample.batt_state', 'sample.low_power'],
    destination: CategoryDestination.ownDrive,
    availability: CategoryAvailability.live,
  ),
  DataCategory(
    id: CategoryId.device,
    title: 'Phone and app details',
    disclosure: 'Phone and app details: system version, phone model, app version. Saved with your drive.',
    fields: ['session.device'],
    destination: CategoryDestination.ownDrive,
    availability: CategoryAvailability.live,
  ),
  DataCategory(
    id: CategoryId.radioHealth,
    title: 'Radio health',
    // BLE signal phone<->radio (sample.ble_rssi) is a stored key but is NOT read yet (needs a flutter_reactive_ble
    // readRssi seam), so the disclosure does not claim it. Add "signal to your phone" here when it is wired.
    disclosure: 'Radio health: radio battery, uptime, error flags and packet counters, airtime, storage and the '
        "radio chip's temperature (when the board reports it), read from your radio once a minute during a drive. "
        'Saved with your drive.',
    fields: [
      'ctx.radio_batt_mv',
      'sample.batt_mv',
      'sample.uptime_s',
      'sample.err_flags',
      'sample.queue',
      'sample.tx_air_s',
      'sample.rx_air_s',
      'sample.last_rssi',
      'sample.last_snr',
      'sample.noise_dbm',
      'sample.pkts',
      'sample.storage_kb',
      'sample.ble_rssi',
      'sample.mcu_temp_c',
    ],
    destination: CategoryDestination.ownDrive,
    availability: CategoryAvailability.live,
  ),
  DataCategory(
    id: CategoryId.radioConfig,
    title: 'Radio settings',
    disclosure: 'Radio settings: board, firmware, power limits. Saved with your drive.',
    fields: ['session.companion_ext'],
    destination: CategoryDestination.ownDrive,
    availability: CategoryAvailability.live,
  ),
  DataCategory(
    id: CategoryId.weather,
    title: 'Weather for my drives',
    disclosure: 'Weather for my drives: the server looks up weather near your drive at about 5 km, when it supports '
        'that (your phone sends nothing extra). Data: Open-Meteo.com, CC BY 4.0.',
    fields: [],
    destination: CategoryDestination.serverDerived,
    availability: CategoryAvailability.needsServer,
  ),
];

/// The category with [id], or null.
DataCategory? dataCategory(String id) {
  for (final c in dataCategories) {
    if (c.id == id) return c;
  }
  return null;
}

/// `<scope>.<key>` -> category id, built from [dataCategories].
final Map<String, String> fieldCategory = {
  for (final c in dataCategories)
    for (final f in c.fields) f: c.id,
};
