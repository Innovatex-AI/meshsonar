# Testing MeshSonar

`flutter test` runs **254 tests: 253 pass and 1 skips** (the opt-in live smoke test). That's on Linux with bun and the
CMAT checkout present, and it takes about 3 min 20 s. `flutter analyze` must report no issues. How to install tools and
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
| `drive_store_test.dart` | Round trip of every field (nulls stay null); on-disk files; heard-nothing preserved; **crash-truncated last line** skipped then repaired; garbage line skipped; `session.json.tmp` fallback; `endSession`; `sessions()` order and counts; `unsyncedPings` excludes synced/rejected; end-reported marker; concurrent appends don't interleave; unknown session fails; path-like ids refused; delete; export = one valid v1 file; duplicate ids read once. |
| `settings_store_test.dart` | Missing/corrupt → defaults; atomic save; rapid saves serialised; old/odd values clamped; antenna defaults to internal. |
| `cmat_client_test.dart` | Endpoint URLs with/without trailing slash or sub-path; key request (nulls omitted, 201); 429; status with `x-driver-key` and every status string; 401; upload body and rejection parsing; 403; non-JSON error page; unreadable 200; network errors and timeouts → `CmatException(status: null)`; repeaters list. |
| `sync_service_test.dart` | No key / pending key → nothing sent; synced only after 200; **12,001 pings → 3 requests**; no double upload; overlapping calls; mid-sync network failure resumes; lost 200 → duplicates; 403 keeps data; 403 stops `syncAll`; network down; rejected pings kept and never re-sent; **> 20 rejections discovered by re-sending**; end time reported once (empty upload only when needed; zero-ping drive); open session with nothing to send makes no request; totals; unknown session; store without `SyncLedger`. |
| `cmat_contract_test.dart` | Against CMAT's real handlers: request → approve → upload a real drive → re-sync = duplicates → end reported; 12,001 pings in 3 requests all stored; validator rejections recorded locally and not re-sent; unknown key 401, revoked key → status revoked + upload 403. |
| `position_filter_test.dart` | Parked phone with ±20 m jitter for 10 min (speed 0 / unknown, several seeds) holds still; ±30 m drift with optimistic accuracy; pull-away followed within 2 fixes (with speed) or a few fixes (without); 90° turn not overshot; steady driving tracks truth; stoplight hold and move-off; poor fixes dropped then used after a drought; nonsense input; `FilteredLocationSource` shares one filter; no fix → null. |
| `heard_test.dart` | `RepeaterLookup` unique / ambiguous / unknown / later source; `HeardTracker` live for `holdPings` then stale, distance, best SNR; bearing and compass. |
| `repeater_directory_test.dart` | Node filtering (type, radius, nearest first, lower-case); `JsonArraySplitter` across arbitrary chunk boundaries; refresh → cache file → `load()`; TTL, centre-moved and forced refetch; offline / HTTP error / bad JSON never throw and back off; no cache + offline; damaged cache; idle timeout; size limit; `maxRepeaters`. |

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
| `onboarding_test.dart` | Intro shown on first run and not again; skippable; "Try the Simulator" connects; "Request a key" lands on Settings; file prefs persist and a damaged file means first run. |
| `simulator_smoke_test.dart` | AppState + real simulator + link + engine: connect, start, ping now, stop → ping stored. |

### `test/integration` and `integration_test`

| File | Covers |
|---|---|
| `test/integration/end_to_end_test.dart` | Simulated radio (real frames, real encrypted echoes) → `MeshCoreCompanionLink` → `DefaultWardriveEngine` → `JsonlDriveStore` → `DefaultSyncService` → `HttpCmatClient` → CMAT's real handlers. The server must hold every ping and echo the radio produced. |
| `test/integration/live_smoke_test.dart` | Same pipeline against a deployed server with an approved key; re-sync is duplicates only. |
| `integration_test/app_flow_test.dart` | Real app on a device or simulator: first run → simulator drive → full-screen map → log → stop/report card → drives → detail → settings, printing `SCREEN <name>` for screenshots. |
| `test/fixtures/cmat_server.ts` | bun server wrapping CMAT's `makeDriveHandlers` + `memoryDriveStore`, with one test repeater, `/__test/state` for assertions, and `PORT n` on stdout. |

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
