# Roadmap and known gaps

Gaps found while documenting v0.2.0, with file references. Priorities: **P1** affects data or field use, **P2**
affects correctness or polish, **P3** is housekeeping. Items fixed since are listed at the end.

## Field use

| P | Item | Detail |
|---|---|---|
| P1 | **Background operation on iOS** | `UIBackgroundModes` (location, bluetooth-central) and `allowBackgroundLocationUpdates` are set, but the app only requests when-in-use permission, and the Drive screen keeps the display awake instead. Nobody has verified that auto-pings, BLE and the 1 s cadence tick keep running with the phone locked or with navigation in front. Test on a device, then decide: request "Always", or rely on the blue location indicator, or keep the wake-lock-only behaviour. |
| P1 | **Android device testing** | Untested. Check runtime BLE permissions, **`POST_NOTIFICATIONS` (never requested; the foreground-service notification may be hidden on Android 13+)**, screen-off pinging through the geolocator foreground service, and the BLE scan on Android ≤ 11. See [PORTING.md](PORTING.md#android). |
| P1 | **Radio drop mid-drive** | The engine goes to `error` ("Radio disconnected") and stays there. The user has to Stop, reconnect and start a new drive. Add auto-reconnect and resume within the same session. |
| P2 | **BLE edge cases not exercised on hardware** | PIN pairing/bonding (`ble_pin` in DEVICE_INFO); a radio already connected to the MeshCore app; small MTUs (SELF_INFO is 58 B + name; DEVICE_INFO is 82 B); write-without-response backpressure; several radios in range; iOS `remoteId` changes; Windows (`flutter_blue_plus_winrt` 0.0.22). On Linux with no system D-Bus, a scan logged an **unhandled** `SocketException` from the BlueZ client instead of a stream error. |
| P2 | **Tile provider** | Maps use `tile.openstreetmap.org` directly. OSM's tile usage policy doesn't allow heavy app traffic. Before wider distribution, switch to a provider with an API key or self-hosted tiles, and consider offline tile caching for rural drives. |
| P2 | **Store distribution** | iOS needs a paid Apple Developer account (TestFlight/App Store); free signing expires after 7 days. Android needs a real release keystore (currently the debug key) and a Play listing. |
| P2 | **Desktop export** | `share_plus` can't share files on Linux (`UnimplementedError`), so Export and Share report fail there. Add "Save as…". |

## Data and sync

| P | Item | Detail |
|---|---|---|
| P2 | **Exports aren't chunked** | A drive with more than 5,000 pings exports as one file that a server rejects as a single upload. Document or split it. |
| P3 | **Neighbour discovery** | Implemented (`discoverNeighbors`) but there's no setting or wiring for it. CMAT counts "heard" from echoes only, while the app counts a neighbour too. Align the two before exposing it. |

## Protocol and compatibility

| P | Item | Detail |
|---|---|---|
| P2 | **Power suffix outside MeshMapper's set** | The ping text uses the radio's real TX power (22 dBm → `0.2w`). MeshMapper only offers `0.3w`/`0.6w`/`1.0w`/`2.0w`. Check whether community parsers care, and snap to the nearest label if they do. |
| P2 | **Channel setting forces `#`** | The UI always prefixes `#`, so `Public` or a private channel already on the radio can't be chosen, even though `ensureChannel` supports both. |
| P3 | **Serial/USB companions** | Only BLE (and the simulator). A USB-serial or TCP `ByteTransport` would need the serial framing. |
| P3 | **Report vs CMAT cell SNR** | The drive report's cell best SNR uses all echoes; CMAT uses direct echoes only (`hops` 1/null). The heard % and grid match. Consider matching SNR too. |
| P3 | **Simulator in the report** | In Simulator mode, with CMAT's list loaded, every simulated repeater is tagged "not on CMAT". |

## Code health

| P | Item | Detail |
|---|---|---|
| P2 | **About screen licence error** | `lib/ui/about_screen.dart` lists `flutter_blue_plus` as "BSD-3-Clause". It's under the FlutterBluePlus License (commercial use needs a licence). The list also omits the MeshCore firmware credit that `THIRD_PARTY_NOTICES.md` has. |
| P2 | **Test gaps from mutation checks** | Echo de-dup preferring fewer hops, and nulling out-of-range RSSI, have no failing test when broken. See [TESTING.md](TESTING.md#mutation-check-notes). |
| P3 | **Hard-coded paths in tests** | `/home/claude/meshcore-insights` (contract test, end-to-end test, fixture import) and `/root/.bun/bin/bun` (end-to-end test only; the contract test searches `$BUN`/`PATH`). Make both configurable with env vars. |
| P3 | **Duplicate helpers** | Three haversine implementations with two Earth radii (`core/heard.dart` and `ui/drive_stats.dart` use 6,371,008.8 m; `wardrive_engine.dart`, `position_filter.dart` and `simulator.dart` use 6,371,000 m); two `formatDistance` (`ui/drive_stats.dart` "850 m" vs `ui/map/map_layers.dart` rounds to 10 m); two `formatSnrShort` (with and without " dB"). `PingTile`/`ResultDot` in `widgets.dart` are unused. |
| P3 | **Stale comments** | README says "Windows builds too" (not verified). (`Settings.intervalSec`'s "0 = manual only" comment was fixed in 0.3.0.) |
| P3 | **Layering** | `ui/drive_stats.dart` and `ui/report/drive_report.dart` are pure Dart and belong in `core`. `drive_map_model.dart` imports the simulator for its repeater list. |
| P3 | **Distance is ping-to-ping** | Drive and report distances sum straight lines between pings, so they under-count on winding roads. Recording the filtered GPS track (without uploading it) would fix that. |

## Possible next steps (not started)

- **Web build** with an IndexedDB store, Web Bluetooth, and CORS on CMAT. Checklist in [PORTING.md](PORTING.md#web).
- Offline map tiles for the drive area (see Tile provider above).
- Import of a Drive Format v1 file (the inverse of Export), e.g. to move drives between phones.

## Fixed in 0.3.0

Each has a test; details in [CHANGELOG.md](CHANGELOG.md#030).

| Was | Item | Fix |
|---|---|---|
| P1 | **Orphaned drives after a crash** | `closeOrphanedSessions` runs in `AppState.init`: open drives get `ended_at` = last ping time (or start time) and are uploaded quietly when the key is approved. |
| P1 | **`app.version` said 0.1.0** | Read from the build with `package_info_plus`; `pubspec.yaml` is the only place the version lives. |
| P2 | **Rename wasn't synced or exported** | `DriveStore.renameSession` rewrites `session.json` and marks the drive for re-send; the UI uses it; 0.2.x phone-only names migrate once. |
| P2 | **Rejected pings looked unsynced forever** | `SessionSummary.rejectedCount`; badges show "N rejected"; Sync is enabled only for pings waiting or a new name. |
| P2 | **Server URL change kept the old key** | Settings asks first and explains; the key and its status are cleared. |
| P2 | **Empty drive left after a failed start** | A drive with no pings is deleted when `engine.start` fails. |
| P2 | **Heard hold change mid-drive** | The slider updates the live `HeardTracker` at once. |
| P3 | **`Settings.fromJson` used `as int?`** | Num-tolerant parsing (and per-field fallbacks) in `Settings` and the model. |
| P3 | **Signing set-up** | Untracked `ios/Flutter/Signing.xcconfig` via `#include?`; see [DEVELOPMENT.md §2.1](DEVELOPMENT.md#21-signing-keep-the-team-id-out-of-the-repo). |
