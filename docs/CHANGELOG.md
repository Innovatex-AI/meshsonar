# Changelog

All notable changes to MeshSonar. Dates are local (US Eastern). This changelog was reconstructed from the commit
history (`.git/logs/HEAD`) and the source. Known gaps are tracked in [ROADMAP.md](ROADMAP.md).

## [0.7.2] — 2026-10-18 — see your driver key

`pubspec.yaml` is `0.7.2+10`. Bundle id unchanged.

- Settings > Driver key: tap the eye to show the full key (monospace, selectable), Copy, and it hides again by itself after 30 s.
  It also says which server the key works on. The key stays only on this phone; nothing new is sent anywhere.

## [0.7.1] — 2026-10-18 — privacy: pings no longer carry your position

`pubspec.yaml` is `0.7.1+9`. Bundle id unchanged. **Fixes a privacy leak.**

- The ping text on the public channel was MeshMapper's `@[MapperBot] <lat>, <lon> [power]`, so anyone reading the channel saw the
  driver's position to 5 decimals (about 1 m). It is now `@[MeshSonar] [power]` (power only when known). **No coordinates, ever**:
  `formatPingText` no longer takes a position, and tests assert nothing coordinate-like is on air.
- The site does not need coordinates on the air: your position is recorded on the phone and uploaded with the drive, and the site
  joins observer receptions to each ping by packet hash (Drive Format v1.1 `pkt_hash`, sent since 0.6.0).
- Pings from 0.7.0 and earlier still carry coordinates on the channel. Update every phone and iPad.

## [0.7.0] — 2026-10-18 — hex coverage on the map

`pubspec.yaml` is `0.7.0+8`. Bundle id unchanged. Builds on 0.6.0.

- **Hex coverage layer** on the drive map, the full-screen map and the drive-detail map: your tx pings rolled up onto the same H3
  hexagons the website draws (resolution 9, about 350 m). Green when the mesh heard something from inside the hexagon (shade by best
  SNR), red when it heard nothing. Toggle: Map layers > Hex coverage (on by default).
- The roll-up is by the parent of the resolution-11 cell, like the server, never a direct resolution-9 lookup (they differ for about 6%
  of points). Tests compare cell ids and outlines with h3-js 4.5.0 (`test/hex_cells_test.dart`; needs `brew install h3` to run).
- New dependency: `h3_flutter` (H3 core v4 linked into the app). If the library cannot load, the map just draws no hexagons.

## [0.6.0] — 2026-10-17 — packet hash for the observer join (Drive Format v1.1 ping fields)

`pubspec.yaml` is `0.6.0+7`. Bundle id unchanged. Builds on 0.5.0. Spec: meshsonar-infra
`docs/specs/m2-observer-ingest.md` §3 (source `upload`); build plan M1 "v1.1 fields".

### Added
- **Every ping now carries `pkt_hash`, `tx_epoch_s` and `tx_dbm`** (Drive Format v1.1, all optional, null when unknown):
  - `pkt_hash`: the MeshCore packet hash of the ping (SHA-256(0x05 ‖ GRP_TXT payload), first 8 bytes, 16 hex), the
    key the server uses to join a ping to every observer that heard it. Taken from a heard repeat of this exact send
    when there is one; otherwise rebuilt from the send command (timestamp, the companion's node name, the ping text,
    the channel key). The companion's channel-send reply has no hash, but its packet is deterministic.
  - `tx_epoch_s`: the second inside the packet (the timestamp MeshSonar put in the send command), not a guess from `ts`.
  - `tx_dbm`: the radio's TX power for that ping.
- The wire `format` id stays `meshsonar.drive.v1`: the live server accepts only that id and ignores unknown fields,
  so uploads keep working before and after the server learns the new fields. Older saved pings load with the fields null.

### Tests
- New `test/radio/packet_hash_test.dart`: golden vectors from real #wardriving pings in the Oct 17 observer capture
  (observer hash = hash of the heard `raw` = hash predicted from the send), route/path independence, TRACE path_len,
  MAX_TEXT_LEN cut, JSON round-trip. Two engine tests (hash and send second per ping, with and without echoes).
  The Drive Format shape mirror (`test/core/helpers.dart`) checks the v1.1 fields.
- `no_cmat_strings_test` (0.5.0 re-review): the `\u0043` cases are written escaped again and checked to decode to
  exactly `CMAT`; a joined literal run attaches to the literal where it started, not one nested in an interpolation
  (`'CM' '${'x'}AT'` is `CMxAT`, not flagged); a literal-only interpolation counts as its text.

## [0.5.0] — 2026-10-17 — new server address, MeshSonar name

`pubspec.yaml` is `0.5.0+6`. Bundle id unchanged (`com.meshsonar.app`). Drive Format v1 and the problem-report body are
unchanged (`app.name` is still `MeshSonar`). Spec: `docs/specs/app-0.5.0.md`.
**Precondition:** meshsonar.com must serve `/api/cmh/*` and `/me/devices` before install.

### Upgrading from 0.4.0
- Nothing to do. If the app was set to the old address (`https://cmh-meshcore.lovable.app`), it switches to
  `https://meshsonar.com` on first launch and **keeps your driver key** (same server, same database).

### Changed
- **Default server is `https://meshsonar.com`.** The old Lovable address is rewritten at launch, whatever its spelling.
- **Same server, different address keeps the key:** moving between the old Lovable address, `meshsonar.com` and
  `cmh.meshsonar.com` in Settings no longer asks to remove the key, as long as both are plain `https://host` addresses
  (default port, no `user@`, no sub-path). Any other server change still removes it (and asks first). The list lives
  in `lib/core/server_url.dart`. The launch rewrite, and any failure to save it, is written to the app log.
- **The website is called MeshSonar in the app:** the repeater source badge, "not on MeshSonar" report tags, the
  report's grid and repeater lines, the repeater sheet and the onboarding key page no longer say "CMAT".

### Tests
- New: `server_url_test`, `server_migration_test`, `no_cmat_strings_test` (strips comments, then fails on any
  whole-word `CMAT` left in `lib/**/*.dart` with escapes decoded and joined literals, Android resources, Info.plists
  or the pubspec description; allow-list for wire values, empty today). Updated the settings, ping-log, report and hosts tests.

## [0.4.0] — 2026-10-17 — report a problem, antenna per radio

`pubspec.yaml` is `0.4.0+5`. Drive Format v1 is unchanged: uploads and exports carry the same keys as 0.3.x (the
antenna is still `{type, gain_dbi, height_m}`, and the new build number is not in the `app` object). Spec:
`docs/specs/m1-app-0.4.0.md`. Released to rings 1 and 2 only.

### Upgrading from 0.3.x
- **The app id is now `com.meshsonar.app`** (was `net.innovatexit.meshsonar`) on iOS, Android and macOS. 0.4.0
  installs as a **new app** next to the old one and does not see its drives or settings. Before switching, open the old
  app and upload (Sync all) or export every drive that is only on the phone; then set up the driver key in the new app
  again (paste it from the website, or request one). The old app can be deleted once its drives are safe.

### Added
- **Report a problem** (Settings → About, and "Report a problem with this drive" in a drive's ⋮ menu). You pick a
  category, describe the problem, choose whether to include the app log and whether to attach a drive (its id only,
  never its pings), then review the **exact text** that will be sent, its size ("0.2 MB of 5 MB") and what was
  removed before the only Send button. Sent with your driver key (pending or approved) to
  `<server>/api/cmh/problem-report`. Without a usable key, "Open driver key settings" opens the key over the form,
  so nothing typed is lost.
- **Redaction on the phone** (`lib/core/redact.dart`): CMAT's §8 rules (driver keys, JWTs, bearer tokens, URL and
  observer passwords, secret fields; coordinates rounded to 3 decimals, about 110 m). The driver key and the full
  server address are also removed word for word from the log. Same output and counts as the server (shared
  vectors file).
- **5 MB cap:** the oldest log lines are dropped until the report fits ("Log shortened to fit 5 MB.").
- **One saved report:** a report that can't be sent stays on the phone (`report_draft.json`, with what you typed in
  the form) until you send it ("Send saved report", which shows the same review again) or discard it. Nothing is ever
  sent in the background. If the server can't accept a report as written (400), the review offers Edit report and
  Discard.
- **Diagnostic log** (`lib/core/diagnostics.dart`): the last 1,000 app events (messages, radio connect and
  disconnect, drive start and stop, uploads, repeater name and node map refreshes, caught errors), in memory only.
  Reports add a settings snapshot (server host only, key status, channel, cadence, upload settings, antenna).
- **Antenna per radio** (Q4.14): the first time a radio connects, "How is this radio's antenna set up?" asks for the
  mount (handheld, inside car, roof mag-mount, fixed mast), gain in dBi or "Don't know", and height in metres. Start
  drive waits until it's set ("Set up this radio's antenna", also on the full-screen map), the simulator included.
  Settings → Antenna lists each radio to edit or forget (not the radio in use while driving).
  Upgrading from 0.3.x prefills gain and height from the old setting and offers the matching mounts first.

### Changed
- The drive screen's Internal/External toggle is now the radio's antenna chip ("Roof mag-mount · 5.8 dBi · 1.8 m");
  tap it to change the antenna before a drive. While driving it is locked and shows what the drive records
  ("External · 5.8 dBi · 1.8 m"). On the wire, handheld and inside car upload as
  `internal`, roof mag-mount and fixed mast as `external`.
- Large text: section headers, slider rows, the connection chip and the simulator tag no longer overflow at 2.0×
  text on a 320 dp screen.
- MeshSonar sends drive data **only to the server in Settings**. There is no MeshMapper or other forwarding (there
  never was); a test records every request through a full drive, sync and report to prove it.

## [0.3.0] — 2026-10-16 — roadmap fixes

`pubspec.yaml` is `0.3.0+3`. The upload contract with CMAT is unchanged (same endpoints, headers and Drive Format v1
bodies); a rename only re-sends the existing session object.

### Fixed
- **Drives cut off by a crash or app kill** are closed at the next launch at their last ping's time (or start time
  with no pings), then uploaded quietly when *Upload at end of drive* is on and the key is approved, so the server
  learns their end. (`closeOrphanedSessions` in `lib/core/drive_store.dart`, run from `AppState.init`.)
- **Failed start no longer leaves an empty drive:** when `engine.start` fails and nothing was recorded, the session
  folder is deleted. A drive that already has pings is closed and kept.
- **Rejected pings** are counted separately (`SessionSummary.rejectedCount`). They no longer show as "N not synced"
  or enable Sync; badges show "· N rejected" instead (drive card and drive detail).
- **Changing the server URL** now removes the driver key and its status (keys are per server). Settings asks first
  and explains why; with no key saved there's no prompt.
- **Settings file parsing** is num-tolerant (`30.0` loads as 30), and a field with the wrong type falls back to its
  own default instead of resetting every setting. Ping/echo/radio integers (`hops`, `delay_ms`, `sf`, `cr`) are
  read the same way.
- **Heard list hold** changes apply to the running drive at once (live/stale rule and pips), not at the next Start.
- **Rename is saved in the drive and uploaded:** `DriveStore.renameSession` rewrites `session.json` and marks the
  drive for re-send (`resend.txt`), so the next sync sends the session with its new `label`, as an upload with no
  pings if everything else is already up. Exports carry the name. Badges say "Name not synced" until then. Names
  typed under 0.2.x (kept only in `ui_prefs.json`) are moved into their drives once.
- **App version** comes from the build via `package_info_plus` instead of the hard-coded `appVersion` (which still
  said 0.1.0). `pubspec.yaml` is now the only place it's set.

### Added
- Settings → Driver key: "Manage your drives and privacy at `<server>/me` — sign in with the same email you
  registered with", and a **Get a key on the website** button that opens `<server>/me/devices` (new dependency:
  `url_launcher`; `package_info_plus` is now a direct dependency).
- iOS signing: `ios/Flutter/Debug.xcconfig` and `Release.xcconfig` end with `#include? "Signing.xcconfig"`. Put your
  `DEVELOPMENT_TEAM` in the git-ignored `ios/Flutter/Signing.xcconfig` (template:
  `Signing.xcconfig.example`) so a personal team id never touches `project.pbxproj`. See DEVELOPMENT.md §2.1.

### Changed (contracts)
- `lib/core/api.dart`: `DriveStore.renameSession`; `SessionSummary.rejectedCount`, `sessionResendPending`,
  `hasSomethingToSync` (`unsyncedCount` now excludes rejected pings). `SyncLedger` gains `sessionResendToken` /
  `clearSessionResend`. `HeardTracker.holdPings` is now a setter that re-applies the rule. `AppServices` gains
  `openUrl`; its and `DefaultSyncService`'s default `AppInfo` no longer carry a version.

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
