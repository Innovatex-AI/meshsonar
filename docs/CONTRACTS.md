# MeshSonar build contracts (read first)

MeshSonar is an open-source (MIT) MeshCore wardriving app: Flutter, one codebase for iPhone, iPad, Android, macOS, Linux.
It pings a channel from a MeshCore companion radio, listens for repeater echoes, records every ping with GPS, saves
locally first, exports files, and syncs to CMAT (or any server implementing the spec).

- Upload/export format: `/home/claude/meshcore-insights/docs/MESHSONAR_DRIVE_FORMAT.md` (server validator:
  `/home/claude/meshcore-insights/src/lib/drive/validate.ts`). The app must produce exactly what that accepts.
- Shared types (do not change without telling the lead): `lib/core/model.dart`, `lib/core/api.dart`, `lib/radio/radio_api.dart`.
  If a contract is wrong or missing something, implement around it and report the needed change in your final message.

## Toolchain
- Flutter: `export PATH=/opt/flutter/bin:$PATH` (running as root prints a warning; ignore it).
- Tests: `flutter test` (widget + unit). Pure-Dart code must not import Flutter (`lib/core`, and `lib/radio` except the BLE transport).
- `flutter analyze` must be clean for your files.
- **Do not run git commands** (no commit, no branch). The lead commits.
- Do not edit files outside your folders except where your brief says so.

## Folder ownership
| Folder | Owner |
|---|---|
| `lib/core/` (except model.dart, api.dart) + `test/core/` | Agent A — storage, sync, settings |
| `lib/radio/` (except radio_api.dart) + `test/radio/` | Agent B — MeshCore protocol, BLE, wardrive engine, simulator |
| `lib/ui/`, `lib/app/`, `lib/platform/`, `lib/main.dart`, `test/ui/`, platform config (ios/, android/, macos/, linux/) | Agent C — app UI |

## Concrete classes and constructors (implement exactly these names)

Agent A (`lib/core/`):
- `JsonlDriveStore` implements `DriveStore` — `static Future<JsonlDriveStore> open(Directory root)`
- `HttpCmatClient` implements `CmatClient` — `HttpCmatClient(Uri baseUrl, {http.Client? client})`
- `DefaultSyncService` implements `SyncService` — `DefaultSyncService({required DriveStore store, required CmatClient client, required SettingsStore settings, AppInfo app = const AppInfo(name: 'MeshSonar', version: '0.1.0')})`
- `FileSettingsStore` implements `SettingsStore` — `FileSettingsStore(File file)`
- Files: `lib/core/drive_store.dart`, `lib/core/cmat_client.dart`, `lib/core/sync_service.dart`, `lib/core/settings_store.dart`

Agent B (`lib/radio/`):
- `MeshCoreCompanionLink` implements `CompanionLink` — `MeshCoreCompanionLink(ByteTransport transport)` (`lib/radio/companion_link.dart`)
- `DefaultWardriveEngine` implements `WardriveEngine` — `DefaultWardriveEngine({required CompanionLink link, required LocationSource location, DateTime Function()? clock, String Function()? newId})` (`lib/radio/wardrive_engine.dart`)
- `BleRadioScanner` implements `RadioScanner` — `BleRadioScanner()` (flutter_reactive_ble; `lib/radio/ble_transport.dart`; the only Flutter-dependent radio file)
- Simulator (no hardware; used by the app's "Simulator" mode, by UI tests and by demos), `lib/radio/simulator.dart`:
  - `SimulatedRadioScanner` implements `RadioScanner` (lists one device "MeshSonar Simulator"; connect returns a `SimulatedTransport`)
  - `SimulatedTransport` implements `ByteTransport` — speaks the real companion protocol frames, so `MeshCoreCompanionLink` runs unchanged on it
  - `SimulatedLocationSource` implements `LocationSource` — drives a loop through Westerville, Ohio (around 40.126, -82.93) at ~13 m/s
  - Simulated repeaters at fixed points; echo odds and SNR fall with distance; some pings hear nothing.

Agent C (`lib/app/`, `lib/ui/`, `lib/platform/`):
- `GeolocatorLocationSource` implements `LocationSource` (`lib/platform/geolocator_location.dart`)
- `AppServices` (`lib/app/services.dart`): holds DriveStore, CmatClient factory, SyncService, SettingsStore, RadioScanner(s),
  LocationSource, and a factory `WardriveEngine Function(CompanionLink, LocationSource)`. `main.dart` builds the real one;
  tests build one from fakes.

## Behaviour that matters (all agents)
- Save first: a ping goes to the local store the moment it's finished, before any upload.
- A ping that heard nothing is kept (`echoes: []`). Never drop it.
- Unmeasured = null. Never invent SNR, RSSI, hops or noise floor.
- Uploads: ≤5,000 pings per request; pings are marked synced only after the server answers 200; 403 = key not approved
  (stop and show status); network errors keep pings for the next try.
- MIT attribution: code ported or adapted from MeshCore Open (`/home/claude/zjs81/meshcore-open`, MIT, © 2025 zjs81) or
  the MeshMapper web client (`/home/claude/meshmapper/meshmapper_webclient`, MIT, © 2025 MrAlders0n) must say so in a
  header comment and be listed in `THIRD_PARTY_NOTICES.md` (create or append your section).
