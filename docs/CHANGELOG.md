# Changelog

All notable changes to MeshSonar. Dates are local (US Eastern). This changelog was reconstructed from the commit
history (`.git/logs/HEAD`) and the source. Known gaps are tracked in [ROADMAP.md](ROADMAP.md).

## [0.2.0] — 2026-10-16 — field-test fixes

Commits `dbff5c4` (05:53, shared groundwork) and `d86ebd3` (07:32, field-test fixes). `pubspec.yaml` is now
`0.2.0+2`. **Note:** the in-app version and the `app.version` sent to servers come from `appVersion` in
`lib/app/wiring.dart`, which still reads `0.1.0`.

### Added
- **Heard box** on the Drive map: who's in range right now. A repeater stays *live* for a configurable number of
  pings after it was last heard (**Heard list hold**, 1–10, default 3), dims while holding, then greys out into
  "+N earlier". It never disappears during a drive. It shows live distance to repeaters with a known position. Tap a
  row to frame the repeater on the map.
- **Full-screen live map** with the heard box, layer toggles (pings by SNR or heard/not, repeaters, links, range
  rings), two-finger rotate + compass, and Stop / Ping now in thumb reach. Works in portrait and landscape.
- **Map links and distances:** solid or dashed links from your position to every live heard repeater, with distance
  labels. Heard repeaters pop up and glow on the map.
- **Ping log** (Log button, and Ping log in drive detail): every ping, newest first, filters All / Heard / Heard
  nothing, plus a Repeaters tab. **Ping detail** sheet with every echo (SNR, RSSI, hops, delay, distance and bearing,
  path) and "Copy as text". **Repeater detail** sheet with key, position, times heard, best/last SNR and an SNR
  sparkline.
- **Repeater lookup with distances:** names and positions from CMAT's list first, then the public MeshCore node map
  (map.meshcore.io, streamed, repeaters within 150 km, cached for 7 days and refreshed on the first ping of a drive).
  Ambiguous short ids are never guessed.
- **Uploads during the drive:** optional periodic upload every 1–30 min (default 5) while driving, as well as at Stop.
  Settings shows the last upload result.
- **Antenna toggle** (Internal / External) on the Drive screen and in Settings, locked while driving and saved with
  each drive. The default is now **internal**.
- **Drive report** (after Stop, from drive detail and from the drive menu): distance, duration and speeds, grids
  mapped on CMAT's ~220 m grid (new grids vs earlier drives on this phone), heard %, SNR over the drive, hop mix,
  repeater leaderboard (NEW / not on CMAT), best and dead spots, and a shareable text summary.
- **Next-ping indicator:** countdown ring, "Move N m", or "Waiting for GPS".

### Changed
- **Auto-ping cadence:** an auto-ping now needs **both** the interval (10–120 s, default 30) **and** the minimum
  distance (15–500 m, default 100) since the last ping. Manual-only mode (interval 0) was removed from Settings; an old
  0 loads as 10 s. Ping now works any time and resets both rules. Changes apply mid-drive.
- New settings: Auto-ping 10–120 s, Minimum distance 15–500 m, Upload during the drive + Upload interval, Heard list
  hold, and Antenna type with internal as the default.

### Fixed
- **GPS drift while parked** no longer "moves" the car or triggers distance pings. Real GPS goes through a filter that
  drops poor fixes (> 50 m), smooths, and holds a parked position until movement is consistent.

## [0.1.0] — 2026-10-16 — MVP

Commits `6e8c90a` (01:38) to `87dc6d4` (05:08).

### Added
- **Scaffold and shared contracts** (`model.dart`, `api.dart`, `radio_api.dart`, `docs/CONTRACTS.md`).
- **MeshCore companion protocol** in pure Dart: BLE transport (flutter_blue_plus), companion link (app start, device
  query, clock, channel find/install with the hashtag key, channel send, RX log, stats noise floor, offline-queue
  drain), over-the-air packet parsing with 1–3 byte path hashes, and pure-Dart SHA-256/HMAC/AES for echo recognition.
- **Wardrive engine:** MeshMapper-compatible `@[MapperBot] lat, lon [power]` pings on `#wardriving`, a 7 s listen
  window, echoes recognised by channel hash + MAC + timestamp + text, best echo per repeater, and heard-nothing pings
  kept. Optional neighbour discovery is in the code (off).
- **Simulator:** a fake companion radio that speaks real frames and floods real encrypted packets, plus a GPS loop
  through Westerville, Ohio. Reported SNR saturates like a real LoRa radio.
- **Local-first storage:** one folder per drive, JSONL pings flushed per ping, crash-truncated lines repaired, atomic
  JSON documents.
- **Sync to CMAT** (or any MeshSonar Drive Format v1 server): driver key request/status, chunks of ≤ 5,000 pings, synced
  only after a 200, rejected pings recorded and never re-sent, end time reported once.
- **Export** of any drive as one Drive Format v1 JSON file through the share sheet.
- **App UI:** Drive screen with a live coverage map (OSM tiles) and Start/Stop + Ping now (one line at every phone
  width), Connect screen (BLE scan + Simulator), Drives list, drive detail (map framed to the drive, fit zoom capped
  at 15.5 so short drives don't show upscaled tiles), Settings with the driver-key flow, About, first-run intro, app
  icon and a design system (Barlow typeface, in-car colour palette).
- **Tests:** unit and widget tests, a contract test and an end-to-end test against CMAT's real handlers (bun), an
  opt-in live smoke test against a deployed server, and an on-device `integration_test` flow that prints `SCREEN`
  markers for screenshots.
