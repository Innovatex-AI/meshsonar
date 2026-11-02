# Chat redesign spikes S1-S14 (WP13), 2026-11-02

Plan: `meshsonar-infra/docs/planning/chat-redesign-plan-2026-11-02.md` section 5.4. Firmware read: MeshCore `main` at commit `81dbae5` (`FIRMWARE_VER_CODE 14`), files `examples/companion_radio/MyMesh.cpp`, `src/helpers/BaseChatMesh.cpp`, `src/Packet.cpp`, `examples/simple_repeater/MyMesh.cpp`, `examples/simple_sensor/SensorMesh.cpp`. "V" = read in firmware source, "SIM" = run on the iPhone 17 Pro simulator (iOS 26.5, Flutter 3.47.7, debug build), "DEFAULT" = plan default taken because it needs Andy's radio or hands.

**Radio reachability (checked Nov 2, 2026).** `scripts/ble_cli_probe.py` does not exist in any of the three repos. A 10 s BLE scan from the Mac (bleak 3) found 8 devices (Poseidon M60 BLE, iPhone, iPad Pro, Apple Watch, 4 unnamed) and no MeshCore companion or repeater. So S1 (radio half), S3, S11, S12 (capture half), S13 are not run; each has the plan default recorded and a command in `scripts/spike_radio_probe.py` (new, offline `selftest` passes, NOT yet run against hardware).

Fixtures: `test/fixtures/chat/firmware_derived_frames.json` is built from the firmware source (not captured). Replace/extend with `chat-spike-capture-*.json` from the probe run.

## Result table

| # | Result | Basis | Flag / default in force |
|---|---|---|---|
| S1 | Byte limit is **160** (`MAX_TEXT_LEN = 10*CIPHER_BLOCK_SIZE`), not ~130. App already uses `maxPacketTextBytes = 160`. Radio boundary send pending. | V | keep 160; channel budget `160 - len(name) - 2` is correct; prefix disabled under 40 free bytes |
| S2 | DM Heard is not observable; DM Delivered = `0x82`. Channel Heard is observable via `0x88` LOG_RX (GRP_TXT, decryptable with the channel secret, same method as `wardrive_engine`) but **nothing emits `InboundRepeatHeard` today**; WP must wire it. | V + code read | DMs skip Heard; channels Heard once wired |
| S3 | Encoding proven in source: `byte = ((hash_size-1)<<6) \| hop_count`. Firmware stores the byte raw, no validation. Radio round trip pending. | V, radio DEFAULT | capability `setPath` OFF (R31) until `spike_radio_probe.py s3` passes |
| S4 | MMA is `REQ_TYPE_GET_AVG_MIN_MAX = 0x04`, **sensor firmware only**, needs login role >= READ_ONLY. Repeaters and companions do not answer. | V | MMA UI only for sensor-type contacts (`ADV_TYPE_SENSOR`) after login |
| S5 | `CupertinoSliverNavigationBar.search` + pinned segmented header works on 3.47.7: large title, search row, collapse to compact blurred bar, header pins. SE and landscape not run. | SIM (17 Pro) | no fallback needed on 17 Pro; SE/landscape on checklist |
| S6 | `CupertinoContextMenu.builder` on 500 rows (every 5th a 200-char bubble): scroll frame times identical to the same list without it (p50 20.4 vs 20.3 ms, p99 22.8 vs 22.9 ms, debug build). Long-press preview itself not gesture-driven. | SIM | context menu on rows and bubbles; action-sheet fallback if device long-press jank |
| S7 | Medium custom route renders (dim, 20 pt top corners, 0.45 height, grabber, text field). Large `showCupertinoSheet` renders as the native stacked page sheet (rounded top, previous page scaled back behind it, status bar black). Drag/keyboard behaviour not gesture-tested. | SIM | as plan: large = `showCupertinoSheet`, medium = custom route |
| S8 | Platform channel with `UINotificationFeedbackGenerator` compiles and answers from Dart (`true`). Feel is device only. | SIM | channel; fallback `HapticFeedback.heavyImpact` pair |
| S9 | **FAIL.** `.SF Pro Rounded`, `SF Pro Rounded` and `.SF Mono` all render as plain SF Pro (pixel diff vs `.SF Pro` = 0). `Menlo` works. | SIM | avatar initials = system semibold; monospace = `Menlo` |
| S10 | Flutter exposes `accessibilityFeatures.highContrast` (Darker System Colors) but **no Reduce Transparency**. A 10-line channel on `UIAccessibility.isReduceTransparencyEnabled` works (returned false). | SIM | WP0 adds `AppA11y` channel; opaque bars when it reports true or is absent |
| S11 | A companion **does not answer** `CMD 27` status (`onContactRequest` handles only `REQ_TYPE_GET_TELEMETRY_DATA`; `GET_STATUS` is repeater/room/sensor code). | V | user stats = telemetry-only; no status button on companions |
| S12 | `0x8D` layout read from source (below). Capture pending. | V, capture DEFAULT | parse per layout with length checks, unknown trailing bytes ignored; run `s12` to confirm |
| S13 | Firmware never resets a path on a failed send. Our outbox is the resetter (`outbox.dart` flood on last attempt + `resetContactPath`). The firmware also overwrites `out_path` on every received PATH packet. | V + code read, radio DEFAULT | capability `keepRoute` OFF until S3 passes; then outbox must skip the last-attempt flood for `path_mode = fixed` and rewrite the path before each send |
| S14 | **Do not export SF Symbols into an icon font or SVG.** Licence limits SF Symbols to UIs on Apple operating systems; an Android build and a redistributed font are outside it. | web, see below | `AppSymbol` backed by `CupertinoIcons` + open SVG set |

## S1 detail
`BaseChatMesh.h: MAX_TEXT_LEN = 160`. DM: `composeMsgPacket` returns NULL above 160 (and above 158 when `attempt > 3`, two tail bytes carry the attempt); the companion maps that to `ERR_CODE_TABLE_FULL` (misleading, show "message too long"). Channel: `sendGroupMessage` builds `"<node_name>: <text>"` and silently truncates the **tail** at 160 total (can cut a UTF-8 character). Command frame size: DM `1+1+1+4+6+160 = 173 <= MAX_FRAME_SIZE 176`. Radio check (checklist step 6) confirms the 161st byte is refused.

## S2 detail
`processAck` emits `0x82 SEND_CONFIRMED [ack 4][trip_ms 4]` only for the ack the radio expects. A flood DM that a repeater re-floods is heard by our radio only as an encrypted TXT_MSG on `0x88`; the phone cannot recompute the ciphertext, so no DM echo. Received V3 messages (`0x10`/`0x11`) carry SNR (x4) but **no RSSI** (two reserved zero bytes), so `messages.rssi` stays null unless correlated from `0x88` within 1 s (plan migration v3, already "best effort"). `path_len` in V3 frames is the packed byte; `InboundDirectText.hops = pathLen & 63` is right, and `hash_size = (pathLen >> 6) + 1` is available for the new column.

## S3 / S13 detail
`CMD_ADD_UPDATE_CONTACT` copies `out_path_len` and all 64 `out_path` bytes with no validity check (`updateContactFromFrame`), `CMD_RESET_PATH` sets `out_path_len = 0xFF`, flood is used exactly when it is `0xFF` (`sendMessage`). Valid per `Packet::isValidPathLen`: hash_size 1..3 (top bits `11` reserved), `count*size <= 64`. App side `pathByteLength` and `encodeAddUpdateContact` already match. `CMD_SET_PATH_HASH_MODE 61 [0][mode 0..2]` sets the hash size the radio uses for floods it originates.

## S4 detail
Request `CMD_SEND_BINARY_REQ 50 [pubkey 32][0x04][start_secs_ago u32 LE][end_secs_ago u32 LE][0][0]`; reply push `0x8C [0][tag u32][now u32]` then records `[channel][lpp_type][min][max][avg]` sized by the LPP type. Repeater firmware has types 1, 2, 3, 5, 6, 7 only.

## S12 detail
`CMD 52 [0][pubkey 32]` sends a flood telemetry request (`REQ_TYPE_GET_TELEMETRY_DATA`, base-permission mask, random blob); reply `RESP_CODE_SENT [flood][tag][est_timeout]`. Result push `0x8D [0][pubkey prefix 6][out_path_len][out_path][in_path_len][in_path]`, each length byte packed as above, telemetry discarded, path not stored. Only matches the pending tag; no timeout push exists, so "no answer" is the UI's own timer (`est_timeout`). Example frame in the fixture JSON.

## S9 / S10 / S8 prototype code
Swift (AppDelegate, implicit engine delegate): a `FlutterMethodChannel` returning `UIAccessibility.isReduceTransparencyEnabled` and calling `UINotificationFeedbackGenerator().notificationOccurred(.success/.warning/.error)`. Dart: `MethodChannel(...).invokeMethod('notify', 'success')`. Prototype lived in a throwaway Flutter project outside the repo and is deleted with the scratchpad; no prototype branch exists in any repo (the only branch, `spikes/wp13`, carries this doc, the fixture and the probe script).

## S14 licence verdict
- Text verified: the SF Symbols licence opens with "THE APPLE SOFTWARE IS TO BE USED SOLELY FOR CREATING USER INTERFACES TO BE USED IN SOFTWARE PRODUCTS RUNNING ON APPLE'S iOS, iPadOS, macOS, tvOS OR watchOS OPERATING SYSTEMS ... SUBJECT TO THE SPECIFIC USE RESTRICTIONS SET FORTH HEREIN" (quoted on developer.apple.com/forums/thread/739523; watchOS/visionOS wording varies). Also quoted there: symbols or confusingly similar glyphs may not be used in app icons, logos or trademark uses, and Apple may require modification or discontinuance. I could not retrieve the full agreement (the PDF URL 404s, the app is not installed on this Mac), so the redistribution/derivative clauses are unread.
- Consequence: SVGs/fonts exported from SF Symbols would ship inside the Android and desktop builds, which the licence does not cover, and a redistributed icon font is the embedding case the "SF is never bundled" rule (D46) already forbids for SF Pro. Verdict: do not build `AppSymbols` from SF exports.
- Decision (default 5.4): `AppSymbol` widget with a manifest mapping each wireframe glyph to (a) `CupertinoIcons` (MIT, bundled with Flutter's cupertino_icons) where a glyph exists, else (b) an open SVG set: Lucide (ISC) first, Phosphor or Tabler (MIT) for gaps. Manifest records source and licence per glyph. Optional later, iOS only: render real system symbols via `UIImage(systemName:)` through a channel (inside the licence, Apple OS).
- `cupertino_icons` must be a dependency (the prototype without it showed a "?" box in the search field).

## Andy's radio checklist (about 25 minutes, second radio plus one contact that can go offline)
Setup (once): `python3 -m venv v && v/bin/pip install bleak`; close the MeshSonar app (one BLE client at a time); put the radio within range; `v/bin/python scripts/spike_radio_probe.py scan` and note the radio's address.
1. `contacts <addr>` : pick a repeater/companion contact name prefix `<n>`.
2. `s3 <addr> <n>` : writes 1-, 2-, 3-byte-hash 2-hop paths, reads each back, resets, restores. Expect `read == wrote` for all three. Any mismatch: leave `setPath` OFF and send me the capture.
3. `s12 <addr> <n>` : expect the SENT frame then a `0x8D` line within about 30 s (contact must be in range).
4. `s13 <addr> <n>` : use a contact that is switched off. Expect `path_len` to stay `0x2` after each attempt (the firmware does not reset it).
5. `s11 <addr> <companion-n>` : companion contact; expect "NONE in 30 s".
6. `s1 <addr> <n>` : expect SENT for 160 bytes and an `ERR` frame (`01 03`) for 161.
Each step writes `chat-spike-capture-<step>.json`; copy them into `meshsonar/test/fixtures/chat/`. Steps 2 and 4 modify one contact's saved route on the radio and restore it; if a script dies midway re-add the contact from the app.
Device checks (Andy A-series): haptic feel of the notification channel (S8), long-press preview feel (S6), medium sheet drag and keyboard on a real phone and SE (S7), Reduce Transparency toggle with the channel (S10).
