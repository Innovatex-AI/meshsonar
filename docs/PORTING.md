# Porting MeshSonar

This guide covers taking MeshSonar to another platform (Android, web, Linux, Windows, macOS) or rewriting it without
Flutter. Read [ARCHITECTURE.md](ARCHITECTURE.md) first for the layers and [PROTOCOL.md](PROTOCOL.md) /
[DATA_MODEL.md](DATA_MODEL.md) for the contracts.

## 1. What is reusable as-is

| Code | Depends on | Reuse |
|---|---|---|
| `lib/core/*` | `dart:io`, `package:http`, `package:path` | Any Dart VM target: mobile, desktop, CLI, server. `dart:io` (`File`, `SocketException`) rules out the web for `drive_store.dart`, `settings_store.dart`, `repeater_directory.dart` and the `SocketException`/`HandshakeException` catches in `cmat_client.dart`. |
| `lib/radio/*` except `ble_transport.dart` | `package:uuid`, `dart:typed_data` | Any Dart target, web included: protocol codec, packet parser, crypto, link, engine, simulator. |
| `lib/ui/drive_stats.dart`, `lib/ui/report/drive_report.dart` | `core/model.dart`, `core/heard.dart` | Pure Dart despite living in `ui/`; good candidates to move into `core`. |
| `lib/ui/map/map_layers.dart` (`heardSnapshot`, `HeardView`) | `flutter/foundation` for `@immutable` only | Trivially made pure. |

All of `lib/radio` runs against the simulator, so a new UI or platform can be built and tested end to end without a
radio, a GPS or a server.

## 2. Platform seams

Every platform dependency sits behind an interface or a function in `AppServices` (`lib/app/services.dart`).
`lib/app/wiring.dart` is where the real ones are chosen.

| Seam | Interface | Current implementation | Notes for a port |
|---|---|---|---|
| BLE radio | `RadioScanner` + `ByteTransport` (`radio_api.dart`) | `BleRadioScanner` (flutter_blue_plus) | Keep the framing: one write = one frame, one notification = one frame. UUIDs are in [PROTOCOL.md §1](PROTOCOL.md#1-transport-bluetooth-le). Request MTU ≥ 185 where possible. |
| Companion protocol | `CompanionLink` | `MeshCoreCompanionLink` | Pure Dart. Only a USB-serial or TCP transport would need a new `ByteTransport` (serial companions add a length prefix: not implemented). |
| GPS | `LocationSource` (`fixes`, `current()`, `ensurePermission()`) | `FilteredLocationSource(GeolocatorLocationSource())` | Keep the filter: wrap any new source in `FilteredLocationSource`. Report `accuracyM` and `speedMps` as null when unknown, never 0. |
| Local store | `DriveStore` (+ optional `SyncLedger`) | `JsonlDriveStore` (`dart:io` files) | Without `SyncLedger`, rejected ids and end markers are kept only in memory. |
| Settings | `SettingsStore` | `FileSettingsStore` | One JSON document (see DATA_MODEL). |
| Repeater name cache | `RepeaterCache` | `FileRepeaterCache` / `MemoryRepeaterCache` | |
| Public node directory | `RepeaterDirectory?` (null = off) | `RepeaterDirectory(cacheFile: File)` | Needs `dart:io` for its cache file. Pass `null` to disable. |
| UI prefs | `AppServices.uiPrefsFile` (null = in memory) | `FileUiPrefs` | |
| File locations | `wiring.dart _dataRoot()`, `exportDir` | `path_provider` support dir / temp dir | |
| Share | `AppServices.shareFile(File)` | `shareDriveFile` (share_plus) | Takes a `dart:io File`. A web port needs a bytes-based variant (download). |
| Wake lock + haptics | `DeviceFeedback` (`ui/device_feedback.dart`) | `wakelock_plus`, `HapticFeedback` | Already no-op tolerant. |
| Background operation | Platform config + `GeolocatorLocationSource._settings()` | Android foreground-service notification; iOS `allowBackgroundLocationUpdates` + `UIBackgroundModes` | See the per-target sections below. |
| Map tiles | `CoverageMap.tileUrl` | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` with UA package `com.meshsonar.app` | See ROADMAP: heavy use needs another provider. |
| Clock and ids | `AppServices.clock`, `newId` | `DateTime.now`, UUID v4 | Tests inject fakes. |
| Theme override | env `MESHSONAR_THEME=dark\|light` | desktop only | For screenshots. |

## 3. Per-target checklists

### Android

The Android project exists (`android/`, package `com.meshsonar.app`, Kotlin DSL). The repo history records no
device testing, so treat it as untested.

- [x] **Manifest permissions** (`android/app/src/main/AndroidManifest.xml`): `BLUETOOTH_SCAN`
  (`neverForLocation`, API 31+), `BLUETOOTH_CONNECT`, legacy `BLUETOOTH` / `BLUETOOTH_ADMIN` (max SDK 30),
  `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`,
  `POST_NOTIFICATIONS`, `WAKE_LOCK`, `INTERNET`, and `uses-feature bluetooth_le` (not required).
- [x] **Foreground service for GPS with the screen off.** `GeolocatorLocationSource` passes an
  `AndroidSettings.foregroundNotificationConfig` ("MeshSonar is recording a drive", wake lock, ongoing). geolocator's
  own manifest declares `GeolocatorLocationService` with `foregroundServiceType="location"`.
- [ ] **Runtime permissions.** flutter_blue_plus requests the BLE permissions when scanning or connecting.
  geolocator's `requestPermission()` asks for location. **Nothing requests `POST_NOTIFICATIONS`** (Android 13+), so the
  foreground-service notification may be hidden until the user allows notifications. Verify this on a device.
- [ ] **Background location.** `ACCESS_BACKGROUND_LOCATION` is not declared. The foreground service is meant to cover
  screen-off driving. Confirm pings keep firing with the screen off, and with another app (navigation) in front.
- [ ] **BLE scan on Android ≤ 11** needs location services switched on.
- [ ] **Release signing.** `build.gradle.kts` still signs release builds with the debug key (Flutter template TODO).
  Add a keystore before publishing.
- [ ] Check `minSdk` (Flutter default) against flutter_blue_plus and geolocator requirements.
- [ ] MTU: `requestMtu(185)` runs on Android. flutter_blue_plus also asks for 512 on connect by default, but
  MeshSonar passes `mtu: null` and requests 185 itself.

### iOS / iPadOS

This is the platform it's developed on (see [DEVELOPMENT.md](DEVELOPMENT.md)). Deployment target is 15.0 and the
bundle id is `com.meshsonar.app`.

- [x] `Info.plist`: `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, and `UIBackgroundModes` =
  `location`, `bluetooth-central`.
- [x] Location settings: `bestForNavigation`, `automotiveNavigation`, no auto-pause, background indicator on,
  `allowBackgroundLocationUpdates: true`.
- [ ] **Background operation is unverified.** The app only asks for when-in-use permission (`requestPermission()`),
  and the Drive screen keeps the display awake. Whether auto-pings continue with the screen locked or another app in
  front has not been tested.
- [ ] Device ids (`remoteId`) are per-phone UUIDs on iOS, not MAC addresses. Don't persist them across devices.

### macOS

- [x] `macos/Runner/Info.plist`: Bluetooth and location usage strings. Entitlements: sandbox, Bluetooth, location,
  network client (+ JIT/server in Debug).
- [x] BLE via `flutter_blue_plus_darwin` (CoreBluetooth). MTU is negotiated automatically.
- [ ] Location comes from CoreLocation (usually Wi-Fi based, no GPS). It's fine for the Simulator. Real wardriving from
  a Mac needs an external GPS that macOS exposes through CoreLocation.

### Linux

- [x] Builds (`flutter build linux`). A release bundle exists under `build/linux/x64/release/bundle`. Screenshots are
  checked under Xvfb (see DEVELOPMENT.md).
- [x] **BLE:** `flutter_blue_plus_linux` (BlueZ over D-Bus; pure Dart, so it isn't in `generated_plugins.cmake`).
  MeshSonar skips `requestMtu` on Linux. Needs `bluetoothd` running and the user allowed to use it.
- [ ] **GPS:** `geolocator_linux` (beta) uses **GeoClue2**. GeoClue must be installed and the app allowed in its
  config. A USB GPS works through gpsd → GeoClue. Without GeoClue, `ensurePermission()` returns false and Start drive
  shows the location message. Simulator mode doesn't need it.
- [ ] Data lives in `$XDG_DATA_HOME/com.meshsonar.app/meshsonar/` (see DATA_MODEL §2).
- [ ] **Export & share doesn't work on Linux.** `share_plus` 13.3.1 throws `UnimplementedError('Sharing files not
  supported on Linux')`, which the app shows as a short error. The export file is still written to the temp folder
  first (`$TMPDIR/meshsonar_export/`). Add a "Save as…" path for desktop.

### Windows

- [ ] The runner exists (`windows/`) and the plugin list includes `flutter_blue_plus_winrt` (0.0.22, pulled in by
  flutter_blue_plus) and `geolocator_windows`. **Not built or tested.** Treat BLE on Windows as experimental: check
  write-without-response, notifications and disconnect detection against a real companion.
- [ ] Paths: `wiring.dart` uses `Platform.pathSeparator`. `drive_report_screen.dart` builds the report file path
  with `/`, which Windows also accepts.

### Web

A web build **compiles** once a `web/` folder is added (`flutter create --platforms=web .`; checked with
`flutter build web` on a scratch copy). It does **not run** as is: `buildRealServices()` calls `path_provider`, which
has no web implementation, so the app opens on the "couldn't start" screen. Checklist:

- [ ] **Storage:** implement `DriveStore` (+ `SyncLedger`), `SettingsStore`, `RepeaterCache` and UI prefs over
  IndexedDB (or `shared_preferences` for the small ones). Keep the same JSON documents. Append-only per-ping writes map
  well onto one object store keyed by `(sessionId, pingId)`.
- [ ] **Web Bluetooth** (`flutter_blue_plus_web`): Chromium browsers only (Chrome, Edge, Android Chrome; not Safari or
  Firefox), HTTPS only, and the device picker needs a user gesture. Scan results come from the browser's chooser, not
  a background scan. MeshSonar already skips `requestMtu` on web.
- [ ] **No background:** a hidden tab is throttled, so drives only work with the tab in front and the screen on (the
  Screen Wake Lock API through wakelock_plus helps).
- [ ] **GPS:** browser Geolocation (`geolocator_web`). Speed and accuracy are often null. Keep the filter.
- [ ] **CORS:** CMAT's `/api/cmh/*` handlers send **no CORS headers** today. A browser client needs
  `Access-Control-Allow-Origin` and a preflight that allows `content-type` and `x-driver-key` on `driver-request`,
  `driver-status`, `drive-upload` and `drive-repeaters`. map.meshcore.io would also need CORS, and a ~52 MB JSON
  download is too heavy for a browser. Disable the directory (`directory: null`) or proxy a filtered list through
  CMAT. OSM tiles load as images and work cross-origin.
- [ ] **Export:** replace `File` + share sheet with a browser download (`Blob`).
- [ ] `dart:io` `Platform` calls are wrapped in `try`/`kIsWeb` checks in the UI (theme, map tiles, device feedback)
  and in `ble_transport.dart`. `messages.dart` and `cmat_client.dart` only use `dart:io` exception types in `is`/`on`
  checks.

## 4. Bluetooth package licence

MeshSonar uses `flutter_reactive_ble` (BSD-3-Clause). It replaced `flutter_blue_plus` 2.x, whose FlutterBluePlus
License requires a paid commercial licence for any for-profit use. Keep the BLE code in `ble_transport.dart` behind
`RadioScanner` / `ByteTransport` so a package can be swapped again.

## 5. Rewriting without Flutter

A native (Swift/Kotlin), web (TypeScript) or other rewrite should keep these **contracts**, in priority order:

1. **Drive Format v1** byte-compatible output, exactly what `validate.ts` accepts: phone-made UUIDs, nulls for
   unmeasured values, `echoes: []` for heard nothing, ranges as in [DATA_MODEL.md](DATA_MODEL.md). Exports must be
   the same document.
2. **Save first:** persist each ping (flushed) when its listen window closes, before any upload.
3. **Sync rules** ([DATA_MODEL.md §5](DATA_MODEL.md#5-sync-rules)): ≤ 5,000 pings per request, mark synced only on a
   200, record rejections and never re-send them, discover unnamed rejections by re-sending, report `ended_at` once,
   serialise syncs, and treat 401/403 as fatal for a sync-all.
4. **Echo recognition** ([PROTOCOL.md §5](PROTOCOL.md#5-the-ping-and-its-echoes)): channel hash + MAC + timestamp +
   text, non-empty flood path, `repeater = path[0]`, hash-size-aware path decoding, fewest hops then best SNR.
5. **Ping text** `MS:` + a random 10-char tag. NEVER put a position (or anything about the driver) in it: the channel is public.
6. **Cadence** (time AND distance, first ping immediately, manual ping resets both, no overlap, 7 s listen window)
   and the **GPS filter** thresholds ([FEATURES.md](FEATURES.md#gps-filter)).
7. Optional but recommended: the **on-device layout** (folder per session, JSONL, ledgers), so drives can be copied
   between implementations, and the **settings** keys and ranges.

**Reuse these tests:**

| Asset | How |
|---|---|
| Crypto vectors (FIPS 180-4, RFC 4231, FIPS 197, `#test`/`#wardriving` secrets, channel hashes) | `test/radio/crypto_test.dart`. Copy the hex. |
| Companion frame vectors | `test/radio/protocol_test.dart`. Every encoder and decoder has byte arrays. |
| Over-the-air packets (Python-built) | `test/radio/packet_test.dart` `pktFlood` / `pktTransport`: decrypt, rebuild byte for byte, and the accept/reject list for `matchEcho`. |
| Cadence scenarios | `test/radio/wardrive_cadence_test.dart`: the scenarios are written as plain sentences; port them one to one. |
| GPS filter scenarios | `test/core/position_filter_test.dart` (parked jitter, pull-away, 90° turn, stoplight, poor fixes). |
| Store crash cases | `test/core/drive_store_test.dart` (truncated tail, garbage line, temp-file fallback, duplicate ids). |
| Sync scenarios | `test/core/sync_service_test.dart` (12,001 pings → 3 requests, lost 200, > 20 rejections, end-time reporting, 403 in sync-all). |
| **CMAT contract** | Run CMAT's real handlers with `bun run test/fixtures/cmat_server.ts <adminKey>`. It prints `PORT n` and serves `/api/cmh/*` + `/__test/state` from an in-memory store. Point your client at it and replay the four scenarios in `test/core/cmat_contract_test.dart`: request → approve (via `driver-admin` with `x-admin-key`) → upload → re-sync duplicates → end reported; 12,001 pings in 3 requests; validator rejections recorded and not re-sent; unknown key 401, revoked key → status revoked and upload 403. |
| End to end | `test/integration/end_to_end_test.dart`: simulator → link → engine → store → sync → real CMAT handlers; the server must hold exactly what the radio heard. |

**Porting the simulator first** (`lib/radio/simulator.dart`, ~500 lines) gives a new implementation a radio and a GPS
for CI and demos. It speaks real frames, so it doubles as a protocol conformance peer.
