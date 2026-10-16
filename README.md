# MeshSonar

Open-source MeshCore wardriving. MeshSonar pings a channel from your MeshCore companion radio, listens for the
repeaters that echo it, and records every ping with GPS — including the ones nobody heard. Drives are saved on the
device first, can be exported as files, and sync to [CMAT](https://cmh-meshcore.lovable.app) or any server that
implements the [MeshSonar Drive Format v1](https://github.com/Innovatex-AI/meshcore-insights/blob/main/docs/MESHSONAR_DRIVE_FORMAT.md).

One Flutter codebase: iPhone, iPad, Android, macOS, Linux (Windows builds too).

## What it does
- **Connect** a MeshCore companion radio over Bluetooth, or use the built-in **Simulator** (no radio needed).
- **Drive:** auto-ping on a timer and distance rule, or Ping now. Each ping is listened to for a few seconds; every
  repeater that repeated it is recorded with SNR, RSSI, hop count and path. "Heard nothing" is recorded too.
- **Not locked down:** the channel (default `#wardriving`, same ping format as MeshMapper) and the server are settings.
- **Save first:** every ping is on disk the moment it's finished. Sync is retry-safe (ping UUIDs; re-sends are duplicates).
- **Export** any drive as a Drive Format v1 JSON file.
- **Driver keys:** request one in Settings; the server admin approves it. Only the last 4 characters are ever shown.

## Build and test
```sh
flutter pub get
flutter test                       # unit, widget, contract and end-to-end tests
flutter build linux                # or: ios, macos, apk
```
The contract and end-to-end tests run CMAT's real endpoint code with [bun](https://bun.sh) when a CMAT checkout is at
`/home/claude/meshcore-insights`; otherwise they skip.

## Layout
- `lib/core/` — data model, on-device store, CMAT client, sync, settings (pure Dart)
- `lib/radio/` — MeshCore companion protocol, packets, wardrive engine, Bluetooth, simulator
- `lib/app/`, `lib/ui/`, `lib/platform/` — app state, screens, GPS and sharing
- `docs/CONTRACTS.md` — how the pieces fit

## License
MIT — see [LICENSE](LICENSE). Ported and adapted code from the MeshCore firmware, MeshMapper web client and
MeshCore Open is credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

**Note:** the Bluetooth library, `flutter_blue_plus`, is not MIT. It's free for personal, nonprofit and educational
use; for-profit use requires a paid licence from its author. See THIRD_PARTY_NOTICES.md.
