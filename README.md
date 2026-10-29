# MeshSonar

**Version 0.7.3** · Open-source MeshCore wardriving. MeshSonar pings a channel from your MeshCore companion radio,
listens for the repeaters that echo it, and records every ping with GPS — including the ones nobody heard. Drives are
saved on the device first, can be exported as files, and sync to [MeshSonar](https://meshsonar.com) or any server that
implements the [MeshSonar Drive Format v1](https://github.com/Innovatex-AI/meshcore-insights/blob/main/docs/MESHSONAR_DRIVE_FORMAT.md).

One Flutter codebase: iPhone, iPad, Android, macOS, Linux. A Windows runner is configured but untested.

## What it does
- **Connect** a MeshCore companion radio over Bluetooth, or use the built-in **Simulator** (no radio needed).
- **Drive:** auto-ping when both the interval (10–120 s) and the minimum distance (15–500 m) are met, or press Ping
  now. Each ping is listened to for 7 seconds. Every repeater that repeated it is recorded with SNR, RSSI, hop count
  and path. "Heard nothing" is recorded too.
- **See who's in range:** a heard box over the live map, a full-screen map, a ping log with per-echo detail, and
  repeater names and distances (from the MeshSonar site and the public MeshCore node map).
- **Not locked down:** the channel (default `#wardriving`; the ping text is `MS:` plus 10 random characters, with no location or other data on the air) and the server are settings.
- **Save first:** every ping is on disk the moment it's finished. Uploads run during the drive and/or at Stop, and are
  retry-safe (ping UUIDs; re-sends count as duplicates).
- **Drive report** after each drive: grids mapped, new grids and repeaters, signal over the drive, best and dead spots.
- **Export** any drive as a Drive Format v1 JSON file.
- **Hex coverage:** drive maps draw H3 resolution-9 hexagons (parent of the res-11 cell), matching the website.
- **Driver key:** create one on the website (`/me/devices`) and paste it in Settings. The eye button shows or copies it and hides it after 30 s.
- **Privacy:** pings never carry your position. Only `MS:<random tag>` goes over the air; the tag is stored and uploaded so the server can join repeater observations.

## Build and test
```sh
flutter pub get
flutter analyze
flutter test                       # unit, widget, contract and end-to-end tests
flutter build ios --release        # or: apk, macos, linux
```
The contract and end-to-end tests run the MeshSonar website's real endpoint code with [bun](https://bun.sh) when a
[meshcore-insights](https://github.com/Innovatex-AI/meshcore-insights) checkout is at `CMAT_DIR` (default
`/home/claude/meshcore-insights`); otherwise they skip. Details in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## For agents
Start with [AGENTS.md](AGENTS.md) (rules) and the platform handoff in [meshsonar-infra/docs/HANDOFF.md](https://github.com/Innovatex-AI/meshsonar-infra/blob/main/docs/HANDOFF.md).

## Documentation
| Document | What's in it |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers and dependency rules, a drive end to end, state, timers, the save-first rule, every file's role |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | MeshCore companion protocol as implemented: BLE, frames, channel crypto, ping text, echo recognition, test vectors |
| [docs/DATA_MODEL.md](docs/DATA_MODEL.md) | Every record field with units and ranges, on-device storage layout, crash recovery, export format, sync rules |
| [docs/FEATURES.md](docs/FEATURES.md) | Every screen and behaviour rule: cadence, GPS filter, heard box, uploads, report metrics, settings |
| [docs/PORTING.md](docs/PORTING.md) | Reusable code, platform seams, per-platform checklists (Android, web, desktop), non-Flutter rewrite guide, BLE licence |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Mac set-up, free Apple ID signing and install, running every kind of test, Linux/Xvfb checks, versions, release checklist |
| [docs/TESTING.md](docs/TESTING.md) | What each test file covers, how to run subsets, mutation-check results |
| [docs/REGIONS_AT_SCALE.md](docs/REGIONS_AT_SCALE.md) | The app with 559 regions: index payload and cadence, detection on borders and seams, the picker, radio presets without a fallback, measurements, asks for the server |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | v0.1.0 (MVP) and v0.2.0 (field-test fixes) |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Known gaps and next steps, prioritised |
| [docs/CONTRACTS.md](docs/CONTRACTS.md) | The original build contracts: shared types, class names, folder ownership |

## Layout
- `lib/core/` — data model, on-device store, server client (`CmatClient`), sync, settings, GPS filter, repeater lookup (pure Dart)
- `lib/radio/` — MeshCore companion protocol, packets, crypto, wardrive engine, simulator (pure Dart) and Bluetooth
- `lib/app/` — app state and wiring; `lib/ui/` — screens, map, report; `lib/platform/` — GPS and sharing
- `test/`, `integration_test/` — see docs/TESTING.md

## License
MIT — see [LICENSE](LICENSE). Ported and adapted code from the MeshCore firmware, MeshMapper web client and
MeshCore Open is credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

**Note:** the Bluetooth library, `flutter_blue_plus`, is not MIT. It's free for personal, nonprofit and educational
use; for-profit use requires a paid licence from its author. See THIRD_PARTY_NOTICES.md and
[docs/PORTING.md](docs/PORTING.md#4-flutter_blue_plus-licence).
