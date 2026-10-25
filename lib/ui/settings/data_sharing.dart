// The one source of truth for what MeshSonar collects and shares, and the words used to say so. The first-run sheet
// (lib/ui/telemetry_sheet.dart), Settings > Privacy & data sharing and the "What MeshSonar shares" page all read from
// here, so they can never disagree.
//
// Owner decision (Andy, Oct 2026, binding): every kind of data collection is OPT-OUT, on by default, disclosed at first
// run with exactly what is collected, and has its own visible switch in Settings. Turning a switch off stops
// collection at once, deletes what is still waiting on the phone, and offers to erase what the server holds.
//
// Adding a category (device sensors, weather context, a settings snapshot, radio metrics): add one [DataCategory] to
// [dataCategories] with its Settings field, its first-run wording and, when the server can erase it, [eraseFromServer].
// The first-run sheet, the Settings switch, the confirmations and the "What MeshSonar shares" page follow from that
// entry. Only list a category once the app really collects it.
//
// Stream 7 (data collected): the drive-context categories of lib/core/data_categories.dart (the pure-Dart list: ids,
// stored field keys, the one-sentence disclosure) are mapped one-to-one onto entries here ([driveContextCategories]),
// so the core sentence is the Settings subtitle and the sheet line. Their data stays on this phone (no server accepts
// it yet), so turning one off offers to delete it from this phone instead of a server erase.
import '../../app/app_state.dart';
import '../../core/api.dart';
import '../../core/data_categories.dart' as core;
import '../../core/phone_sensors.dart';

/// The Settings section that holds the switches; the first-run sheet points people here by this exact name.
const String privacySectionTitle = 'Privacy & data sharing';

class DataCategory {
  /// Stable id (also used in widget keys).
  final String id;

  /// The switch's key in Settings. Kept as it was for packet headers ('telemetry-toggle').
  final String toggleKey;

  /// Switch title in Settings, e.g. "Share packet headers".
  final String title;

  /// One line under the switch: what is shared, in a few words.
  final String summary;

  /// First-run sheet heading and lead paragraph.
  final String disclosureTitle;
  final String disclosureLead;

  /// Exactly what is sent, one item per line.
  final List<String> shared;

  /// What is never sent, one item per line.
  final List<String> neverShared;

  /// When it is collected and where it goes.
  final String destination;

  /// What turning the switch off does, in one sentence.
  final String offEffect;

  /// Button labels on the first-run sheet.
  final String keepLabel;
  final String offLabel;

  final bool Function(Settings s) isOn;
  final Settings Function(Settings s, bool on) set;

  /// Asks the server to delete what this phone sent; returns how many items were erased, or null when it could not be
  /// done now (it is retried). Null when the server keeps nothing that could be erased.
  final Future<int?> Function(AppState s)? eraseFromServer;

  /// Wording for the erase action and its result, e.g. "packet headers".
  final String erasedNoun;

  /// Items waiting on the phone, shown under the switch. Null = nothing to show.
  final int Function(AppState s)? queued;

  /// The server has an erase request it has not completed yet.
  final bool Function(AppState s)? erasePending;

  /// The lib/core/data_categories.dart id this entry switches.
  final String coreId;

  /// The data stays on this phone (recorded with the driver's own drives, never uploaded yet): turning it off offers
  /// [deleteLocal] instead of a server erase.
  final bool localOnly;

  /// Line under the switch while it is on (e.g. "no barometer on this phone"); null = nothing to add.
  final String? Function(AppState s)? onStatus;

  const DataCategory({
    required this.id,
    required this.toggleKey,
    required this.title,
    required this.summary,
    required this.disclosureTitle,
    required this.disclosureLead,
    required this.shared,
    required this.neverShared,
    required this.destination,
    required this.offEffect,
    required this.keepLabel,
    required this.offLabel,
    required this.isOn,
    required this.set,
    required this.erasedNoun,
    this.eraseFromServer,
    this.queued,
    this.erasePending,
    this.coreId = '',
    this.localOnly = false,
    this.onStatus,
  });

  /// Deletes what this phone recorded for the category from every drive on it; returns how many drives changed.
  Future<int> deleteLocal(AppState s) => s.deleteCollectedLocally(coreId);

  /// The core metadata (stored field keys, destination, availability).
  core.DataCategory? get meta => core.dataCategory(coreId);
}

bool _telemetryOn(Settings s) => s.telemetryEnabled;
Settings _setTelemetry(Settings s, bool on) => s.copyWith(telemetryEnabled: on);
Future<int?> _eraseTelemetry(AppState s) => s.eraseTelemetry();
int _telemetryQueued(AppState s) => s.telemetryQueued;
bool _telemetryErasePending(AppState s) => s.telemetryErasePending;
String? _telemetryStatus(AppState s) {
  final waiting = s.telemetryQueued;
  if (!s.hasKey) return 'On, but nothing is collected until this phone has a driver key.';
  return waiting > 0 ? '$waiting waiting on this phone to be sent.' : null;
}

/// Packet-header telemetry (lib/core/telemetry.dart is the record; its wire keys are pinned by a test). Changing what
/// the record holds means changing [shared] here in the same commit.
const DataCategory telemetryCategory = DataCategory(
  id: 'telemetry',
  toggleKey: 'telemetry-toggle',
  title: 'Share packet headers',
  summary: 'Type, path, signal strength, time and region. Never message content.',
  disclosureTitle: 'Help build the live packet feed',
  disclosureLead: 'MeshSonar can share what your radio overhears on the mesh, so everyone gets a live view of the '
      'network. This is on unless you turn it off.',
  shared: [
    'Packet type and route type',
    'The repeaters it passed through (their short path codes)',
    'Signal strength: SNR and RSSI',
    'The time it was heard and your region code (for example CMH), never your position',
    'A fingerprint of the packet (a hash, not its content), so copies heard by others are counted once',
    'The app version and phone platform (iOS or Android)',
  ],
  neverShared: [
    'Message text or any message content',
    'Private channels and direct messages (those packets are never recorded at all)',
    'Your name, or your location attached to packets',
    'Your own pings and their echoes',
  ],
  destination: 'Collected only while this phone has a driver key, and sent only to your server '
      '(the Server URL in Settings) once the key is approved.',
  offEffect: 'Turning it off stops collection at once and deletes the headers still waiting on this phone.',
  keepLabel: 'Share headers',
  offLabel: 'Turn off',
  isOn: _telemetryOn,
  set: _setTelemetry,
  eraseFromServer: _eraseTelemetry,
  erasedNoun: 'packet headers',
  queued: _telemetryQueued,
  erasePending: _telemetryErasePending,
  coreId: core.CategoryId.packetHeaders,
  onStatus: _telemetryStatus,
);

/// Where every drive-context category's data goes today (stream 7 section 4.2/4.4: local first; uploaded only once
/// the server advertises it accepts it, which no server does yet).
const String ownDriveDestination = 'Recorded only while a drive is running, saved with that drive on this phone and '
    'shown in its drive report. Not uploaded: the server does not accept it yet. It is in the drive\'s Export file, '
    'which is yours.';

const String ownDriveOffEffect = 'Turning it off stops it at once. Nothing of it has left this phone, so there is '
    'nothing to erase on the server; you can delete what is saved on this phone.';

DataCategory _driveCategory(
  String coreId, {
  required List<String> shared,
  required List<String> neverShared,
  required String erasedNoun,
  String destination = ownDriveDestination,
  String offEffect = ownDriveOffEffect,
  bool localOnly = true,
  String? Function(AppState s)? onStatus,
}) {
  final m = core.dataCategory(coreId)!;
  return DataCategory(
    id: coreId,
    toggleKey: 'collect-$coreId-toggle',
    title: m.title,
    summary: m.disclosure,
    disclosureTitle: m.title,
    disclosureLead: m.disclosure,
    shared: shared,
    neverShared: neverShared,
    destination: destination,
    offEffect: offEffect,
    keepLabel: 'Turn on',
    offLabel: 'Turn off',
    isOn: (s) => s.collectionOn(coreId),
    set: (s, on) => s.withCollection(coreId, on),
    erasedNoun: erasedNoun,
    coreId: coreId,
    localOnly: localOnly,
    onStatus: onStatus,
  );
}

String? _barometerStatus(AppState s) => switch (s.barometerStatus) {
      SensorStatus.unsupported => 'This phone or app build has no barometer support, so nothing is read.',
      SensorStatus.unavailable =>
        'The phone gave no barometer readings on the last drive: it has no barometer, or Motion & Fitness access is '
            'off for MeshSonar in the phone\'s Settings.',
      SensorStatus.notStarted => 'Read during your next drive. iPhone asks for Motion & Fitness access the first time.',
      SensorStatus.reading => 'Reading the barometer during this drive.',
    };

String? _weatherStatus(AppState s) => s.siteConfig?.driveEnv == true
    ? 'This server says it looks up weather for uploaded drives. The app does not show it yet.'
    : 'Not available yet: no MeshSonar server looks up weather for drives today, so nothing is collected or sent. '
        'Your choice is kept for when it is.';

/// The stream-7 drive-context categories, in disclosure order (lib/core/data_categories.dart).
final List<DataCategory> driveContextCategories = [
  _driveCategory(core.CategoryId.motion,
      shared: [
        'Height above sea level and how accurate it is, from GPS, at each ping',
        'Direction of travel and how accurate it is (from GPS movement, not the compass)',
        'How accurate the GPS speed was',
      ],
      neverShared: ['Anything while no drive is running'],
      erasedNoun: 'motion and altitude data'),
  _driveCategory(core.CategoryId.barometer,
      shared: [
        'Air pressure from the phone barometer, read once a second during a drive and kept as a one-minute median and '
            'one value per ping (inside a car this is cabin pressure, close to outside pressure)',
      ],
      neverShared: ['Any other motion or fitness data (steps, activity)', 'Anything while no drive is running'],
      erasedNoun: 'air pressure readings',
      onStatus: _barometerStatus),
  _driveCategory(core.CategoryId.phoneBattery,
      shared: [
        'Battery level in percent, once a minute and when charging changes',
        'Charging, full or unplugged',
        'Low Power Mode (battery saver) on or off',
      ],
      neverShared: ['Anything while no drive is running'],
      erasedNoun: 'phone battery readings'),
  _driveCategory(core.CategoryId.device,
      shared: [
        'System (iOS or Android) and its version',
        'Phone model code (for example iPhone15,2)',
        'App build number',
      ],
      neverShared: [
        'Your phone\'s name',
        'Advertising or device identifiers',
        'Your IP address, Wi-Fi or carrier',
      ],
      erasedNoun: 'phone and app details'),
  _driveCategory(core.CategoryId.radioHealth,
      shared: [
        'Radio battery voltage, uptime and transmit queue length',
        'Radio error flags (queue full, channel-activity timeout, receive-start timeout)',
        'Packet counters: received, sent, flood and direct',
        'Transmit and receive airtime, the last packet\'s signal strength and SNR, the noise floor',
        'Radio storage used',
        'The radio chip\'s temperature, when the board reports it (its processor, not the air)',
      ],
      neverShared: [
        'Messages, contacts or channel content on the radio',
        'Anything asked while a ping is being sent or listened for',
      ],
      erasedNoun: 'radio health readings'),
  _driveCategory(core.CategoryId.radioConfig,
      shared: [
        'Board model, firmware version, build date and code',
        'The highest transmit power the radio allows',
        'Path hash mode',
      ],
      neverShared: ['Channel names or secrets', 'Contacts'],
      erasedNoun: 'radio settings'),
  _driveCategory(core.CategoryId.weather,
      shared: ['Nothing from your phone: the server would look up weather near your uploaded drive'],
      neverShared: ['Your live position (the phone contacts no weather service)'],
      destination: 'Done by the server from the drive it already holds, with the position rounded to a coarse grid of a few kilometres. '
          'Weather data: Open-Meteo.com, CC BY 4.0.',
      offEffect: 'Turning it off asks the server not to look up weather for your drives.',
      localOnly: false,
      erasedNoun: 'weather lookups',
      onStatus: _weatherStatus),
];

/// Every kind of data collection the app does, in disclosure order. Only real categories belong here (see the file
/// comment); weather is listed because the person can already choose, and says plainly that it is not active yet.
final List<DataCategory> dataCategories = [telemetryCategory, ...driveContextCategories];

/// Kept for callers of the old constant: one-line help for the packet-header switch.
const String telemetryHelp =
    'Shares packet headers and signal strength your radio hears, to build the live packet feed. Never message text.';

/// "Change your mind any time in Settings, under Privacy & data sharing."
const String changeYourMindLine = 'Change your mind any time in Settings, under $privacySectionTitle.';

// ---------- other flows that are not switches (shown on "What MeshSonar shares") ----------

class DataFlow {
  final String title;
  final String body;
  const DataFlow(this.title, this.body);
}

/// The rest of what leaves the phone, each controlled somewhere else (and said where).
const List<DataFlow> otherDataFlows = [
  DataFlow('Your drives',
      'Each ping\'s time, position, signal and which repeaters heard it, plus the antenna setup. Uploaded only to your '
          'server, under your driver key, when uploads are on (Settings > Drives & uploads). Without a key nothing is '
          'uploaded. Privacy zones on the website hide pings near places you choose.'),
  DataFlow('The ping itself',
      'What your radio transmits is exactly "MS:" and 10 random characters. Never your position, name or any '
          'identifier.'),
  DataFlow('Problem reports',
      'Only when you send one. You see the whole report before it goes; secrets are removed and positions rounded.'),
  DataFlow('Region and map data',
      'The app downloads coverage, region pages, repeater names and map packs. Those requests carry no driver key, '
          'except repeater names, which come from your server with your key.'),
];

// ---------- location (the "Always" explainer) ----------

/// The four points of the "Always" location explainer (lib/ui/always_location_screen.dart), also summarised in
/// Settings > Privacy & data sharing > Location while driving.
const List<({String head, String body})> locationPoints = [
  (
    head: 'Why "Always"',
    body: 'On a drive your phone is usually locked or showing navigation. Without Always, iOS stops giving MeshSonar '
        'your position and the drive has gaps.',
  ),
  (
    head: 'Which region you are in',
    body: 'The same position is used on this phone to tell which MeshSonar region you are in (for example Columbus or '
        'Dayton) and to tell you when you cross into another. The last place is kept on this phone so the app opens on '
        'the right region.',
  ),
  (
    head: 'What it is NOT used for',
    body: 'Nothing is recorded or sent when you are not driving: between drives a coarse, low-power position only keeps '
        'the region right, on this phone. Position is never put in the on-air ping, and drive data goes only to the '
        'server you chose, under your driver key.',
  ),
  (
    head: 'You stay in control',
    body: 'iOS shows a blue bar while MeshSonar uses your location in the background. You can change this any time in '
        'iOS Settings > MeshSonar > Location.',
  ),
];

/// One line for the Settings row.
const String locationSummary =
    'Used to record each ping and to know your region. Never in the on-air ping; change it in iOS Settings.';
