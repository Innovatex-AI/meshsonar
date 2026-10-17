# MeshMapper app: capture behaviour we learn from

Study notes for milestone M0. They record **what MeshMapper's phone app does**, cited to file and line, so
MeshSonar can decide what to match and what to do better. **We do not copy MeshMapper code or its on-air format.**
MeshSonar uses its own Ping Standard (plan D2). MeshMapper's app is MIT-licensed; these notes describe behaviour
in our own words.

**Sources** (read-only clones, read Oct 17 2026; never run):

| Prefix | Repository | Commit |
|---|---|---|
| `MMA/` | MeshMapper/MeshMapper_Flutter_App, under `lib/` | `3b5b5af` |
| `MMW/` | MeshMapper/MeshMapper_Wiki, under `docs/` | `83c74c7` |
| `MC/` | meshcore-dev/MeshCore firmware | `81dbae59` (v1.18.0) |

A citation is `file:line` or `file:first–last`. **"Inferred"** marks anything that is not stated in code or docs.
MeshMapper's server is closed source, so every server-side behaviour below is either documented in the wiki or
inferred from what the app expects.

---

## 1. On-air TX ping and the wire tag (study only)

| Item | MeshMapper behaviour | Source |
|---|---|---|
| Channel | Group text (GRP_TXT) on `#wardriving`. Key = first 16 bytes of SHA-256("#wardriving"), AES-128-ECB by the radio | `MMW/app_how_it_works.md:36–38` |
| Body | `MM:` + wire tag (13 characters). With "Broadcast My Coordinates" on: `MM:<tag>:lat,lon` (5 decimals) | `MMA/services/ping_service.dart:991–1020`; `MMA/services/meshcore/wire_tag_codec.dart:9`, `:35` |
| Tag layout | 55 bits, MSB→LSB: region (15) \| date (15) \| session number (14) \| counter (11). Date = (year−2020)×512 + month×32 + day. Region = 3 letters base 26 | `wire_tag_codec.dart:14–15`, `:43–53`, `:138–144` |
| Encryption | Keyed 4-round balanced Feistel on two 28-bit halves; round function = first 4 bytes of SHA-256(secret ‖ round ‖ half), masked to 28 bits. Output 7 bytes, base64url without padding | `wire_tag_codec.dart:58–92`, `:94–116`, `:146–147` |
| Key | Per-session `wire_key` from the server's `/auth` reply. Null key falls back to an unkeyed tag | `MMA/services/api_service.dart:908`; `wire_tag_codec.dart:121–123` |
| Session id | `IATA-YYYYMMDD-NNNN`; offline sessions are never tagged | `wire_tag_codec.dart:121–133` |
| Counter cap | 2047 pings per session (11-bit counter); at the cap the app uploads and disconnects | `ping_service.dart:1003–1013`; `MMW/app_how_it_works.md:52` |
| No session, no ping | A TX without a session is refused (every TX carries a tag) | `ping_service.dart:1021–1029` |
| Why | Lets the server recognise the same packet at an observer without putting the driver's position on air | `MMW/app_how_it_works.md:330` |

**For us:** we keep the idea (an opaque per-session tag the server can resolve, no position on air) and design our
own encoding in the M1 spec. Two lessons from their code: the date had to go into the tag so a recycled daily
session number does not collide ("green TX → DEAD tile" fix, `wire_tag_codec.dart:15–18`), and a tag is only valid
under the session that minted it, so queued tagged items are dropped, not re-tagged, after a session change
(`MMA/services/api_queue_service.dart:1580–1592`, `MMA/models/api_queue_item.dart:522–531`).

## 2. Listening windows

| Window | Value | Source |
|---|---|---|
| TX echo window | **5 s** (`_rxListeningWindow`), passed to the TX tracker | `ping_service.dart:51`, `:1151` |
| TX tracker default | 5 s in code; its doc comment wrongly says 7 s | `MMA/services/meshcore/tx_tracker.dart:63`, `:69` |
| DISC window | **7 s** (`_discoveryListeningWindow`) | `ping_service.dart:57`, `:2160`; `MMA/services/meshcore/disc_tracker.dart:68`; `MMW/app_how_it_works.md:100` |
| Trace window | 5 s (reuses the TX window; the trace tracker's 7 s default is overridden) | `ping_service.dart:2661`; `MMA/services/meshcore/trace_tracker.dart:52` |
| Auto-ping cooldown | 5 s between auto pings, and a stop of Active/Hybrid is blocked for 5 s after a ping | `ping_service.dart:54`, `:616–623`, `:1697–1703`; `MMW/app_wardriving_modes.md:187` |
| Manual cooldown | 15 s | `ping_service.dart:63`; `MMW/app_wardriving_modes.md:15`, `:22` |

The class comment at `ping_service.dart:44–48` says discovery uses a 5 s window; the constant (`:57`) and its use
(`:2160`) are 7 s. Trust the code.

## 3. TX echo validation (during the 5 s window)

Order of checks in `MMA/services/meshcore/tx_tracker.dart:121–379`. A packet counts as an echo only if every check
passes.

| # | Check | Lines |
|---|---|---|
| 1 | Payload type is GRP_TXT | `:131–136` |
| 2 | Path length > 0 | `:140–145` |
| 3 | Own CARpeater on the **first** hop: single hop → dropped; else that hop is stripped, the next hop is credited, SNR/RSSI set to null | `:148–169` |
| 4 | Multi-hop (2+ hops, not stripped): credited to the **last** hop, kept separately with the full hop list | `:171–185` |
| 5 | Regional CARpeater list: drop if the credited hop **or** the first hop is listed | `:187–200` |
| 6 | User's ignore filter | `:202–209` |
| 7 | RSSI failsafe: drop if RSSI ≥ −30 dBm (skipped after a CARpeater strip, or if the user turned it off) | `:211–229` |
| 8 | Channel hash equals `#wardriving`'s (payload ≥ 3 bytes) | `:231–246` |
| 9 | Decrypted text equals, or contains, the body just sent | `:250–304` |
| 10 | Dedup per repeater: keep the best SNR, count repeats | `:321–361` |

After the window: direct (1-hop) echoes become the TX item's `heard_repeats`, formatted `id(snr),id(snr)` with SNR to
2 decimals, or `id(null)` after a CARpeater strip, or `None` (`ping_service.dart:1245–1270`). Multi-hop echoes are
uploaded as separate RX items at the ping's location (`ping_service.dart:1286–1300`; `MMW/app_how_it_works.md:48`).

## 4. Passive RX pipeline and batching

Runs only while an auto mode runs; with no auto mode only the echoes of a manual ping are used
(`MMW/app_how_it_works.md:65`). Code: `MMA/services/meshcore/rx_logger.dart` and
`MMA/services/meshcore/packet_validator.dart`.

### 4.1 Validation (in order)

| # | Check | Source |
|---|---|---|
| 1 | Path length > 0 | `rx_logger.dart:92–96` |
| 2 | Not direct-routed (a direct packet's path is the route still ahead, not who you heard) | `rx_logger.dart:103–108` |
| 3 | Own CARpeater on the **last** hop: single hop → dropped; else credit the second-to-last hop, SNR/RSSI null | `rx_logger.dart:116–135` |
| 4 | Regional CARpeater → dropped | `rx_logger.dart:140–143` |
| 5 | No GPS fix → dropped (user notified at most every 30 s) | `rx_logger.dart:146–158` |
| 6 | User ignore filter | `rx_logger.dart:164–170` |
| 7 | RSSI failsafe ≥ −30 dBm → dropped, unless stripped or switched off | `packet_validator.dart:14`, `:48–62`, `:185–187` |
| 8 | Only GRP_TXT or ADVERT | `packet_validator.dart:64–73` |
| 9 | GRP_TXT: payload ≥ 3 bytes, channel hash in the allowed list (Public, #wardriving, region channels) | `packet_validator.dart:85–105`; `MMW/app_how_it_works.md:211–215` |
| 10 | GRP_TXT: decrypted ≥ 5 bytes (4 timestamp + 1 flags), then ≥ 60 % printable ASCII | `packet_validator.dart:19`, `:107–158`, `:202–214` |
| 11 | ADVERT: name flag set, name non-empty and ≥ 60 % printable | `packet_validator.dart:218–313` |

### 4.2 Batching

| Rule | Value | Source |
|---|---|---|
| Key | Repeater id (the credited hop) | `rx_logger.dart:273–295` |
| Kept reading | Best SNR only; a reading with SNR beats one without | `rx_logger.dart:308–336` |
| Location | **Pinned to where the repeater was first heard**, even when a later reading wins | `rx_logger.dart:318–326` |
| Flush on distance | 25 m from the first location, checked on each packet and on every GPS fix (fixes arrive every 10 m) | `rx_logger.dart:19`, `:340–355`, `:362–405`; `MMA/services/gps_service.dart:457–458` |
| Flush on time | 30 s after the first reading | `rx_logger.dart:20`, `:300–303` |
| Speed term | **None.** Both limits are fixed constants | `rx_logger.dart:19–20` |
| Session end | All batches flushed on stop or disconnect | `rx_logger.dart:73–77`, `:451–467` |
| Upload-queue cap | At most **4 RX items per repeater** buffered before they move to the main queue; extras dropped | `api_queue_service.dart:275`, `:690–698`, `:1060–1068` |

**For us:** best-SNR-only and first-location pinning lose information at speed (teardown §3.4). We keep all readings
or n/min/median/max per batch (M4 spec).

## 5. CARpeater rules

| Rule | Behaviour | Source |
|---|---|---|
| RSSI failsafe | RSSI ≥ −30 dBm is treated as a vehicle repeater and dropped, on TX echoes, RX and DISC replies | `packet_validator.dart:11–14`, `:185–187`; `tx_tracker.dart:217`; `disc_tracker.dart:200–210` |
| Failsafe off switch | User setting "Disable RSSI Filter" | `packet_validator.dart:24–25`; `ping_service.dart:101–102`; `MMW/app_how_it_works.md:198–203` |
| Own CARpeater | Stored as the full 64-hex key; hops compared on the shorter length (1–4 bytes) | `packet_validator.dart:189–199` |
| Own CARpeater on TX echo | Matched on the **first** hop (our ping reached our car first) | `tx_tracker.dart:150–169` |
| Own CARpeater on RX | Matched on the **last** hop (our car delivered it to us) | `rx_logger.dart:116–135`; `MMW/app_how_it_works.md:191–193` |
| Own CARpeater, single hop | Dropped (only our own car heard it) | `tx_tracker.dart:157–160`; `rx_logger.dart:122–125` |
| Regional CARpeaters | Admin-shared list; always a plain drop, nothing behind them is credited; DISC matches on the full key | `tx_tracker.dart:187–200`; `rx_logger.dart:140–143`; `disc_tracker.dart:186–191`; `MMW/app_how_it_works.md:285` |
| Regional list expiry | 90 days without reports | teardown §3.5 (wiki admin docs; not re-checked in this pass) |

## 6. Discovery (DISC) and trace commands

### 6.1 Discovery request (companion command)

Built in `MMA/services/meshcore/connection.dart:2877–2904`.

| Byte | Value | Meaning |
|---|---|---|
| 0 | `0x37` (55) | `CMD_SEND_CONTROL_DATA` |
| 1 | `0x80` | `DISCOVER_REQ`, prefix-only bit clear (full key wanted) |
| 2 | `0x06` | Type filter. Bit 2 (`1 << ADV_TYPE_REPEATER`) is the one repeaters test |
| 3–6 | random | 4-byte tag (`Random.secure`) |
| 7–10 | `0` (u32 LE) | "since" timestamp; 0 = everyone answers |

The code comment at `connection.dart:2894` says the filter is `0x0C`; the constant is `0x06`
(`MMA/services/meshcore/protocol_constants.dart:216–217`).

### 6.2 What the repeater does (firmware)

From `MC/examples/simple_repeater/MyMesh.cpp:786–817`:

- Answers only if forwarding is on, the node is not hidden, the rate limiter allows it, the filter has the repeater
  bit, and its `discovery_mod_timestamp` ≥ "since".
- Rate limit: **4 replies per 120 s** per repeater (`MyMesh.cpp:868`).
- Reply payload: `0x90 | ADV_TYPE_REPEATER`, inbound SNR × 4, the request's tag, then the 32-byte public key (8 bytes
  if prefix-only). Sent zero-hop after a random delay widened ×4.
- Only `simple_repeater` (type 2) and `simple_sensor` (type 4) implement replies in this firmware; room servers do
  not.

### 6.3 Reading the reply (app)

The companion pushes `0x8E PUSH_CODE_CONTROL_DATA`: SNR×4, RSSI, path length, then the payload
(`MC/examples/companion_radio/MyMesh.cpp:816–821`). MeshMapper parses it in `disc_tracker.dart:127–271`:

| Step | Behaviour | Lines |
|---|---|---|
| Length | ≥ 39 bytes | `:131–135` |
| Type | Upper nibble `0x90`; lower nibble must be `0x02` or `0x04` | `:137–155` |
| Remote SNR | Signed byte ÷ 4 | `:157–159` |
| Tag | **Any tag is accepted** (another phone's sweep counts). Only our own tag gets a reply time | `:161–174` |
| Id | First 1–3 bytes of the key, following the user's TX-bytes setting | `:176–184` |
| Filters | Regional CARpeater (full key), user ignore list, RSSI failsafe | `:186–210` |
| Dedup | Best local SNR per id; reply time kept only within the same full key | `:220–260` |

Inferred: MeshMapper labels lower nibble `0x04` "ROOM" (`protocol_constants.dart:220–221`), but in the firmware
4 is `ADV_TYPE_SENSOR` and room servers (type 3) do not answer (`MC/src/helpers/AdvertDataHelpers.h:7–11`). Since the
request filter `0x06` lacks bit 4, sensors should not answer either, so in practice only repeaters reply.

### 6.4 Trace request

`connection.dart:2909–2946`: `0x24` (`CMD_SEND_TRACE_PATH`), 4-byte random tag, u32 auth code 0, flags (path size
code in bits 0–1: 1 byte → 0, 2 → 1, 4 → 2), then the target repeater id. The reply is `0x89 PUSH_CODE_TRACE_DATA`;
the tracker checks the tag, reads the first hop and the per-hop SNR bytes (signed, ÷ 4): first = remote SNR, second
= local SNR (`trace_tracker.dart:95–176`). Only answered traces are uploaded; failures stay local
(`MMW/app_how_it_works.md:105–111`).

### 6.5 Upload items (study only)

`MMA/models/api_queue_item.dart:402–520`, sent as `{"key", "session_id", "data": [...]}` to
`/wardrive-api.php/wardrive` (`api_service.dart:115`, `:1143–1146`).

| Type | Fields |
|---|---|
| TX | type, lat, lon, noisefloor, heard_repeats, timestamp (unix s), external_antenna, power (`"0.3w"`), ping_counter, wire_tag, altitude/altitude_ref/altitude_acc, auto_mode, radio_freq |
| RX | same shape as TX without the tag fields; `heard_repeats` holds one repeater |
| DISC | type, lat, lon, noisefloor, repeater_id, node_type, local_snr, local_rssi, remote_snr, public_key, timestamp, external_antenna, power, altitude…, auto_mode, radio_freq |
| DISC (no reply) | `repeater_id: "None"`; sent only when the region turns on "Discovery Drop" (`disc_drop`) |
| TRACE | type, lat, lon, noisefloor, repeater_id, local_snr, local_rssi, remote_snr, timestamp, … |
| DEFER | type, lat, lon, timestamp, held (`tx`/`disc`), radio_freq |
| SCOPES | type, public_key, scopes, timestamp, lat, lon, radio_freq |

Discovery Drop: `ping_service.dart:2270–2280`, `api_queue_item.dart:459–475`, `api_service.dart:946`.

## 7. Modes and Hybrid timing

| Mode | Behaviour | Source |
|---|---|---|
| Intervals | 15, 30 or 60 s; anything else falls back to 30 s; default 30 s | `ping_service.dart:173–175`, `:518–528` |
| Hybrid start | Always starts with a DISC | `ping_service.dart:149`, `:1568` |
| Hybrid alternation | Strict: each timer fire sends the pending leg, then flips DISC ↔ TX | `ping_service.dart:2438–2445` |
| Hybrid spacing | Start-to-start: wait = interval − that leg's window (7 s DISC, 5 s TX), floor 1 s | `ping_service.dart:2397–2403` |
| Hybrid TX rate | One TX every 2 × interval | follows from the two rows above; `MMW/app_settings_reference.md:162` |
| Busy | A fire while a ping is in progress is skipped | `ping_service.dart:2432–2435` |
| Passive | DISC only, fixed 30 s, chosen because repeaters answer 4 per 2 min | `ping_service.dart:59–60`, `:2361–2386`; `MMW/app_wardriving_modes.md:67` |
| Trace (targeted) | One trace per interval to one repeater | `ping_service.dart:2760–2787`; `MMW/app_wardriving_modes.md:107–110` |
| Region overrides | `/auth` can enforce Hybrid, a minimum interval, Discovery Drop, flood-off, hop bytes, Smart Ping on and its window | `api_service.dart:877–990` (`enforce_hybrid` `:940`, `disc_drop` `:946`, `flood_disabled` `:952`, `min_mode_interval` `:958`, `hop_bytes` `:967`, `smart_ping` `:980`) |

Hybrid at a 15 s interval sends one DISC every 30 s, exactly the 4-per-120 s repeater budget (plan §14.2).

## 8. Smart Pinging and the deferred ping

| Rule | Behaviour | Source |
|---|---|---|
| Applies to | Auto TX and auto DISC only. Manual, trace and RX are never deferred | `ping_service.dart:600–609`, `:2100–2112`; `MMW/app_how_it_works.md:125–126` |
| "Covered" | Square has a BIDIR (green) or DISC/TRACE (cyan) result within the window | `MMA/services/recent_coverage_service.dart:287–296`; `MMW/app_how_it_works.md:119` |
| Window | Default **14 days**, range 1–365 | `MMA/models/user_preferences.dart:670–673` |
| Tiles | z13 vector tiles; everything within **500 m** kept loaded; re-evaluated after **100 m** of movement; tiles refreshed after **5 min**; failed fetch retried after 30 s | `recent_coverage_service.dart:26`, `:30`, `:33`, `:36`, `:39` |
| Square size | The user's grid (300 m, or 100 m in Detailed) | `MMW/app_how_it_works.md:120` |
| Order | Covered check runs **before** the 25 m rule, so a parked phone reads "Deferred", not "Skipped" | `ping_service.dart:600–614` |
| Bank | One slot; a later deferral replaces it | `ping_service.dart:180–185`, `:953`, `:2104` |
| Release | On a GPS fix in a clear square that also satisfies the minimum distance; cancels the timer and sends; Hybrid alternation is re-pinned | `ping_service.dart:432–512` |
| Fail open | Only a definite "covered" defers; "unknown" (no tile, fetch failed, offline) sends normally | `ping_service.dart:456–463`; `MMW/app_how_it_works.md:122` |
| Airborne | Bank never released while airborne | `ping_service.dart:449–454` |
| DEFER item | One per **fixed 300 m square per session**; the server verifies and credits **1.5 points** | `MMA/providers/app_state_provider.dart:5436–5440`; `api_queue_item.dart:419–433`; `MMW/app_how_it_works.md:123`; `MMW/leaderboards.md:22`, `:37` |

## 9. Upload queue, batching and retries

| Rule | Value | Source |
|---|---|---|
| Store | Hive box `api_queue`; in-memory fallback if Hive fails | `api_queue_service.dart:265`, `:296`; `MMW/app_how_it_works.md:266` |
| Batch size | 50 items | `api_queue_service.dart:266` |
| Timer | 15 s (60 s on a constrained link, e.g. satellite) | `api_queue_service.dart:267–271` |
| After a TX/DISC/TRACE/DEFER/SCOPES | Flush in 5 s (60 s constrained) | `api_queue_service.dart:272–273`; `MMW/app_how_it_works.md:267` |
| Retries | 5 per item | `api_queue_service.dart:274`, `:1197`, `:1205` |
| Backoff | `2^retryCount` seconds, clamped 1–60 s. With 5 retries the ladder stops at 16–32 s; the 60 s cap is never reached | `MMA/models/api_queue_item.dart:533–544` |
| Unreachable / server says wait | Batch held, no retry spent | `api_queue_service.dart:1315–1330`; `MMW/app_how_it_works.md:269` |
| Data errors (dropped) | `gps_inaccurate`, `gps_stale`, `invalid_request`, `zone_disabled`, `outofdate`; `outside_zone` dropped but session kept | `api_service.dart:2071–2093` |
| Session errors (disconnect) | `session_expired` (refresh first), `session_invalid`, `session_revoked`, `bad_session`, `invalid_key`, `unauthorized`, `bad_key`, `zone_full`, `zone_disabled` | `api_service.dart:2033–2069` |
| Connect/disconnect | Queue cleared on connect; best-effort upload then clear on disconnect; kept across auto-reconnect | `MMW/app_how_it_works.md:272` |
| Third-party forward (not used by us, M3 removed) | Phone POSTs `{"data": [...]}` with `X-API-Key`, 10 s timeout, error log throttled 1/min, no retry; adds `contact` (first 8 hex of companion key, opt-in, default on) and `iata` | `MMA/services/custom_api_service.dart:19`, `:26–27`, `:71–98`, `:114–121`; `user_preferences.dart:219`; `app_state_provider.dart:3482–3486` |

## 10. Noise floor

| Rule | Value | Source |
|---|---|---|
| Poll | Every **5 s** from connect, via `CMD_GET_STATS` (radio) | `connection.dart:654`, `:3421–3442`; `MMW/app_how_it_works.md:254` |
| Backoff | **30 s** after **3** consecutive failures; reset on success | `connection.dart:650`, `:660`, `:3499`, `:3514–3519` |
| Paused | While a repeater-admin command or scope lease holds the radio | `connection.dart:3475–3479` |
| Upload | On every TX, RX, DISC and TRACE item | `api_queue_item.dart:444`, `:466`, `:483`, `:504`; `MMW/app_how_it_works.md:255` |
| Baseline (server) | Per companion, **10th percentile** of its readings once it has **≥ 5**; map shows reading − baseline ("noise delta") | `MMW/layers.md:60–62`; `MMW/app_how_it_works.md:258`. Not in app code: server-side |

## 11. GPS gates

| Gate | Value | Source |
|---|---|---|
| Accuracy for a ping | ≤ **100 m** (auto and manual) | `gps_service.dart:61`, `:571–574`; `ping_service.dart:588–596` |
| Accuracy for zone checks and API calls | ≤ **50 m** | `gps_service.dart:65`, `:577–580`; `app_state_provider.dart:10519–10520` |
| Stale fix | **60 s** max age for API calls and the zone-check fix | `gps_service.dart:57`, `:646–656`; `app_state_provider.dart:10516–10517`, `:10560` |
| Stale fix on the ping path | **Not age-gated.** Each auto TX, DISC and trace takes a fresh fix first (3 s timeout); `canPing()` notes the freshness check was removed. `validatePositionForPing()` (`gps_service.dart:583–598`) has no callers (inferred from a full-tree search). The server can still reject a batch as `gps_stale` | `ping_service.dart:585–586`, `:848–853`, `:2020`, `:2549`; `gps_service.dart:692–693`; `api_service.dart:2084` |
| Airborne | A fix is "airborne" if (altitude − vertical accuracy) > **6,000 m** and speed is unknown or ≥ **150 km/h**, or speed > **250 km/h**. **3** airborne fixes in a row set the latch, 3 ground fixes clear it. Unknown values never qualify (fail open) | `gps_service.dart:66–87`, `:202–222`, `:230–268` |
| Airborne effect | Pings refused; the provider ends the session | `ping_service.dart:579–583` |
| Minimum distance | **25 m** floor (user may raise it), auto modes only; manual pings have none | `gps_service.dart:53`, `:89–98`; `ping_service.dart:611–614`, `:628–630`; `MMW/app_wardriving_modes.md:15` |
| Idle auto-stop | Auto mode stops after **30 min** without leaving a **150 m** circle on **3** fixes in a row (mirrors the server's stationary guard) | `app_state_provider.dart:403–412`, `:8311–8378`; `MMW/app_wardriving_modes.md:188` |
| Idle disconnect | Connected but no manual ping or auto mode for **15 min** → disconnect | `app_state_provider.dart:734–735`, `:6764–6777` |
| Location stream | Fix every 10 m of movement, high accuracy | `gps_service.dart:452–458` |

---

## 12. Status codes 0–7

What each `status` integer in MeshMapper's coverage data means, and how sure we are.

| Code | Type | Meaning | Confirmed by | Still inferred |
|---|---|---|---|---|
| 0 | DROP | No repeat heard and the ping never reached an observer | `MMW/dataupload.md:33`; `MMW/visuals.md:43–44`; app treats 0 as drop/skip (`MMA/utils/coverage_summary.dart:619`, `:826`) | — |
| 1 | BIDIR | Repeat heard **and** reached an observer | `MMW/dataupload.md:34`; `MMW/visuals.md:31–32`; `coverage_summary.dart:12`, `:608–609` | — |
| 2 | TX | Reached an observer, no repeat heard back | `MMW/dataupload.md:35`; `MMW/visuals.md:37–38`; `coverage_summary.dart:610–611` | — |
| 3 | DEAD | A repeat was heard (a repeater relayed it) but **no observer** received it | `MMW/dataupload.md:36`; `MMW/visuals.md:41–42`; ping-type diagram `MMW/assets/ping-types.svg` ("Repeat heard, but it never reached an observer"); `coverage_summary.dart:616–617` | — |
| 4 | WAIT (pending) | Server-side pending TX row that a wire-tagged ping joins; never drawn | App comments: "no status-4 WAIT row to join, so it inserts as DEAD(3)" (`MMA/services/api_queue_service.dart:1588–1589`; `MMA/models/api_queue_item.dart:528–529`). Wiki: "Pending pings (status 4) are left out entirely" (`MMW/coverage-api.md:147`). Absent from the status list in `MMW/dataupload.md:33–39` | **How** the server creates and resolves the row (when it is written, how long it waits, how it becomes 1/2/3/0) is closed-source. Inferred: the row is written when the TX upload arrives and is resolved by the observer join |
| 5 | RX | Passive: heard traffic without transmitting | `MMW/dataupload.md:37`; `MMW/visuals.md:39–40`; `coverage_summary.dart:12`, `:612–613` | — |
| 6 | DISC | Discovery request answered | `MMW/dataupload.md:38`; DISC rows carry `public_key` (`coverage_summary.dart:645`, `:830`) | — |
| 7 | TRACE | Targeted trace answered; drawn the same as DISC | `MMW/dataupload.md:39`; `MMW/visuals.md:35–36`; `coverage_summary.dart:191`, `:614` (6 and 7 both cyan) | — |

**3 vs 5, settled.** They look alike in raw rows (one heard repeat, no observer route) but come from different
actions: **3 is a transmitted ping** whose repeat you heard but no observer logged (an isolated repeater island);
**5 is passive listening**, no transmission at all. The app comment above confirms the TX path can end as DEAD(3).
In our data the difference must come from the item type, not the heard set.

Two other enumerations exist and must not be confused with `status`:

| Enumeration | Values | Source |
|---|---|---|
| Vector-tile `st` (display priority, lower wins) | 1 green BIDIR, 2 cyan DISC/TRACE, 3 orange TX, 4 purple RX, 5 grey DEAD, 6 red DROP | `MMA/utils/coverage_tile_palette.dart:11–13`; `coverage_summary.dart:176–194` |
| Coverage API `status_mask` bits | BIDIR 1, TX 2, RX 4, DISC 8, DEAD 16, DROP 32 | `MMW/coverage-api.md:176–181` (bits at `:181`) |

The Coverage API also splits BIDIR by whether a repeat was heard: "BIDIR with a heard repeat" ranks first, "BIDIR with
no heard repeat" ranks fifth (`MMW/coverage-api.md:149–157`; `coverage_summary.dart:186–192`). Inferred: status 1 can
be stored without a heard repeat (for example a DISC-confirmed or observer-only path), so "1" alone does not prove
the driver heard a repeat.

---

## 13. Differences from the plan's earlier notes

| Plan / teardown said | Source says | Action |
|---|---|---|
| Stale GPS 60 s, "checked at `gps_service.dart:565–567`" for pings | The 60 s check exists but the ping path does not call it; auto pings take a fresh fix instead. 60 s applies to API/zone calls | Our 60 s ping gate stays (our choice); cite as "MeshMapper: fresh fix per ping, 60 s for API" |
| Upload backoff "1 → 60 s" | Formula clamps at 60 s, but 5 retries stop at 16–32 s | Ours: backoff 1 → 60 s and never drop (phone keeps pings), unchanged |
| DISC replies from "repeaters and room servers" (`MMW/app_how_it_works.md:96`) | Room servers do not implement DISCOVER replies in MeshCore v1.18.0 | Treat DISC as repeater-only |
| `tx_tracker.dart:63` says 7 s | Code default 5 s (`:69`) | Already noted in §14.1 |
