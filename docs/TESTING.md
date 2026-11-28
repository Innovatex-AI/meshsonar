# Testing MeshSonar

`flutter test` runs **282 tests: 281 pass and 1 skips** (the opt-in live smoke test). That's on Linux with bun and the
CMAT checkout present, and it takes about 3–4 min on a desktop (about 14 min in a busy build container). `flutter analyze` must report no issues. How to install tools and
run the opt-in suites is in [DEVELOPMENT.md §4](DEVELOPMENT.md#4-running-the-tests).

## Kinds of test

| Kind | Where | Needs |
|---|---|---|
| Pure-Dart unit tests | `test/core`, `test/radio` | nothing (no Flutter bindings except where noted) |
| Widget tests (fakes, no plugins) | `test/ui` | `test/ui/fakes.dart` (`Harness` builds `AppServices` from fakes) |
| AppState behaviour (real timers, fakes) | `test/app`, `test/radio/app_cadence_hook_test.dart`, `test/ui/ping_log_directory_test.dart`, `test/ui/simulator_smoke_test.dart` | fakes; the simulator smoke test uses the real link, engine and simulator |
| Contract test | `test/core/cmat_contract_test.dart` | bun + CMAT checkout; **skips** otherwise |
| End-to-end | `test/integration/end_to_end_test.dart` | bun at `/root/.bun/bin/bun` + CMAT checkout; **skips** otherwise |
| Live smoke | `test/integration/live_smoke_test.dart` | `MESHSONAR_LIVE_URL` + `MESHSONAR_LIVE_KEY`; **skips** otherwise |
| On-device flow | `integration_test/app_flow_test.dart` | a simulator, emulator or device (`-d`) |

Under `flutter test` the app turns off map tiles, wake lock/haptics and the animated intro art. It detects the run
through `FLUTTER_TEST` in the environment.

## What each file covers

### `test/core`

| File | Covers |
|---|---|
| `helpers.dart` | Builders for sessions and pings, plus a **Dart mirror of CMAT's `validate.ts` shape rules** used to check exports and uploads. |
| `drive_store_test.dart` | Round trip of every field (nulls stay null); on-disk files; heard-nothing preserved; **crash-truncated last line** skipped then repaired; garbage line skipped; `session.json.tmp` fallback; `endSession`; `sessions()` order and counts; `unsyncedPings` excludes synced/rejected; **rejected counted apart in `sessions()`**; **`renameSession` + re-send token**; **`closeOrphanedSessions`**; end-reported marker; concurrent appends don't interleave; unknown session fails; path-like ids refused; delete; export = one valid v1 file; duplicate ids read once. |
| `settings_store_test.dart` | Missing/corrupt → defaults; atomic save; rapid saves serialised; old/odd values clamped; antenna defaults to internal; **`30.0`-style numbers load and a wrong-typed field falls back alone**; model ints (`hops`, `delay_ms`, `sf`, `cr`) from floats. |
| `cmat_client_test.dart` | Endpoint URLs with/without trailing slash or sub-path; key request (nulls omitted, 201); 429; status with `x-driver-key` and every status string; 401; upload body and rejection parsing; 403; non-JSON error page; unreadable 200; network errors and timeouts → `CmatException(status: null)`; repeaters list. |
| `sync_service_test.dart` | No key / pending key → nothing sent; synced only after 200; **12,001 pings → 3 requests**; no double upload; overlapping calls; mid-sync network failure resumes; lost 200 → duplicates; 403 keeps data; 403 stops `syncAll`; network down; rejected pings kept and never re-sent; **> 20 rejections discovered by re-sending**; end time reported once (empty upload only when needed; zero-ping drive); open session with nothing to send makes no request; **renamed drive re-sends its session once (also open drives, rides on a pending upload, kept after a failed upload)**; **orphan closed at launch reports its end**; rejected pings leave nothing to sync; totals; unknown session; store without `SyncLedger`. |
| `cmat_contract_test.dart` | Against CMAT's real handlers: request → approve → upload a real drive → re-sync = duplicates → end reported; 12,001 pings in 3 requests all stored; validator rejections recorded locally and not re-sent; unknown key 401, revoked key → status revoked + upload 403. |
| `position_filter_test.dart` | Parked phone with ±20 m jitter for 10 min (speed 0 / unknown, several seeds) holds still; ±30 m drift with optimistic accuracy; pull-away followed within 2 fixes (with speed) or a few fixes (without); 90° turn not overshot; steady driving tracks truth; stoplight hold and move-off; poor fixes dropped then used after a drought; nonsense input; `FilteredLocationSource` shares one filter; no fix → null. |
| `heard_test.dart` | `RepeaterLookup` unique / ambiguous / unknown / later source; `HeardTracker` live for `holdPings` then stale, distance, best SNR; **hold changed mid-drive re-applies at once**; bearing and compass. |
| `repeater_directory_test.dart` | Node filtering (type, radius, nearest first, lower-case); `JsonArraySplitter` across arbitrary chunk boundaries; refresh → cache file → `load()`; TTL, centre-moved and forced refetch; offline / HTTP error / bad JSON never throw and back off; no cache + offline; damaged cache; idle timeout; size limit; `maxRepeaters`. |

### Regions at 559

`test/support/regions_559.dart` builds a deterministic 559-region stand-in of `regions-index` (230-vertex outlines, accented names, country suffixes) and a
`square()` helper for exact borders. `core/region_geometry_test.dart` (typed arrays agree with the old ray cast on 20,000 points, holes, MultiPolygon,
malformed), `core/region_pick_559_test.dart` (slivers, nested zones, seams, L shapes, switcher order, 5,000 fixes), `core/region_search_test.dart`,
`core/region_index_service_test.dart` (off-isolate parse, fingerprint, back-off, refine, big file round trip, `regionsIndex` 429/slugs, 304 on a 3.4 MB body),
`app/region_559_state_test.dart` (also-in, seam, exact outline, foreground cadence), `ui/region_picker_559_test.dart` (sheet and All regions at 559),
`ui/region_preset_states_test.dart`, `ui/region_crossing_no_preset_test.dart`, `ui/new_region_empty_states_test.dart` (real UKK answers in `test/fixtures/ukk_*`).
Benchmarks over a real body: `tool/bench_regions.dart`, `tool/bench_regions_new.dart`.

### `test/radio`

| File | Covers |
|---|---|
| `crypto_test.dart` | SHA-256, HMAC-SHA256 and AES-128 against published vectors; hashtag secret (`#test` from the firmware docs, case-insensitive, `#wardriving`); channel hash; encrypt-then-MAC round trip and MAC rejection. |
| `protocol_test.dart` | Code values; every encoder (APP_START, DEVICE_QUERY, SET_DEVICE_TIME, GET/SET_CHANNEL, SEND_CHANNEL_TXT_MSG, SYNC_NEXT, GET_STATS, NODE_DISCOVER_REQ) and decoder (OK/ERR, SELF_INFO incl. simulator round trip, DEVICE_INFO, CHANNEL_INFO, STATS radio, LOG_RX_DATA, CONTROL_DATA + DISCOVER_RESP, CHANNEL_MSG_RECV v3/legacy, MSG_WAITING, NO_MORE_MESSAGES, unknown, empty). |
| `packet_test.dart` | Header bits; path_len with 1-byte hashes; transport codes + 2-byte hashes; rejects what firmware rejects; GRP_TXT decrypt; **Python-built vectors reproduced byte for byte**; `matchEcho` accepts our repeat and rejects other text, timestamp, channel, empty path, non-flood. |
| `companion_link_test.dart` | Start sequence and `SelfInfo`; `ensureChannel` installs `#wardriving` in the first empty slot then finds it; unknown private channel → clear error; real send frame + RX pushes; strictly increasing timestamps; noise floor (null without stats); unresponsive radio times out; disconnect fails the pending command and closes RX; simulator scanner. |
| `wardrive_engine_test.dart` | Ping text = MeshMapper `buildPayload`; `pingNow` emits one ping with real echoes; driving the loop gives some heard and some not, every ping emitted; real-clock auto mode (first ping immediate, 1 s → 10 s clamp, manual pings allowed); no GPS → no ping; stop waits for the ping on air; radio disconnect mid-drive; dead radio at start; optional neighbour discovery. |
| `wardrive_cadence_test.dart` | Fake clock + hand-driven GPS: first ping immediate; waits for distance; waits for time; fast driving pings exactly every interval; parked → no auto pings; Ping now resets timer and anchor; clamping (1 s → 10, 5 m → 15, 1000 m → 500, 999 s → 120, 0 = manual); manual-only mode; `updateConfig` mid-drive; no GPS waits then pings; no ping during another's listen window; **parked jittery GPS behind the filter: 10 min, one ping**. |
| `app_cadence_hook_test.dart` | `AppState.updateSettings` pushes interval/distance into the running engine; nothing when idle. |

### `test/app`

| File | Covers |
|---|---|
| `state_fixes_test.dart` | Orphaned drives closed at launch at the last ping (or start) and uploaded quietly only with an approved key; failed start deletes an empty drive but keeps one with pings; server URL change clears key/status; heard hold applied mid-drive; rename saved in the drive (also while driving); 0.2.x phone-only names migrated; `openWebPage` URL and no-browser message. |
| `app_version_test.dart` | `loadAppInfo` reads the version from `package_info_plus` (null when unknown); pubspec is `0.3.0+3`; no Dart file hard-codes an app version. |
| `drive_upload_test.dart` | In-drive uploads on schedule update `syncedCount`; stop at Stop with the final upload after `ended_at`; toggles and key gate; turning on mid-drive / a longer period restarts the timer; never overlaps; quiet failures retried next tick; real sync service carries `ended_at`; a drive fully uploaded mid-drive still reports its end at Stop. |

### `test/ui`

| File | Covers |
|---|---|
| `fakes.dart` | `FakeDriveStore`, `FakeCmatClient`, `FakeSyncService`, `FakeSettingsStore`, `FakeTransport`, `FakeScanner`, `FakeLink`, `FakeLocation`, `FakeEngine`, `Harness`. |
| `drive_flow_test.dart` | Empty Drive screen; start → pings appear and are stored → stop → sync; heard-nothing shown and kept; sync failure / 403 messages keep pings; no auto-sync while pending; **failed local write retried, ping not lost**; simulator uses simulated location; permission denied blocks start; connect and scan failures. |
| `drive_screen_test.dart` | Wake lock only while driving, feedback per ping; map dots coloured by result, last SNR stat; countdown; empty-state hint; signal bars. |
| `drive_redesign_test.dart` | Heard snapshot phases; heard box live → holding → stale (+N earlier); tap highlights on map; antenna toggle (default internal, locked while driving); full-screen map open/close; LOG and report card; next-ping indicator (time / distance / GPS); simulator labelling. |
| `map_coverage_test.dart` | Ping colour scale; links resolve unique prefixes only; map draws pings, repeaters, position; tap repeater for name; attribution with tiles; drag stops follow → Recenter. |
| `ping_log_test.dart` | `EchoTile` facts (name, id, SNR, hops, RSSI, delay, distance + bearing, source), multi-hop path, unknown and ambiguous ids; saved-drive log summary, order, filters; ping detail with every echo, neighbour, copy as text; repeaters tab → repeater detail with sparkline; live log updates; `pingAsText` omits unmeasured values. |
| `ping_log_directory_test.dart` | Cached directory loads at init; first ping of a drive refreshes it there (names with source = map); offline map never breaks a drive. |
| `sessions_list_test.dart` | `DriveStats` maths (distance, heard %, SNR, repeaters, multi-hop; empty drive); card shows duration, distance, strip, badge; Sync all; failed badge; rename; swipe-to-delete confirmation; pull to refresh. |
| `sessions_settings_test.dart` | Drives empty state; newest first; sync, export, delete; delete warns about unsynced pings; sync without key; key request pending → refresh → approved (key never shown in full); key request failure; settings persist; About shows MIT text. |
| `settings_controls_test.dart` | Slider stops match the allowed ranges; out-of-range stored values clamped; defaults "Every 30 s" / "100 m"; sliders save on drag end; antenna gain/height kept; upload toggle dependency and period slider; last-upload line. |
| `settings_sections_test.dart` | Grouped sections; coloured key badge; welcome tour from Settings. |
| `detail_screen_test.dart` | Drive detail map, stats, named repeaters with counts, ping list; sync and export; delete returns to the list. |
| `report_math_test.dart` | Cell index matches CMAT (negatives too); grids are distinct tx cells, rx ignored; new grids; distance and speed (GPS speed preferred, jumps ignored); empty drive; leaderboard; unknown-to-CMAT only when the list is loaded; new repeaters across prefix lengths; best/worst spots; text summary; **2,500 pings vs 20 earlier drives is fast**. |
| `report_screen_test.dart` | Report from drive detail (hero, new grids and repeaters, not-on-CMAT tags, charts, share); first drive (everything new, no NEW tags) from the drives menu; pushed directly. |
| `fixes_ui_test.dart` | "· N rejected" badge and Sync disabled for rejected-only drives (card and detail); rename → "Name not synced" → Sync uploads it; server change with a key asks first and removes the key (no prompt without a key); account hint `<server>/me` and "Get a key on the website" → `<server>/me/devices`. |
| `onboarding_test.dart` | Intro shown on first run and not again; skippable; "Try the Simulator" connects; "Request a key" lands on Settings; file prefs persist and a damaged file means first run. |
| `simulator_smoke_test.dart` | AppState + real simulator + link + engine: connect, start, ping now, stop → ping stored. |

### `test/integration` and `integration_test`

| File | Covers |
|---|---|
| `test/integration/end_to_end_test.dart` | Simulated radio (real frames, real encrypted echoes) → `MeshCoreCompanionLink` → `DefaultWardriveEngine` → `JsonlDriveStore` → `DefaultSyncService` → `HttpCmatClient` → CMAT's real handlers. The server must hold every ping and echo the radio produced. |
| `test/integration/live_smoke_test.dart` | Same pipeline against a deployed server with an approved key; re-sync is duplicates only. |
| `integration_test/app_flow_test.dart` | Real app on a device or simulator: first run → simulator drive → full-screen map → log → stop/report card → drives → detail → settings, printing `SCREEN <name>` for screenshots. |
| `test/fixtures/cmat_server.ts` | bun server wrapping CMAT's `makeDriveHandlers` + `memoryDriveStore`, with one test repeater, `/__test/state` for assertions, and `PORT n` on stdout. |

### Build 77 additions (whole-app redesign, delivery rebuilt to the official MeshCore flow)

| File | Covers |
|---|---|
| `test/radio/lossy_radio.dart` | A scripted radio that loses frames, answers late, confirms late, confirms an earlier try, drops byte-identical packets, reports table full and "not a contact": tests fail the way a real mesh does. |
| `test/chat/delivery_lossy_test.dart` | The official flow item for item on the lossy radio: 4 direct, one reset path, 4 flood; no-route contact floods with no reset; try numbers 0..7 untouched with one timestamp (prints the bytes of tries 1-8); 160/158-byte limit; late and earlier-try confirmations; duplicates; table full; not a contact; no sync loop after a send; contact writes only on add/edit. |
| `test/radio/reply_matching_test.dart` | Each reply matched to its command by code; a late or stray frame discarded; start order DEVICE_QUERY → APP_START → clock; confirmed Bluetooth writes; the link half of the message log. |
| `test/chat/route_removed_test.dart` | Route modes, pins, eviction and the route-broken logic are gone; Reset route, ping and path history kept. |
| `test/core/time_format_test.dart` | The one time formatter: phone time / UTC setting, 12/24 h, relative times, always-UTC labels for server totals, logs and exports. |
| `test/core/drive_verdict_test.dart` | The drive verdict (Good 80 %+, Patchy 40-79 %, Poor, Nothing answered, Listen-only). |
| `test/core/basemap_choices_test.dart`, `test/ui/map/basemap_layers_for_test.dart` | Road / Light / Dark / Topo / Satellite choices, old saved values, thumbnails, resolve() to the data-first base and the names-above pass. |
| `test/ui/theme_tokens_b77_test.dart` | One meaning per colour: teal selected, amber only for warnings, neutral repeaters, neutral No reply, white link line, magenta friends, teal percent-heard scale, packet colours off the signal hues. |
| `test/ui/map/b77_map_core_test.dart`, `b77_legend_layers_test.dart`, `b77_map_extras_test.dart`, `test/ui/network/live_b77_test.dart` | Map system: fixed credit pill, names above coverage, ping dots in one pass, image cache kept, one chip style, Legend and Layers in plain words, compass, stale/estimated repeaters, Reduce Motion, status pill, small maps, tips, Show whole drive; Live repeaters through the Drive painter, latest packets, Speed in replay, one-copy replay. |
| `test/ui/network/who_heard_test.dart`, `colour_language_test.dart`, `time_setting_test.dart`, `analytics/native_analytics_test.dart` | Network: who-heard grouping with full routes, Private channel, colours, times, native Overview, My Repeaters and Status. |
| `test/ui/chat/round3_chat_test.dart`, `test/ui/meshtrack/round3_meshtrack_test.dart`, `test/alerts/alert_coordinator_round3_test.dart` | Chat: previews, position updates collapsed, first unread, Unread filter, Connect, people button, route hops, "add you" note, try n of m, Cancel, Share my position. |
| `test/ui/settings/messages_section_test.dart`, `round5_more_settings_test.dart`, `time_zone_tile_test.dart`, `test/ui/connect_screen_r5_test.dart` | Settings > Messages and Message delivery, Message log, round 5 renames and moves, Time zone row, Bluetooth-off and wrong-PIN advice. |

## Running subsets

```sh
flutter test test/core/sync_service_test.dart                      # one file
flutter test test/radio --plain-name "cadence"                     # by name substring
flutter test test/ui --name "heard box"                            # regex on test names
flutter test test/core test/radio                                  # pure-Dart layers only
flutter test --reporter expanded                                   # one line per test
```

`flutter test` with no arguments also discovers `test/integration/*`. The contract, end-to-end and live tests skip
themselves when their prerequisites are missing, so the default run is safe offline.

## Mutation-check notes

To see whether the tests actually guard the rules that matter, some deliberate bugs were introduced, one at a time, in
a scratch copy of v0.2.0, and the relevant tests were run against each. The repo was never modified.

| # | Mutation | Tests run | Caught? |
|---|---|---|---|
| 1 | `matchEcho` ignores the timestamp | `packet_test` | **Yes** (1 failure) |
| 2 | Path hash size always 1 byte | `packet_test` | **Yes** |
| 3 | Channel hash = `secret[0]` instead of `SHA-256(secret)[0]` | `crypto_test` | **Yes** |
| 4 | Distance rule always met | `wardrive_cadence_test` | **Yes** (5 failures) |
| 5 | Truncated-tail repair skipped | `drive_store_test` | **Yes** |
| 6 | Rejected pings also marked synced | `sync_service_test` | **Yes** |
| 7 | Heard hold off by one (`<` → `<=`) | `heard_test` | **Yes** |
| 8 | **Save-first removed** (`_onPing` doesn't write) | `drive_flow_test` | **Yes** (6 failures) |
| 9 | Wrong key header name | `cmat_client_test` | **Yes** (3 failures) |
| 10 | Stationary hold never entered | `position_filter_test` | **Yes** (9 failures) |
| 11 | `heardNothing` ignores `neighbor` | all of `test/core test/ui test/radio` | **Yes** (1 failure) |
| 14 | In-drive upload ignores the key status | `drive_upload_test` | **Yes** |
| 16 | `ended_at` re-reported on every sync | `sync_service_test` | **Yes** (4 failures) |
| 12 | Echo de-dup keeps best SNR, ignoring hop count | `test/radio` | **No**: all pass |
| 13 | Echo SNR not range-checked (raw value stored) | `test/radio test/integration` | **No**: all pass |
| 15 | Auto-ping gap not floored at one listen window | `test/radio` | **No**: equivalent mutant (interval ≥ 10 s > 7 s window, so the floor never applies with the default window) |

**Gaps to close:**

- **#12:** add an engine test where the same repeater is heard as a 2-hop copy with higher SNR and a 1-hop copy with
  lower SNR. The 1-hop copy must win.
- **#13:** add a link/engine test where a LOG_RX_DATA push carries an RSSI outside −160…0 (e.g. a positive RSSI
  byte). The echo's `rssi_dbm` must become null. SNR can't leave ±40 dB through this frame, because the int8 ÷ 4
  encoding tops out at ±32.
- **#15** only matters if someone configures a listen window longer than the minimum interval.

To repeat a check: copy the repo to a scratch folder (`tar --exclude=./build --exclude=./.git -cf - . | tar -xf - -C
/tmp/ms`), edit one line there, and run the test file. Don't mutate the working tree.

## MeshSonar radio acceptance tests (build 78, Andy on a real radio)

1. Stock MeshCore radio: connect, chat, wardrive as before; no MeshSonar row; no local network prompt; no request to any local address.
2. MeshSonar radio over Bluetooth, on the phone's Wi-Fi: More > Radio shows "MeshSonar radio 0.1.0"; Pair over Wi-Fi finishes in under 10 s with no tap on the radio; serial `appapi tokens` lists the app.
3. Two MeshSonar radios, phone on radio A over Bluetooth: pairing always ends on A; typing B's address says "This is not the radio you are connected to".
4. Phone off Wi-Fi, or web console Off: "Not on Wi-Fi" within 5 s; Bluetooth chat keeps working.
5. Ask on the radio with Bluetooth off: Allow pairs, No refuses, a locked radio says locked.
6. Sharing / wardrive switches change the radio's More > Sharing within 2 s, and back.
7. Save log to phone gives two files whose sizes match the log; Show on map draws a short drive's GPS points.
8. Map pack: send `cmh-20261108.msmp`; progress moves; the radio's map shows it after Done.
9. Firmware: Check shows the offer; Install over Wi-Fi downloads and the radio asks to restart; after restart the page shows the new version and "kept after 1 minute".
10. Lua apps: load catalog, install, run (opens on the radio), stop, remove.
11. Settings: timeout, volume, quiet hours show on the radio; Lock now locks; Remove PIN with a wrong PIN says "Wrong PIN".
12. Owner link: link to another proven radio; radio's More > MeshSonar account shows it; remove it.
13. Spectrum: a 10 s US scan draws bars and mesh receive continues; Probe now shows a result within 20 s.
14. `appapi revoke all` on the radio: next call shows "Pair again"; pairing works again.
15. iPhone Personal Hotspot: discovery and every section work.
16. Full `flutter test` and `flutter analyze` clean; no test removed.
