# Changelog

All notable changes to MeshSonar. Dates are local (US Eastern). This changelog was reconstructed from the commit
history (`.git/logs/HEAD`) and the source. Known gaps are tracked in [ROADMAP.md](ROADMAP.md).

## [Unreleased]

## [0.24.0] — 2026-11-01 — claim your radios; no approval anywhere

- **No approval wording**: the server no longer holds new keys or drives back (website 0096), so the app says "Not confirmed yet" for an old server's pending key and "once your key is ready" instead of "once the server accepts". The SNR trend says "observers placed in this region", not "trusted observers".

- **Claims follow the server's final contract.** A `409 {owner: "you"}` from `claim-start` means "already yours": the app shows the
  existing claim, touches nothing on the repeater and asks for no password (the claim screen also says so up front for a
  repeater you own). My radios keeps ended claims (last 90 days) in a collapsed "Past radios" list with the reason
  ("Another owner proved control", "You released it", "Removed by a moderator"). Error `code`s (`no_such_challenge`,
  `not_owner`, `no_such_claim`) get plain messages. A contract test asserts no claim request carries a password-like field.

- **Claim a radio or a repeater (needs a server with `capabilities.nodeClaims`).** Settings > My radios lists the radios your
  driver key manages and lets you rename one, choose whether its position is public, add notes, or give it up; the website
  (`/me/radios`) has the full multi-radio view. **A claim only manages a radio: it never decides whether its data is
  recorded, uploaded or counted.**
  - **Claim my radio**: the connected companion signs a server message with its own Ed25519 key (CMD_SIGN_START/DATA/FINISH).
    No password, nothing over the air.
  - **Claim a repeater**: pick it (map panel or repeater sheet "Claim this repeater", your repeaters, or paste its key), enter
    its admin password (kept in memory only, never sent to MeshSonar, 15 characters at most as the firmware reads), and your
    radio logs in over the mesh, reads the name, adds a short code (`MSxxxx`) to it, sends an advert so an observer hears the
    code, then ALWAYS puts the name back and reads it back to confirm. Handles: guest login (not admin), no answer (out of
    range or wrong password), cancel, app backgrounded, radio dropped (restored when it reconnects), restore not confirmed
    (the exact commands to type are shown, and a reminder stays in My radios until done). "Owned by you" shows on claimed
    repeaters. Room servers are not claimable yet.
  - Radio layer: login, logout, status, remote CLI, contacts, signing and export-contact frames, verified against the
    MeshCore firmware source (docs/PROTOCOL.md 2.5); a wrong repeater password gets no reply at all, so the app says "out of
    range or wrong password".
- **Fullscreen map**: the Heard box's maximum height can no longer go negative (soft keyboard over a short window threw "non-normalized height constraints" and left a blank sheet).

## [0.23.3] — 2026-11-01 — repeater lines at the finest cell size

- **Repeater -> cells lines use the server's finest cells** (H3 resolution 11, `capabilities.reachH3`, `repeater-reach?res=11`) instead of the old 270 m x 200 m squares, then roll up to the hexagons drawn at the current zoom. Older servers keep the square shape. Cached answers are kept apart by shape.
- **Thin cells are fainter**: a cell with 1 or 2 pings is drawn at half strength, so one lucky ping is not painted like a measured area.

## [0.23.2] — 2026-10-31 — taps that work, and a map that tells the truth

- **Repeater taps work everywhere.** The amber repeater markers of your own drive only toggled a label (no panel, no lines); they now open the info panel and draw the lines to every cell the repeater was heard in. A tap on a repeater drawn on top of a coverage cell no longer risks opening the cell underneath. (The panel's repeater taps in the network layer already worked.)
- **Ping dots are tappable** (they were ignoring touches, so the dots "showed nothing"): tap a dot for lines to the repeaters that heard it with their SNR, and its full details in the collapsed panel. A ping that heard nothing says "mapped, no signal".
- **Colours follow one rule.** Green and the other strength colours mean measured coverage. A ping or cell that was mapped but heard nothing is GREY (it was red). A ping or cell that was heard but has no signal reading is its own purple "heard, signal unknown" (it was teal, which read as good). Share-heard colouring no longer paints 0% heard in the red "weak" step. Legends say so, and the report's "red ticks" are "grey ticks".

## [0.23.1] — 2026-10-31 — link lines you can see, and an info panel that leaves the map alone

- **Link lines are orange** (one colour, dark casing) so they stand out from the SNR-coloured cells; the SNR stays in each label and in the panel.
- **Tapping a cell or a repeater opens a collapsed info panel** (one line: what you tapped and what the lines found; tap to expand) instead of a modal sheet that covered the map. It holds Fit all links and Close; a tap on empty map closes it.
- **Repeater info with the calculated figures** (from `repeater-reach` totals): cells heard in, pings heard, drives and drivers, best and median SNR, farthest heard, last heard, above the existing repeater details. A repeater no MeshSonar drive has heard says so ("No MeshSonar drive has heard it yet") instead of drawing nothing silently. The cell panel lists the repeaters heard there with pings and SNR.

## [0.23.0] — 2026-10-31 — map link lines

- **Map link lines (like MeshMapper).** Tap a repeater: a line runs to every coverage cell it was heard in. Tap a coverage
  cell: a line runs to every repeater heard there. Lines are coloured by best SNR (the map's own scale), the 24 with most
  pings carry an SNR label ("+6.5 dB"), at most 250 are drawn, and a chip under the map says "Alpha heard in 14 cells" /
  "12 repeaters heard here (+2 not on the map)" with Fit (frame all links) and Clear; a tap on empty map clears too.
  A repeater's cells come from `repeater-reach` (`reachDriverKey`), re-bucketed onto the hexagons drawn at the current
  zoom (pings add up, best SNR kept) and redone when the zoom crosses a band. A cell's repeaters come from the new
  `GET cell-links?h3=` (`capabilities.cellLinks`, approved key; meshcore-insights migration and handler). Only public
  drives, trimmed, as in repeater-reach. Failures say so in the chip; no key or no capability = no lines. Website
  counterpart: the same lines on the coverage and mesh maps (meshcore-insights). Code: `lib/core/map_links.dart`,
  `lib/ui/map/layers/link_lines_layer.dart`; tests `test/core/map_links_test.dart`, `test/ui/map/link_lines_test.dart`.

## [0.22.0] — 2026-10-31 — first field-test fixes

- Layers sheet: the MeshCore Map credit and its age are one line ("Data: MeshCore Map (map.meshcore.io), as of ..."), not two.

- **Weather and drive-data logging fixes (test drive: "weather not being logged").** Root causes: (1) a drive that
  went up as plain v1 (site-config not answered in time, or Weather switched on after the upload) never told the server
  `enrich.weather=true`, and nothing sent it later, so the server never looked the drive up; (2) the drive report hid
  the whole Weather block (silence) when the viewed region's site-config had not loaded, the key was not approved, the
  switch was off or the drive had not uploaded; (3) the "pending" text promised 30 minutes while the server also waits
  2 hours after the last upload (real delay 2 to 3 hours); (4) the launch catch-up was marked done for the run even when
  it failed offline. Fixed: the weather choice is part of the session fingerprint, so a drive the server holds with the
  other choice gets one small ping-less v1.2 upload (also when Weather is switched on or off, and on the next launch);
  drives older than 60 days are left alone. The report block always shows (switch off, no approved key, server does no
  weather, not uploaded yet with the real delay, pending, unavailable with the privacy-trim reason) and "no context
  recorded" names the categories that are off.
- **Map: repeater names, and the grid now follows the zoom** (Andy's test drive: "I have to click a repeater to see the
  name; the grid did not match the zoom"). Branch `fix/map-labels-grid`.
  - **Repeater name labels** on the Drive map, the full-screen map and the drive report map, beside every repeater the map
    draws (known/heard diamonds, region roster dots, global network dots). One painter (`ui/map/layers/repeater_name_labels.dart`)
    so labels never overlap each other, a marker, a cluster bubble, the link/ring captions, the heard box, the button
    column or the credit stack; right of the marker, else left, above, below, else dropped. Zoom-dependent: nothing below zoom
    9, heard-this-drive repeaters from 9, everyone else from 11, with a per-zoom budget (8, 14, 24, 36, 60 labels); heard
    first, then nearest to you (or the map centre). Halo in the surface colour for light and dark, Dynamic Type up to 1.6x,
    ellipsis at 150 px. Markers now speak their name to VoiceOver ("Repeater Westerville Water Tower").
  - **New layer "Repeater names"** in the layers sheet (Network section), default on, **saved** (`Settings.mapRepeaterLabels`,
    JSON `map_repeater_labels`, written only when off). Showing repeaters at all was already switchable (Repeaters, Region
    repeaters, All MeshCore repeaters).
  - **Grid vs zoom.** The drive's own hexagons were always H3 res 9 while the network layer used the zoom table, so at street
    zoom the drive's cells were about 5x bigger than the network's. Both now use one table (`kCoverageResBands`,
    `coverageResForZoom`): res 7 below zoom 11.5, 8 to 12.5, 9 to 14, 10 to 15.5, 11 above. The drive hexagons re-roll
    (`cellToParent(geoToCell(res 11))`, never a direct lookup) the moment a pinch crosses a band; the map also reports its opening
    zoom so the network fetch starts at the right resolution; the fetch debounce is 250 ms (was 500). A resolution pinned in
    Coverage options pins both layers. Tests: `test/core/coverage_res_table_test.dart`, `test/ui/map/hex_zoom_test.dart`.
  - **Other map fixes found in a simulated drive on iPhone 17 Pro and iPad Pro 11-inch:** the result flash and the report card
    covered the SIMULATED tag and the repeater-age legend (they now sit above the credit stack,
    `DriveMapModel.attributionStackHeight`); ring and link-distance captions and heard-repeater tags piled onto the cluster
    bubbles when zoomed out to a region (now drawn from zoom 10); labels were hidden under the heard box in full screen.

- **First-time-user and field-use UX pass (non-map screens).** Stop drive asks "Stop this drive?" first (Keep driving is the default). The
  connection chip says "Reconnecting…" instead of "Not connected" while a dropped radio reconnects. Log button and report-card dismiss
  are 48 px tall; the onboarding Skip is 48 px; every stat tile reads to VoiceOver as one thing ("Pings: 3"); the onboarding page dots and
  illustrations have proper semantics. Bluetooth permission refused: an **Open Settings** button next to the message. Radio signal in
  plain words ("Good signal") instead of dBm. Onboarding now says the phone will ask for Bluetooth and Location. Every user-visible string
  that contradicted the automatic key ("Pending approval", "Request a key", "An admin needs to approve", "approved key", "server admin")
  is reworded (key badge: Waiting for the server / Ready to upload / Turned down / Switched off); `test/ui/copy_consistency_test.dart`
  keeps them out. "Connect a radio (or the simulator) first." no longer appears in release builds. About no longer points at a file that
  is not in the app. The drive report card subtitle no longer truncates; the report map credit no longer says "flutter_map |".
  Largest Dynamic Type: the Drive tab used to overflow by 78 px with Start drive off screen (at 2.3x and up); it now scrolls
  the status, stats and chips under a fixed-height map and pins Start/Stop and Ping now at the bottom (test at 2x and 3.1x),
  the map overlays and the connection chip stop growing past 1.3x / 1.5x, stat labels shrink to fit, and a section label with an
  action ("Nearby radios" + "Scan again") stacks instead of breaking one letter per line.
  `integration_test/screens.dart` now also walks onboarding, the disclosure sheet, Connect (scan and Bluetooth-off), the antenna sheet, a
  live simulated drive, the Stop confirmation, the drive report, Drives, Radio and Region.

- **The Simulator is out of release builds.** `simulatorAvailable` (`lib/app/build_flags.dart`) is `kDebugMode ||
  --dart-define=MESHSONAR_SIMULATOR=true`: the Connect screen entry, the onboarding button and the simulator's code are
  gone from the App Store / TestFlight app (checked by `scripts/verify_release_no_sim.sh`). Debug builds and tests keep
  it. Onboarding and the Drive hint no longer mention it. App Review notes now rely on a demo video (docs/APP_STORE.md).

## [0.21.0] — 2026-10-30 — production readiness (TestFlight candidate)

- **Bluetooth now runs on `flutter_reactive_ble` (BSD-3-Clause)**, replacing `flutter_blue_plus`, whose licence needs a
  paid commercial licence for for-profit use. Same behaviour behind `RadioScanner` / `ByteTransport`: scan filtered on
  the MeshCore UART service, MTU 185 on Android, TX notifications, write without response when allowed. Bluetooth off,
  unauthorised or unsupported is reported before scanning or connecting. **Not yet exercised against a real radio.**

- **One-tap onboarding: the driver key creates itself.** A phone with no key asks the server for one at launch, on
  returning to the app, and when the server changes (`AppState.ensureKey`): no form, no approval wait on a server
  with open registration (production). The registration name is the generic "MeshSonar driver" (the public handle is
  "Driver N" until a callsign is set). Failures (offline, 429) are quiet and retried with a growing pause. Removing
  the key turns `Settings.autoKey` off so it never comes back unasked; Settings > Driver key then offers **Create my
  key** (name, callsign and email optional), which turns it back on. Onboarding page 3 now says nothing needs signing
  up. New setting key `auto_key` (default true). Tests: `test/app/auto_key_test.dart`.

App Store readiness audit (PR `fix/app-store-readiness`; details and App Store Connect answers in [APP_STORE.md](APP_STORE.md)).

- Privacy policy: linked in the app (Settings > Privacy & data sharing, About, and the driver-key request form) to `https://meshsonar.com/privacy`.
- Account and data deletion (guideline 5.1.1(v)): "Delete my collected data" is now "Delete my data and account": it adds Delete my account (opens the website page that deletes the account, drives and keys), Delete all drives on this phone, and Remove the driver key from this phone.
- Simulator drives are never uploaded and the Simulator's packets are never shared (a drive recorded with the simulated radio is made-up data and used to go to the community map when a key was present). The Simulator rows say so.
- Background location is for recording a drive only: the idle region watcher no longer keeps a low-power background stream with "Always" granted (it runs in the foreground only). The "Always" and "While Using" permission strings and the in-app explainer now describe exactly that.
- Info.plist: `ITSAppUsesNonExemptEncryption` = false, `UIRequiredDeviceCapabilities` (arm64, bluetooth-le, location-services), removed the unused `NSBluetoothPeripheralUsageDescription`.
- Tests: `test/ui/app_store_readiness_test.dart` (policy links, deletion screen, large text on iPad windows, plist and icon invariants), Simulator upload guard, idle watcher.

- Stream 7 finish: stats-parser edge-case tests (truncation, trailing bytes, extremes), PROTOCOL.md verification table marking which radio frame layouts are still unverified against real hardware, privacy manifest / App Store mapping documented in FEATURES.md. The drive hook, disclosure v2, per-category switches, phone sensors and v1.2 context upload were already on this branch.
Field-robustness pass (branch `fix/field-robustness`): the drive path audited end to end before real-device tests and App Review.

- **Radio drop mid-drive now reconnects and resumes in the same drive** (ROADMAP P1, was "stays in error"). `AppState` reconnects to the same radio with growing waits, `WardriveEngine.resumeOnLink` rejoins the channel on the new link and keeps the cadence; the radio-health sampler follows the new link. Plain reasons while it tries ("Bluetooth is off...", "radio isn't answering"). Stop ends the loop. The engine also notices a dead link between pings and in listen-only mode.
- **Exports are chunked** (ROADMAP P2, was "document or split"): a drive over 5,000 pings exports as `-partNofM.json` files that are each a valid upload body, shared in one sheet (`ChunkedExport`, `services.shareFiles`). A drive that fits is byte-identical to before.
- **Sync status codes**: 429 stops the run and pauses automatic uploads for `Retry-After` (default 60 s); 5xx, 408 and no network stop the run after the first failure (it used to wait out a 120 s timeout per queued drive); 413 halves the request until accepted; every one keeps all pings. New plain-language texts for 429, 413, 5xx.
- **Offline queue**: finished drives that never uploaded are retried at launch and on every resume (quietly, at most every 2 minutes, never while driving).
- **GPS gone mid-drive**: after 20 s the status says to check Location and permission; a remembered GPS fix older than 30 s is never used for a ping.
- **Phone clock off from GPS time** by more than 5 minutes (steady over three fixes): one warning per drive.
- **Drive list speed**: `JsonlDriveStore.sessions()` reuses a drive's summary while its files are unchanged (a 6,000-ping drive was fully re-parsed on every refresh, including each in-drive upload tick).
- Simulator pass (iPhone 17 Pro, iPad Pro 11-inch): the Drive map's "No pings yet" hint no longer sits under the region chip on a phone; the About licence text is unwrapped from its 75-column hard breaks.
- Tests added for each (`radio_reconnect_test`, `sync_status_codes_test`, `offline_queue_test`, `long_drive_test`, `wardrive_resilience_test`, long-drive cases in `drive_store_test`), including the two mutation-check gaps in TESTING.md (echo de-dup prefers fewer hops; out-of-range SNR/RSSI become null).

## [0.20.1] — 2026-10-28 — 559 regions

The platform went from about 5 to 559 active regions. Design, measurements and the asks for the server: [REGIONS_AT_SCALE.md](REGIONS_AT_SCALE.md). Not installed anywhere (the app is on hold).

- Region index: parsed on a background isolate, written to the cache only when it changed (a 304 no longer rewrites the 3.4 MB file or re-encodes it), re-asked after 6 h in the foreground (not while a 429 or a failure is backing off, `Retry-After` honoured), the same list object kept when the answer is the same. Launch no longer parses (40 ms) and re-encodes (150 ms) the 3.4 MB index on the main isolate (laptop figures; a phone is slower).
- Region detection: typed-array point-in-polygon (holes, MultiPolygon), a position held by several regions names the most specific (smallest real area) and reports the others ("you are also here (shared border)", "also CODE"); a seam between two thinned outlines (300 m) resolves to the nearest outline instead of "outside coverage"; near an edge the exact outline is fetched once (`regions-index?slug=`); "outside every region" picks the nearest by true edge distance (the old box-only pick was wrong for L-shaped zones).
- Region picker: lazily built list with search (accent-insensitive; name, code, slug, country), "Near you", countries as headings; nearest first now ranks by centre distance inside a big box; short lists unchanged.
- All regions screen: figures are read only for rows on screen, three at a time, politely (it used to fire 559 reads at once); a 429 pauses the reads and says so; countries as headings; the comparison table is a collapsed card at the top covering the regions read so far (at most 25) and says so.
- Server asks answered (meshcore-insights PR `api/app-559-asks`, migration 0087; the app reads each field when present and falls back when absent): `regions-index` rows carry `country`, `country_code` and `machine_derived` (the app no longer reads the country off the end of a region name when the server says; the name-suffix reading is the fallback for an older server); the All regions screen uses ONE `regions-figures` read for every region (per-region reads only when the server lacks it; a 429 waits and asks the same single question again); a region whose outline the server drew by machine shows a quiet "Machine-derived outline" note on the Region tab. `radioPresetNone` / `preset_none` and `timezone` were already read and are now sent.
- Radio preset: a region with no preset says so, shows the server's stored reason and evidence when sent (`radioPresetNone` / `preset_none`, forward compatible) and otherwise "The server has not said why"; never the US preset or another region's; provenance (published / community-observed, note) shown from the region catalogue (`/v1/regions`); the previous region's site-config is never shown after a switch; entering a region with no preset says so in the notice. Time zone shown when the server sends it.
- Brand-new region (no observers, no drives, no preset) checked against the real UKK answers: every panel says what is missing.
- The viewed region and the switcher order are computed once per index / fix, not on every notification. `CmatException.retryAfterSec`, `RegionStatsException.status`.
- Tests: new tests over a 559-region stand-in (`test/support/regions_559.dart`): geometry (agrees with the old ray cast on 20,000 points), border slivers, nested zones, seams, switcher order, search and accents, index service (fingerprint, back-off, refine, off-isolate parse, big file round trip, 304 on a 3.4 MB body), the picker sheet and All regions screen at 559 (built rows, reads in flight, 429 pause), preset states, crossing into a no-preset region, the foreground cadence, the empty new region.
- Gate: `flutter analyze` clean; `flutter test` 1,611 pass / 37 skip / 0 fail (baseline 1,534 / 37 / 0). Under heavy machine load `drive_report_v2_test`, `wardrive_cadence_test`, `wardrive_engine_test` and `offline_basemap_test` can time out; they pass alone.
- Tooling: `tool/bench_regions.dart`, `tool/bench_regions_new.dart` (AOT benchmarks over a real `regions-index` body); `scripts/verify_sim.sh` flow gains a region picker screenshot step and no longer exits silently when no simulator matches (it prints which one is missing; this Mac has no iOS simulator runtime installed, so the flow was not run).

## [0.20.0] — 2026-10-25 — Driver insights, RF windows, weather in reports

- Your progress shows your whole account's history from the server (`driver-summary`, capability `driverSummary`): totals, weekly charts (UTC Monday weeks), recent server drives and a comparison with this phone, with a stored offline copy and explicit error states. The Chart/Table switch moves under the title at large text sizes.
- Repeater detail (Region tab and drive repeater sheet): "Where MeshSonar drives heard this repeater" from `repeater-reach` with the driver key (`reachDriverKey`): tiles, map of reach cells, signal-by-distance chart, every state explicit, 10-minute on-disk cache with offline copy.
- RF tab: time window selector (24 hours, 7 days, 30 days, 90 days) when the server offers `rfWindow`; daily points for 30 and 90 days; per-window offline copies. `RegionFetch.fail` carries the HTTP status.
- Repeater detail: 30-day signal trend from `snrDaily` (daily mean direct SNR from our observers, honest gaps, trend sentence from 7 days of data).
- Drive report text, CSV (`weather` table) and PDF now include the server's hourly weather when it is ready (model values, Open-Meteo credit); nothing when it is not.
- Fix: the weather answer is kept 1 hour (was 6) and is dropped when the server's weather is erased or the Weather switch is turned off.
- Drive context is uploaded (Drive Format v1.2) to a server that lists `meshsonar.drive.v1.2` in its site-config: device and radio details, the weather flag, per-ping altitude/course/pressure/battery and the radio-health and phone samples (never a coordinate, never the local-only BLE signal). Any other server gets exactly the plain drive, byte for byte. A drive is never lost to its context: a v1.2 upload refused as a whole is sent again as the plain drive, a ping whose context is refused is stored without it, and refusals are counted in the upload line. Context recorded after its ping was uploaded, and the context of drives uploaded before the server accepted it, is delivered by itself (`POST drive-context`); retries never double count.
- Opt-out is real: a category switched off is never uploaded, its context is removed from every drive the server does not have it for (so turning it back on does not send it), and, with a key, a dialog offers to erase what the server already holds (Erase highlighted); a server that cannot erase says so. Weather off tells the server to stop and delete.
- Settings > Privacy & data sharing: each category says where its data goes with the connected server ("Uploaded with your drive." / "Saved on this phone only: this server does not accept it yet."); Weather for my drives is live when the server looks it up (about 5 km, Open-Meteo.com, CC BY 4.0).
- New: Delete my collected data (Settings > Privacy & data sharing): deletes all drive context and the shared packet headers on the server with the server's counts, handles the hourly limit, unknown key, no key, no connection and older servers in words; separately (never the default) deletes the context saved on this phone.
- Drive report: Weather block for uploaded drives (stream 7 WP6). Shows the server's Open-Meteo weather for the places and hours of the drive: tiles, charts with a Chart / Table switch (temperature and dew point, wind, air pressure), all hourly values, and the weather model's station pressure compared with the phone barometer (labelled as model value for about a 5 km cell vs cabin pressure). Every state is explicit (not looked up yet, partly looked up, off for this drive, nothing to look up, offline with the stored copy, 404, 429, errors with Retry); an old server or the category switched off hides the block. Answers are cached on disk per drive (`ready` 6 h, others re-asked after 5 min, at most 50 asks a minute). "Weather data by Open-Meteo.com (CC BY 4.0)" (link to open-meteo.com) sits under the values, in About and in THIRD_PARTY_NOTICES.md. New `Units.precipitation` (mm / in), `speedValue`, `pressureDelta`.
- Repeater list refresh by delta: when the server offers `networkRepeatersDelta`, the 55k-row "All MeshCore repeaters" list is kept fresh by asking only for what changed since the stored cursor (`network-repeaters?updated_since=`; live check Oct 25 2026: 332 KB decoded / 187 KB on the wire against 6.5 MB / 3.6 MB for the full list). Removed keys are deleted first, then changed rows replace or add by key, the cursor moves to the answer's `asOfS`, and the list is saved atomically (the repeat of the server's last two minutes is harmless). Any 410, refusal, inconsistent body (counts that do not match, half the list vanishing), stored list over 13 days behind, last full download over 30 days ago, missing capability or missing stored list falls back to the full list (with ETag) once, with one line in Diagnostics and nothing shown to you. The 6 h gate, the 10 s pull-to-refresh floor and the failure back-off are unchanged; a failing delta (offline, 5xx, 429) keeps the stored list and never turns into a full download.
- The launch repeater sync waits (up to 4 s) for the site config so the delta capability is known; without it the full list is used as before.
- Tests: delta apply, cursor math, fallbacks, persistence, bytes saved, AppState wiring with the capability on/off and region switch, global layer scope edge (39 km in / 41 km out), and a live contract test (`MESHSONAR_LIVE_CONTRACT=1 flutter test test/core/network_delta_live_contract_test.dart`).

- Offline maps verified against the real hosted CMH pack (tiles.meshsonar.com): header, directories and tiles checked byte for byte against an independent reader; real tiles rendered in both palettes.
- Fixed: the PMTiles reader failed every concurrent tile request ("async operation is currently pending"), so a downloaded pack would have drawn mostly blank on the map. Reads are now queued on the file handle.
- Offline map style now matches the online map: OSM Carto colours and road hierarchy through the same grey/paper (light) and chart (dark) colour matrix as the online tiles. Labels: place names by size, road names along roads, motorway refs, river and lake names, with wide halos for reading in the car. No glyph files needed in the app.
- The map now switches region pack as the view moves (sticky where packs overlap) and back to online tiles outside every pack, instead of choosing once from the starting centre.
- Offline maps screen: "Download on Wi-Fi only" (default on; on cellular it shows the size and asks), downloads queue and resume by themselves on Wi-Fi, on return to the app and after a restart; "Update available (size)" with the old pack kept in use until the new one is verified; pack list cached with ETag so the screen works offline ("Offline - pack list as of"); per-pack size, total and Delete all; stalled downloads fail after 30 s instead of spinning; a partial download from another version is discarded instead of appended to; honest full-disk message.
- Fixed: dark mode showed light offline map tiles (both palettes shared one tile-cache key); the style now has its own id and version per palette, so style changes also invalidate cached tiles.
- Fixed: the Reports tab asked `/api/<slug>/region-report`, which is 404 for every region but CMH; it now uses `/api/cmh/` on the region's host like the other region data, so DAY and CVG reports load and are cached.
- Fixed: Offline maps storage accounting could crash while a download finished (flaky screen test).
- Region tab offline-first: saved data shown with "Offline - as of", honest "No connection" states with a working Retry on every panel, and a clear "Live needs a connection" on the Live tab. Busiest-hours data is now saved for offline use.
- Units: besides Auto / Metric / Imperial, distance, speed, height and altitude, temperature (°C/°F) and air pressure (hPa/inHg/mmHg) can each have their own unit; each follows Units by default. Old settings files load unchanged.
- Settings on phones: app bar Search and Sections (jump to any section); every unavailable control now says why and how to enable it; removing the driver key says how to undo it.
- A last-known position older than 72 hours (was 24 h) is labelled and can still centre the map, but no longer switches the region or shows a region notice or preset prompt.
- Map layers sheet rebuilt from the layer registry: sections This drive / Coverage / Network / Around you, and every server-fed layer says where it stands (count and source, loading, "Couldn't load" with Retry, "Offline - as of …", or the switch disabled with the reason, e.g. "Not available on this server yet").
- New map layer "All MeshCore repeaters", on by default: every repeater with a public position from the server's network list (live: 55.6k), coloured by last advert (24 h / 7 d / 30 d / older), with a legend and the MeshCore Map credit. In your region it shows that region plus 40 km around it; with no region known it shows the whole world as count bubbles that split as you zoom in. Bubble counts are large, high-contrast and read by screen readers. Shows "Not available on this server yet" (switch off and disabled) on a server without the list.
- Region repeaters on the map are now clustered and come from the synced roster (offline too); tap one for its sheet with "Open repeater page" (was a name tooltip).
- New map layer "Observers": the region's observers that share their position; tap for online state, noise floor, packets per hour and more.
- Tap a cluster to zoom into it; tap a repeater or observer for its detail sheet.
- Fix: the network repeater list never loaded in the app (its background decode failed with "object is unsendable"); it is now decoded off the main isolate as intended.

- The Drive map and the Region tab open on the phone at once (last-known position), then move to the fresh GPS fix unless you moved the map; an old position is labelled "Last known location, 3 d ago". With no position the app opens on the last region, else on all regions.
- Location off, not asked, denied, restricted, approximate or services off: a plain note with the right action (Allow location, Open Settings) and "Choose region". Nothing is asked on launch.
- Repeater lists sync on app open and resume (region roster with ETag, and the server's network repeater list once it is offered) and are stored for offline names and map pins; the Repeaters panel shows "Updated 5m ago" / "Offline - as of 2d ago".
- Repeater names: region roster first, then MeshSonar's list, then the network list near you, then map.meshcore.io; prefixes the region marks as shared are never guessed. With the network list available the 17 MB map.meshcore.io download is skipped.

- Settings restructured into Account & driver key, Region, Units & display, Map & offline maps, Privacy & data sharing, Radio, Drives & uploads, Data & storage, Diagnostics and About, one file per section under `lib/ui/settings/`. Every row explains what it does; destructive and sharing changes ask first.
- Settings search: matches titles, explanations and keywords and jumps to the row (opens its section, tints the row, announces it to screen readers). Sections fold from their headers on phones; wide screens (>= 840 dp) show sections and content side by side.
- Privacy & data sharing: one switch per data category from a registry (today only packet headers); turning sharing on asks and lists exactly what is shared; erase what the server holds at any time; "What MeshSonar shares" page; the location explainer is reachable from Settings. The first-run sheet and Settings now use the same text, and it lists every field actually sent (packet fingerprint, app version and platform were missing).
- Data & storage: space used by drives, saved region data, repeater names, the public node map and offline maps, with clear actions that state the cost first. Only fully uploaded drives can be removed there; drives with pings waiting or rejected always stay.
- Diagnostics: view, copy (secrets hidden, coordinates rounded, same rules as problem reports) or clear the diagnostic log.
- Location explainer wording corrected: between drives a coarse position is used on the phone to keep the region right (it said "no tracking when you are not driving").
- Charts: every chart now has a Chart / Table switch and reads its numbers to VoiceOver (one chart kit, `lib/ui/charts`); the repeater sparklines use it too.
- Drive report v2: noise floor during the drive, reply RSSI, TX power, signal by distance to the repeater (direct links, the website's distance bands), heard by speed, GPS accuracy; Export as text or one CSV file (contains your exact track).
- Region tab: new RF tab (noise floor by observer, by hour of day, SNR histogram; an observer that went quiet is named and its line stops) and Growth tab (known nodes over time, weekly churn, roles, hash sizes).
- Region tab: Export region report as text, JSON, one CSV with every table, or any table as the website's own CSV file.
- Your progress (Drives tab card): every drive on this phone by ISO week (Monday start, your local time): distance, heard %, new grid cells, new repeaters; totals, best drives, and your radio's noise floor and TX power across drives. It says plainly that it covers drives stored on this phone.
- Repeater "Your drives": on the repeater detail screen and the drive repeater sheet, how often and where (grid cells on a small map, never your track) your drives heard it, best SNR, last heard and farthest.
- PDF export: the drive report and the region report as PDF (charts, every table row, Barlow embedded, your units), shared through the share sheet (Print / Save to Files). New dependency `pdf` (Apache-2.0, pure Dart, no network).
- Charts: the region overview sparkline, the Reports panel bars, the Analysis heatmap and the drive heard strip moved onto the chart kit; the sparkline, bars and drive-card strip now read their numbers to VoiceOver.
- Radio protocol: decoders, encoders and byte tests for GET_STATS core (battery, uptime, error flags, queue) and packets
  (30 B and 26 B), and GET_BATT_AND_STORAGE; `MeshCoreCompanionLink` reads them (unsupported asked once). The simulator
  answers all of them.
- Drive context core (stream 7, not yet switched on in a drive): `RadioHealthPoller` (60 s, never during a ping),
  `DriveContextRecorder`, per-drive `samples.jsonl` / `ctx.jsonl` / `context.json` beside the drive (uploads and
  exports byte-identical), category list with disclosure text (`lib/core/data_categories.dart`), GPS altitude, course
  and accuracies kept on `GeoFix`.
- Units: air pressure (hPa / inHg) and temperature (°C / °F).
- Data collected during drives (stream 7, opt-out): motion and altitude, phone barometer, phone battery, phone and app
  details, radio health (battery, uptime, error flags, packet counters, airtime, storage, every minute, never during a
  ping), the radio chip's temperature (from the radio's own telemetry, ESP32 / nRF52 boards) and radio settings,
  recorded with the drive on this phone only (not uploaded). Drive report: noise floor and SNR by radio temperature. Weather is listed as not
  available yet. No phone air temperature (iPhones have no sensor).
- First-run disclosure v2 "What MeshSonar collects": every category with its own switch, Continue / Turn all off;
  shown once to everyone who saw only the packet-header sheet; nothing new is collected before it is seen.
- Settings > Privacy & data sharing: a switch per category; off stops at once and offers to delete it from the drives
  on this phone. Drive report: new "Phone and radio context" section. Export files add the drive's context.
- iOS: Motion & Fitness usage text for the barometer and an app privacy manifest (PrivacyInfo.xcprivacy).
- Map engine groundwork (not on screen yet): grid clustering for 5-20k points (`core/cluster_index.dart`), map links compatible with the website's `/coverage` URL (`core/map_view_state.dart`), the layer registry with website `?show=` keys and honest per-layer availability, a single-painter clustered repeater layer for the global "All MeshCore repeaters" list and the region roster, and a repeater detail sheet (copy key, last advert, distance in your units, Open repeater page).

## [0.19.0] — 2026-10-24 — Timeline, telemetry, offline cache

- Map layers > Network coverage > Coverage options: "Coverage growth (as of)" slider with play/pause and a Live reset; the map shows a "Coverage as of <date>" badge while scrubbed back (server `public-coverage?until=`).
- Opt-out telemetry uploader: packet headers and metadata only (type, route, path hashes, SNR/RSSI, time, packet hash), never payloads or coordinates, never your own pings or private message types. Turning it off clears the queue and offers to erase what was already shared.
- Region data is cached with ETags; with no network the Region tab shows stored data labelled "Offline - as of ...".
- The region follows the phone's GPS when not driving (same preset: notice and switch; different preset: prompt; the radio is never changed silently).
- Repeater detail screen (tap a repeater in the Region tab > Repeaters).

## [0.18.0] — 2026-10-23 — Coverage layer controls

- Map layers sheet > Network coverage > "Coverage options": hex detail (Auto picks H3 resolution 7 to 11 by zoom, or pin one), colour by Best SNR / Share heard / Noise floor with a legend, since chips (1 h, 24 h, 7 d, All) and source chips (All, MeshSonar, MeshMapper); tapping a cell opens a sheet with pings, heard share, best and median SNR, repeaters heard, noise floor and last measured. The coverage timeline needs a server change and is not built.

## [0.17.0] — 2026-10-23 — Units everywhere, offline map packs

- Settings > Units (Auto / Metric / Imperial) now drives every distance, speed and height shown in the app: drive stats, drive detail and sessions, the drive report and its exported text, map rings and repeater link tags, heard box and repeater widgets, ping detail, the antenna sheet and the min-distance slider; the region Stats, All regions, Reports and Repeater detail screens follow it too. Auto follows the phone's region (US, Liberia and Myanmar are imperial).
- Offline map packs (Settings > About > Offline maps): download, pause, update and delete per-region PMTiles packs; the map draws a pack when one covers the view. No pack is published yet.

## [0.16.0] — 2026-10-23 — Stats, All regions, Live, Radio tab, border-crossing polish

- Region screen: Stats tab (live drivers, figures, 30-day leaderboard), All regions screen (groups, per-region figures, sortable compare table), and a Live tab streaming region packets over SSE (reconnect with backoff, 65 s watchdog, pauses in the background).
- Radio tab (read-only): the connected radio's settings beside the viewed region's preset with Matches/Differs per field, plus an on-demand community preset comparison. Telemetry: first-run disclosure and a Settings switch (on by default, opt-out); packet headers/metadata only, never message content; no uploader is wired yet.
- Region awareness: a region change commits after 3 consecutive fixes with 100 m edge hysteresis; banner on automatic switches; a different radio preset asks first and never writes to the radio; iOS "Always" location explainer; the map centres on the viewed region; region data cached on disk with an "Offline, as of" chip.

## [0.15.0] — 2026-10-23 — Packets panel

- The Region tab's Packets panel is live: recent packets for the viewed region with route filter chips (All, Flood, Direct, T-flood, T-direct), a Live/Paused switch that polls every 10 s while visible, pull-to-refresh and honest pending, busy and reconnecting states.

## [0.14.0] — 2026-10-23 — Region tab panels

- The Region tab now shows real data for the viewed region: Overview (stats, packets-per-hour sparkline, recent events), Repeaters (searchable, sortable, filterable list with detail sheet and an optional "Region repeaters" map layer), Observers, Analysis (role and hash-size mix, busiest-hours heatmap, hops, top repeaters) and Reports (24 h figures, trend, notable events, network health, data sources). Packets is still a placeholder.
- `hosts_static_test` allow-list includes the new region API clients.

## [0.13.0] — 2026-10-23 — region switcher and Region tab

`pubspec.yaml` is `0.13.0+17`.

- **Region tab (new, 2nd tab)** hosting website data for the viewed region as tabs (Overview, Repeaters, Observers,
  Packets, Analysis, Reports; panels land as their own files, see `lib/ui/region/region_panels.dart`).
- **Region switcher** (chip on the Region tab and the Settings "Region" tile): lists ALL regions from `regions-index`,
  the phone's GPS region first, then nearest; "Follow my location" returns to automatic. Outside every region the
  nearest region shows. The choice and the last viewed region are saved (`region_manual`, `region_last`).
- The coverage layer and the radio-preset display now follow the viewed region (read from that region's own host);
  a custom server keeps single-region behaviour. Region detection now uses the real boundary polygon.
- Settings: new "Region & units" section (region, preset of the viewed region, Auto/Metric/Imperial). The setting is
  stored; `lib/core/units.dart` (tested) is the formatting core, screens migrate next.

## [0.12.0] — 2026-10-21 — discovery (listen-only) mode

`pubspec.yaml` is `0.12.0+16`. Bundle id unchanged. A pure app-side feature — no server change (`docs/
MESHSONAR_DRIVE_FORMAT.md` already documents `"kind": "tx" | "rx"` as current, accepted, default `"tx"`), and no
collision with the in-progress drive-stats work in its own separate worktree.

Research grounding this build (`meshsonar-infra/docs/planning/meshmapper-teardown.md` §3.3-3.4, citing
`wiki.meshmapper.net` and `github.com/MeshMapper/MeshMapper_Flutter_App`): MeshMapper's own "Passive" mode still
transmits a zero-hop discovery request every 30 s — not fully silent. Its separate Passive RX logging pipeline is
continuous and independent of transmission: it overhears `GRP_TXT`/`ADVERT` traffic, keys each sighting by the
**last-hop** repeater (MeshCore's `Mesh.cpp` appends each repeater's hash to the end of the path before
re-flooding, so the last path entry is the one physically heard, not the first), keeps the best-SNR sighting per
repeater, and flushes a batch every 25 m moved or 30 s elapsed. This project's privacy stance is stricter than
MeshMapper's: listen-only means nothing goes out at all, so the DISC-every-30s transmission is dropped; everything
else about the Passive RX pipeline (continuous overhearing, last-hop keying, 25 m / 30 s batching, best-SNR per
repeater) is mirrored.

- **A discovery/listen-only drive mode: the phone transmits nothing — not even the privacy-hardened `MS:<tag>`
  ping — and only records what it overhears.** `WardriveConfig.listenOnly` (immutable mid-drive, same as
  `channel`) and `Settings.discoveryMode` (persisted, locked while driving). The engine still joins the channel
  (`ensureChannel` is BLE-local, never an RF transmission) to get the secret needed to decrypt overheard traffic,
  but a continuous RX collector (`DefaultWardriveEngine._onPassiveHeard`, running for the whole drive, not a
  few-second window around a ping) replaces the auto-ping cadence entirely. `pingNow()` throws in this mode;
  interval/distance/next-ping status fields go null — they don't apply when nothing is ever transmitted.
- **`HeardTracker.addPing`** (`lib/core/heard.dart`) no longer gates on `kind == PingKind.tx`: the live Heard
  panel/map now populates during a discovery drive too. Safe change — a normal tx drive never emits rx pings,
  before or after this, so tx-drive behaviour is unchanged.
- **UI**: Settings → Wardriving gains a "Discovery (listen-only)" switch, disabled (not hidden) while a drive is
  active — a privacy-critical toggle, no silent-ignore-mid-drive ambiguity. The interval/minimum-distance sliders
  show as greyed out with a "doesn't apply" caption when discovery mode is on. The Drive screen hides "Ping now"
  entirely in discovery mode (not just disabled) and the map hint/status text says "Listening" instead of
  ping-oriented language.
- **Fixed a real pre-existing bug this feature surfaced**: the drives list' "Heard %" (`heardCount/pingCount`)
  would show a misleading "0% heard" for an all-rx (discovery) drive — reading as a failed drive, not a successful
  listen session. `lib/ui/drive_stats.dart`'s `DriveStats.heardPercent` already guarded this correctly
  (`txPings == 0 ? null : …`); `SessionSummary` (`lib/core/api.dart`) gained the same tx-aware `txCount` field,
  computed in `lib/core/drive_store.dart`, and `lib/ui/sessions_screen.dart`'s percentage now guards on it the
  same way. `AppState.heardPercent` (the live Drive-screen stats strip) had the identical bug — only ever dormant
  before this feature made an all-rx drive possible — and got the same fix (`AppState._txCount`).
- Gate: `flutter analyze` clean, `flutter test` all green (baseline 591 passing / 7 skipped after the previous
  release below, plus this feature's new tests).

## [0.11.0] — 2026-10-21 — more live, mid-drive stats

`pubspec.yaml` is `0.11.0+15`. Bundle id unchanged. Pure UI/local-logic addition — no wire format change, no new
server calls.

- **A second stats strip on the Drive screen, shown only while actually driving** (hidden before Start and after
  Stop — the drive report covers the final figures once the drive is over):
  - **Distance** and **Elapsed** for this session, summed/measured the same way `DriveStats`/`DriveReport` already
    do (ping-to-ping haversine; `session.startedAt` vs. the clock) — just live instead of computed once at the end.
  - **A running new-vs-repeat grid-cell tally** ("N new" / "N repeat"): the live counterpart of the after-drive
    report's "new grids" figure. New `lib/ui/drive/drive_live_stats.dart` (`DriveLiveStats`, a `ChangeNotifier` owned
    by the Drive screen) reuses `drive_report.dart`'s exact cell identity (`cellIndexOf`, CMAT's 0.002°×0.0025° grid)
    and its earlier-local-drives history rule, reading that history once per drive (async) and then classifying each
    new tx ping against it incrementally, rather than recomputing the whole drive's cells on every ping.
  - **GPS accuracy of the current fix** ("±N m", colour-coded good/fair/poor by the same bands `position_filter.dart`
    already treats as acceptable/marginal; "No fix" while waiting for one). `DriveMapModel` gained a `fix` getter
    (the `GeoFix` behind the existing `position`) so this reads the same continuously-updated fix the live map
    position already uses, rather than opening a second GPS subscription.
- **Deliberately left out this pass:** a "time since last heard repeater" stat — the live heard box already shows
  each repeater's `pings ago`/`missed N` state, and a second, wall-clock-based number next to it would compete for
  attention rather than add anything a driver can't already see at a glance.

## [0.10.0] — 2026-10-20 — live region awareness

`pubspec.yaml` is `0.10.0+14`. Bundle id unchanged. Builds on the website's `GET /api/cmh/regions-index`
(already live, serving the same region codes/bboxes/boundaries for `meshsonar.com` and every `<region>.
meshsonar.com` host). This is purely live, local, in-app feedback — the server already tags every ping's true
region correctly at upload time regardless of connectivity, so this never changes what a ping is tagged as.

- **Drive-screen badge: which MeshSonar region the phone is physically in, right now.** A small chip above the
  map's full-screen/layers buttons shows the region's code (e.g. "CMH") once a fix and a regions index are both
  known. Detected at app startup (one-shot GPS fix, before any drive begins) and kept live during a drive by
  riding the engine's own GPS stream — no second, always-on `Geolocator` subscription. States handled
  explicitly, each shown plainly rather than left blank: nothing yet (no cache, no fetch has ever answered) —
  badge hidden; a fix but no regions-index data — "Locating…"; a fix outside every known region's bbox —
  "Outside coverage"; offline on a stale cache — the matched code, with the tooltip saying so; a normal match —
  the code, full name in the tooltip.
- **A one-shot "Entered DAY" notice on a border crossing mid-drive.** Reuses the same transient-notice mechanism
  as the upload success/error banners (`AppState._say`/`pendingNotice`/`takeNotice`, shown as a `SnackBar` by
  `HomeShell`) rather than inventing a new one. Only fires for a genuine change into a different *named* region
  while actively driving; silent background detection at startup or while idle never pops a toast.
  - New `CmatClient.regionsIndex()` (public, no driver key) in `lib/core/api.dart`/`cmat_client.dart`, following
    `siteConfig()`'s parsing/error convention exactly (malformed response → `CmatException`, not silent garbage).
  - New `lib/core/region_lookup.dart` (pure Dart): `RegionIndexEntry` model (code/slug/name/url/bbox/boundary),
    `regionAt()` — bbox-only point-in-rectangle matching with a nearest-bbox-centroid tiebreak for overlaps — and
    `RegionIndexCache`/`FileRegionIndexCache`/`MemoryRegionIndexCache` + `RegionIndexService`, a fetch-then-cache
    wrapper mirroring `FileRepeaterCache`'s shape: a failed fetch falls back to the last-cached index rather than
    going blank.
  - **Scope cut, deliberate:** matching is bbox-only this pass, not point-in-polygon against `boundary` (real
    algorithmic risk under a same-day deadline) — `boundary` (`Polygon` or `MultiPolygon`) is parsed and cached
    for later, never evaluated yet. No per-ping region/IATA field was added to the upload wire format (a
    separate, lower-value, cross-repo change). Overlapping bboxes at a point are resolved by nearest centroid —
    simple and defensible, not a geometric guarantee; a judgment call for this pass.
  - `AppServices` gained an optional `regionIndexCache` (null in tests unless set; the real app wires a
    `FileRegionIndexCache` next to `settings.json`).

## [0.9.0] — 2026-10-20 — network coverage on the live map

`pubspec.yaml` is `0.9.0+13`. Bundle id unchanged. Builds on the website's `GET /api/cmh/public-coverage`
(already live, serving the same cells `/coverage` draws on meshcore-insights).

- **Network-wide coverage, drawn on the Drive screen's map by default.** A new quiet background layer shows
  every driver's measured coverage (squares or H3 hexagons, whichever grid the region uses) underneath the
  pings, repeaters and links — "where hasn't this been driven", not just this drive's own pings. On by default,
  no extra step to find it, since basic visibility while driving was the point. Coloured by best SNR, the same
  4-step legend the website's `/coverage` page uses (strong/likely/possible/stretch green/blue/amber/red); an
  area nobody has measured is simply left blank — that absence is the gap indicator, so there's no "no data"
  placeholder to build or to misread.
  - New `CmatClient.publicCoverage()` (public, no driver key) and `CoverageCell`/`CoverageGrid`/`PublicCoverage`
    models in `lib/core/api.dart`, matching the server's response field for field (minus the per-source split,
    out of scope for this pass).
  - New `lib/core/network_coverage.dart`: pure logic turning a `PublicCoverage` answer into drawable cells
    (square bbox or H3 hexagon boundary) bucketed by colour-by dimension. Best SNR is the one wired into the map
    today; share-heard and noise-floor buckets are implemented and tested too, ready for a picker later if
    that's ever wanted.
  - `CoverageMap` (`lib/ui/map/coverage_map.dart`) gained a `networkCells` parameter, drawn as a new layer right
    above the basemap tiles (the bottom of the data stack) — reusing the exact same widget the live drive map
    already uses, not a parallel implementation.
  - New `MapLayers.networkCoverage` toggle (default on), with a matching switch in the existing layers sheet
    (`showMapLayersSheet`, shared by the Drive screen and the full-screen map) — "Network coverage" alongside
    "Hex coverage", "Pings", etc.
  - `AppState.refreshNetworkCoverage()` fetches once at startup and again on a server-URL change (mirroring
    `refreshSiteConfig()`'s pattern exactly); a failed refresh is logged quietly and never clears cells already
    on screen — stale coverage is still useful for "where hasn't this been driven", so a network hiccup keeps
    showing the last good answer instead of blanking the map.
- **Deliberately left out of this pass** (basic visibility, not full feature parity with the website's
  `/coverage` page): no colour-by picker in the UI (one dimension, best SNR, is enough for an always-on
  background layer — adding a mode switch would be UI weight in the wrong place); no since/source filters, no
  place-picker, no cell-click-for-detail drill-down; no separate region-picker "Stats" dashboard (considered,
  deferred — a good next step, not blocking this one).

## [0.8.0] — 2026-10-20 — Settings knows the server's region and its radio preset

`pubspec.yaml` is `0.8.0+12`. Bundle id unchanged. Builds on the server's `GET /api/cmh/site-config` region +
radio-preset fields (already live).

- **Server region, shown next to the Server URL tile:** a read-only "Connected to: `<host>`" row names the region
  the configured server resolves to (e.g. `cmh.meshsonar.com`). Shown only once the server answers; a slow or
  missing answer leaves today's Server URL tile exactly as it was.
- **Radio preset comparison (informational only — the app never writes to the radio):** a new Settings row shows the
  region's suggested MeshCore RF parameters (name, frequency, bandwidth, spreading factor, coding rate). If the
  region has none configured, it says so plainly. If a radio is connected, its own live parameters are shown
  alongside the region's, each clearly labeled ("Yours" vs. the region's); with no radio connected, the preset is
  shown with a "No radio connected to compare" note.
- **"Manage privacy zones on the website"** button next to "Get a key on the website": opens `<server>/me/privacy`
  in the system browser, same treatment as the existing key-request link. Drivers manage trim radius and privacy
  zones on the site's `/me` pages; no new driver-key endpoints were added.
- A server-URL change clears the old region/preset immediately (never shows a stale region against a new server)
  and refetches once the new URL is saved. All of this is best-effort: fetch failures are logged quietly, never
  shown as an error, and never affect the Server URL tile.

## [0.7.3] — 2026-10-18 — ping text is "MS:" + a random tag

`pubspec.yaml` is `0.7.3+11`. Bundle id unchanged.

- The ping on the public channel is now `MS:` plus a random 10-character tag from the secure random source, for example
  `MS:m3jnr7dan5`. Nothing else: no position, no power, no name. A new tag for every ping, never derived from position, time or driver.
- The tag is stored with the ping and uploaded as `wire_tag` (Drive Format v1.1, optional; servers that do not know it ignore it), so a
  heard repeat can be matched to exactly that ping in analysis. The transmit power is already sent as `tx_dbm`.

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
