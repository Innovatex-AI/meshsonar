# Observer firmware MQTT: what CMAT's broker and ingest must accept

Study notes for milestone M0 (plan §4, M0 and M2). They describe what a MeshCore **observer** publishes over MQTT,
so CMAT can run its own broker at `mqtt.meshsonar.com` and ingest packets and status. Everything is cited to file
and line in read-only clones (never run).

| Prefix | Repository | Commit |
|---|---|---|
| `OBS/` | agessaman/MeshCore, branch `observer-firmware` (MQTT observer firmware) | `a714b38` (v1.18.0) |
| `BRK/` | michaelhart/meshcore-mqtt-broker (reference broker) | `4c0496b` |
| `DEC/` | @michaelhart/meshcore-decoder (token verifier used by the broker) | 0.3.0, `package/src/` |
| `M2M/` | Cisien/meshcoretomqtt (Raspberry Pi / serial bridge) | `9b4e022` |
| `M2Mt/` | tbaumann/meshcoretomqtt (older single-file fork) | `8514399` |

"Doc" = `OBS/MQTT_IMPLEMENTATION.md`. Where the doc and the code differ, the code wins and the difference is noted.
**"Inferred"** marks anything not stated in code or docs.

---

## 1. Slots and memory

| Item | Value | Source |
|---|---|---|
| Slots | 6 configurable (`mqtt1`…`mqtt6`), each holds one preset, `custom` or `none` | `OBS/src/helpers/MQTTPresets.h:8`; Doc `:107`, `:116–169` |
| Defaults | Slot 1 `analyzer-us`, slot 2 `analyzer-eu`, slots 3–6 `none` | Doc `:177`, `:334–336` |
| With PSRAM | All 6 slots can run | Doc `:179`; `MQTTPresets.h:13–14` |
| Without PSRAM | Only **3 runtime slots** exist, and at most **2 TLS/WSS** connections (~40 KB internal heap each) | `MQTTPresets.h:10–17`; Doc `:180` |
| Classic ESP32 T-LoRa V2.1–1.6 | Treat as **one** WSS broker | Doc `:240` |
| Heltec V4 | Has PSRAM (`-DBOARD_HAS_PSRAM`; 2 MB, or 8 MB on the r8) | `OBS/boards/heltec_v4.json:10`, `:31`; `OBS/boards/heltec_v4_r8.json:10`, `:31` |
| Packet queue while a broker is down | 50 packets (PSRAM) or 6 (no PSRAM); queued packets older than 5 min are stale | `OBS/src/helpers/bridges/MQTTBridge.h:242–248`; `OBS/src/helpers/MQTTPacketQueuePolicy.h:12` |
| Duplicate presets | A built-in preset cannot be on two slots | `OBS/src/helpers/CommonCLI_Observer.cpp:506` (reply "already assigned to slot") |

**Board type (plan M0 task, Q4.12).** If Andy's "V4" is a Heltec V4, it has PSRAM, so all 6 slots are available and
analyzer-eu does **not** need to be dropped. Inferred until confirmed on the device: `get mqtt.status` lists every
slot and marks the ones a board cannot run as `(inactive)` (Doc `:181`).

## 2. Transports and TLS

| Scheme | Meaning | Source |
|---|---|---|
| `wss://` | MQTT over WebSocket Secure | Doc `:171–173` |
| `mqtts://` | MQTT over TLS | Doc `:171–173` |
| `mqtt://`, `ws://` | Plain; no certificate check | Doc `:171–173`, `:483–488` |
| URL forms | Full URL with scheme in `mqttN.server`; an explicit port in the URL wins. With no port in the URL, a set `mqttN.port` is inserted before the path; with neither, the scheme default applies. The path (e.g. `/mqtt`) is kept | `OBS/src/helpers/bridges/MQTTBridge.cpp:2076–2111` (port insertion `:2102–2110`); Doc `:495–497` |
| Host only | Scheme picked from the port: 8883 → mqtts, 443 → wss, else mqtt | `MQTTBridge.cpp:2112–2119` |
| Custom-slot trust | Verified against the firmware's **embedded CA bundle** (no pinning). Built-in presets pin a root (e.g. ISRG Root X1, GTS Root R4) | `MQTTBridge.cpp:2125–2158`; `MQTTPresets.h:139–141` |
| Field limits | `mqttN.server` 63 chars, `mqttN.audience` 63, `mqttN.topic` 95 | `OBS/src/helpers/MQTTPrefsStorage.h:85`, `:94–95` |

Inferred: a Cloudflare-fronted `mqtt.meshsonar.com` chains to a public root in the bundle, so no extra certificate
step is needed. Verify on the first device connection (`get mqtt3.diag`).

## 3. Token auth (exact format)

Used by JWT presets and by a `custom` slot once `mqttN.audience` is set (Doc `:470–481`).

| Part | Value | Source |
|---|---|---|
| MQTT username | `v1_` + device public key, 64 **uppercase** hex | `MQTTBridge.cpp:2961–2965`; `OBS/src/Utils.cpp:177–187`; Doc `:921` |
| MQTT password | The token below | Doc `:478–479` |
| Token shape | `base64url(header) . base64url(payload) . HEX(signature)` — three dot-separated parts; base64url **without padding**; signature is **128 uppercase hex chars**, not base64 | `OBS/src/helpers/JWTHelper.cpp:57–112`, `:115–142` |
| Header JSON | `{"alg":"Ed25519","typ":"JWT"}` | `JWTHelper.cpp:144–157` |
| Payload JSON, in order | `publicKey` (64 uppercase hex), `aud` (the audience string), `iat` (unix s), `exp` (= iat + lifetime, omitted if lifetime 0), then optional `owner` (64 uppercase hex, from `set mqtt.owner`), `client` (`meshcore/<firmware version>`), `email` (from `set mqtt.email`) | `JWTHelper.cpp:159–202`; `MQTTBridge.cpp:2967–2991`, `:5118–5123` |
| Signed bytes | The ASCII text `base64url(header).base64url(payload)` | `JWTHelper.cpp:57–66`, `:82` |
| Algorithm | Ed25519 with the node's own identity key; verified locally before use | `JWTHelper.cpp:68–89` |
| Lifetime | 86,400 s (24 h) unless the preset sets one, minus a per-slot stagger of min(lifetime ÷ 20, 300 s) × slot index (0-based). Slot 3 custom: 86,400 − 600 = 85,800 s | `OBS/src/helpers/MQTTConnectionPolicy.h:17–18`, `:159–169`; `MQTTBridge.cpp:2919–2927` |
| Renewal | Before expiry by lifetime ÷ 10, clamped 60–300 s (24 h tokens renew 5 min early); at most one attempt per minute; then a clean reconnect | `MQTTConnectionPolicy.h:171–176`; `MQTTBridge.cpp:2649–2705` |
| Clock | Needs NTP (pool.ntp.org, then Google, Cloudflare, AWS, NIST); hourly resync; replies validated | Doc `:909–914` |

Worked shape (illustrative, not a real token):

```
username: v1_CC5D3CFD…(64 hex)
password: eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJwdWJsaWNLZXkiOiJDQzVE…In0.9F3A…(128 hex)
```

### 3.1 What the reference broker checks

`BRK/src/server.ts` (aedes over a WebSocket server), with `DEC/src/utils/auth-token.ts:142–202`.

| # | Check | Source |
|---|---|---|
| 1 | Username in the subscriber list → password compare, subscriber role | `server.ts:145–178` |
| 2 | Otherwise username must start `v1_`; rest must be 64 hex | `server.ts:183–197` |
| 3 | Password must be non-empty | `server.ts:199–203` |
| 4 | Token has 3 parts; header `alg` = `Ed25519`, `typ` = `JWT` | `auth-token.ts:148–168` |
| 5 | Payload has `publicKey` and `iat`; `publicKey` equals the username key (case-insensitive) | `auth-token.ts:170–178` |
| 6 | If `exp` present: now ≤ `exp`. **No check** that `exp` exists, that `iat` is not in the future, or of a maximum lifetime | `auth-token.ts:180–186` |
| 7 | Ed25519 signature over `header.payload` | `auth-token.ts:188–197` |
| 8 | `aud` equals `AUTH_EXPECTED_AUDIENCE` (required env var) | `server.ts:220–225`; `BRK/src/config.ts:19–30` |
| 9 | Publishers may only publish under `meshcore/` | `server.ts:306–312` |
| 10 | Topic has ≥ 4 parts: `meshcore/{IATA}/{PUBKEY}/…` | `server.ts:314–325` |
| 11 | IATA: not `XXX`; exactly 3 uppercase **letters** (`/^[A-Z]{3}$/`, `:328`) and a real airport (`airport-utils`), or `test`. The firmware accepts letters **and digits** (`OBS/src/helpers/MQTTObserverValidation.h:15–23`) | `server.ts:22–29`, `:327–368` |
| 12 | Topic key is 64 hex **and equals the authenticated key** | `server.ts:371–396` |
| 13 | Topic normalised to uppercase IATA and key | `server.ts:399–409` |
| 14 | JSON payload must contain `origin_id` equal to the authenticated key | `server.ts:435–455` |
| 15 | Retain flag stripped from `/status` publishes | `server.ts:261–266` |
| 16 | Publishers cannot subscribe (except their own `serial/commands`) | `server.ts:559–590` |
| 17 | Abuse tracking: duplicates, token bucket, packet size, topics/day, IATA changes in 24 h; muting only if enforcement is on | `BRK/src/config.ts:45–84`; `BRK/src/abuse-detector.ts:738`, `:831–839` |
| 18 | Any WebSocket path is accepted (no path filter); non-WebSocket HTTP is redirected | `server.ts:817–828` |

## 4. Topics

| Topic | Content | QoS / retain | Source |
|---|---|---|---|
| `meshcore/{IATA}/{PUBKEY}/status` | Status JSON, on each connect and every status interval | QoS 1; retained only if the preset allows it. **Custom slots publish status unretained** | `MQTTBridge.cpp:3191–3196`, `:4116–4117`; Doc `:722–723` |
| `meshcore/{IATA}/{PUBKEY}/packets` | One JSON per RX packet (and TX per `mqtt.tx`) | QoS 0, not retained | `MQTTBridge.cpp:4262–4263`; `MQTTBridge.h:564` |
| `meshcore/{IATA}/{PUBKEY}/raw` | Minimal raw packet (off by default) | QoS 0, not retained | `MQTTBridge.cpp:4322–4323`; Doc `:330` |
| `meshcore/{IATA}/{PUBKEY}/neighbors` | Zero-hop neighbour table with scopes (neighbors-enabled builds) | QoS 0; retain per preset | `MQTTBridge.cpp:4386–4387`; Doc `:731–738` |

- `{IATA}` is upper-cased by the CLI and must be 3 letters/digits (`CommonCLI_Observer.cpp:330–343`).
- `{PUBKEY}` is the node's 64-hex key, uppercase (`OBS/examples/simple_repeater/MyMesh.h:380–383`; `Utils.cpp:177`).
- Custom slots use `meshcore/{iata}/{device}/{type}` unless `mqttN.topic` is set (`MQTTBridge.cpp:3086–3094`;
  `OBS/src/helpers/MQTTTopicRouter.h:71`; Doc `:499–512`).
- **No last-will and no "offline" status.** The firmware only ever publishes `"status": "online"`
  (`MQTTBridge.cpp:3182`); no `setWill` call exists in the bridge (searched). The doc's `online|offline` (Doc `:747`)
  describes the schema, not this firmware. CMAT must detect a dead observer from silence.
- Status interval: default **5 min** (300,000 ms), settable 1–60 min (`OBS/src/helpers/MQTTDefaults.h:72`;
  `CommonCLI_Observer.cpp:373–381`; Doc `:333`, `:549`).

## 5. JSON fields

All field names below are exact. "str-num" means a number sent as a JSON **string**.

### 5.1 `status`

`OBS/src/helpers/MQTTPayloadBuilder.cpp:25–105`; values filled at `MQTTBridge.cpp:3132–3186`.

| Field | Type | Notes |
|---|---|---|
| `status` | string | Always `"online"` from this firmware |
| `timestamp` | string | ISO 8601 UTC with microseconds and `+00:00`, e.g. `2026-10-17T12:00:00.123456+00:00` |
| `origin` | string | Node name |
| `origin_id` | string | 64 uppercase hex public key |
| `model` | string | Board manufacturer name |
| `firmware_version` | string | e.g. `v1.18.0` |
| `radio` | string | `"%.6f,%.1f,%d,%d"` = freq MHz, BW kHz, SF, CR, e.g. `910.525024,62.5,7,5` (`MQTTBridge.cpp:3142–3143`). Inferred: float formatting may show binary noise in the last digits |
| `client_version` | string | `meshcore/<firmware_version>` |
| `repeat` | string, optional | `"on"` or `"off"` (forwarding) |
| `stats` | object, optional | Present when any stat is known; each field omitted when unknown |
| `stats.battery_mv` | int | |
| `stats.uptime_secs` | int | |
| `stats.packets_sent` | int | Flood + direct since boot |
| `stats.packets_received` | int | Flood + direct since boot |
| `stats.errors` | int | Dispatcher error flags |
| `stats.queue_len` | int | Bridge packet queue |
| `stats.noise_floor` | int | dBm |
| `stats.tx_air_secs` | int | Total TX airtime since boot |
| `stats.rx_air_secs` | int | Total RX airtime since boot |
| `stats.recv_errors` | int | Radio receive errors |
| `stats.internal_heap` | int | Free internal heap, bytes |
| `stats.heap_largest` | int | **Not in the doc** |
| `stats.mqtt_slots_up` | int | **Not in the doc** |
| `stats.mqtt_slots_total` | int | **Not in the doc**; `up < total` means a broker is down |
| `stats.mqtt_outage_secs` | int, optional | **Not in the doc**; only during an outage |
| `stats.mqtt_connect_failures` | int, optional | **Not in the doc**; only when > 0 |
| `stats.mqtt_slots_breaker` | int, optional | **Not in the doc**; only when > 0 |

`tx_air_secs` and `rx_air_secs` are a free airtime meter per observer (plan rule 9, Network → Airtime). Inferred:
the delta between two status messages gives airtime per interval.

### 5.2 `packets`

`MQTTPayloadBuilder.cpp:107–193`; built from the radio's raw bytes at `OBS/src/helpers/MQTTMessageBuilder.cpp:224–299`.

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string | ISO 8601 UTC as above |
| `hash` | string | 16 uppercase hex = first 8 bytes of SHA-256(payload type ‖ payload); TRACE also hashes the path length. **The path is not hashed**, so every observer that hears the same packet reports the same hash: this is the join key (`OBS/src/Packet.cpp:41–50`; `OBS/src/MeshCore.h:7`) |
| `origin` | string | Node name |
| `type` | string | `"PACKET"` |
| `direction` | string | `"rx"` or `"tx"` |
| `time` | string | `HH:MM:SS` UTC |
| `date` | string | `DD/MM/YYYY` UTC |
| `len` | str-num | Raw radio length |
| `packet_type` | str-num | Payload type 0–15 (5 = GRP_TXT, 4 = ADVERT, 11 = CONTROL, 9 = TRACE; Doc `:397–406`) |
| `route` | string | Only `"F"` (flood or transport-flood) or `"D"` (direct or transport-direct) are emitted. `T`/`U` in the doc never occur (`MQTTMessageBuilder.cpp:269`, `:325–331`; `OBS/src/Packet.h:65`) |
| `payload_len` | str-num | |
| `raw` | string | Uppercase hex of the full on-air packet, header and path included |
| `origin_id` | string | 64 uppercase hex |
| `SNR` | str-num, rx only | One decimal (`%.1f`); omitted if unknown |
| `RSSI` | str-num, rx only | Integer dBm; omitted if unknown |
| `score` | str-num, rx only | Rebroadcast score × 1000, 0–1000; omitted if unknown |
| `path` | array of strings, optional | **Direct-routed packets only.** Lowercase hex per hop, e.g. `["aa","bb"]` |

**Consequence for CMAT:** a flood ping's repeater path is **not** in `path`. The ingest must decode the hop list from
`raw` (header byte, optional transport codes, path-length byte with hash-size bits, then hops). Cross-check against
`docs/PROTOCOL.md` and the M2 decoder tests.

### 5.3 `raw`

`MQTTPayloadBuilder.cpp:195–214`: `origin` (string), `origin_id` (string), `timestamp` (string), `type` = `"RAW"`,
`data` (uppercase hex packet). Off by default (`set mqtt.raw on`).

### 5.4 `neighbors`

`MQTTPayloadBuilder.cpp:216–322`; Doc `:818–869`.

| Field | Type | Notes |
|---|---|---|
| `timestamp`, `origin`, `origin_id` | string | As above |
| `total_neighbors` | int | Table size at cycle start |
| `queried_neighbors` | int | Scope requests confirmed sent |
| `truncated` | bool | True if the 10 KB buffer filled |
| `self.scopes` | string | Comma list, may be empty |
| `self.default_scope` | string | `*` when none |
| `neighbors[]` | array of objects | Ordered most to least useful |
| `neighbors[].pubkey` | string | Hex key |
| `neighbors[].snr` | number | dB, float |
| `neighbors[].heard_secs_ago` | int or **null** | null = unknown, never "just now" |
| `neighbors[].scopes` | string | |
| `neighbors[].status` | string | `responded`, `timeout` or `send_failed` |

Non-PSRAM builds cap the table at 20 entries; classic ESP32 T-LoRa builds do not publish neighbours (Doc `:184–192`).
Periodic publishing default 24 h, range 12–336 h (Doc `:550–551`).

## 6. meshcoretomqtt (Pi / serial bridge) differences

For owners who run a Raspberry Pi bridge instead of the observer firmware.

| Topic | Observer firmware | meshcoretomqtt | Source (M2M) |
|---|---|---|---|
| Token lifetime | 24 h (minus stagger) | **1 h** (`token_ttl = 3600`), reused until < 5 min left | `bridge/state.py:77`; `bridge/mqtt_manager.py:304–310`; M2Mt `mctomqtt.py:136`, `:239` |
| Token format | Same header and signature form | Same; payload order `publicKey`, `iat`, `exp`, then `aud`, then `owner`/`email` (only when TLS **and** verify are on; email lower-cased), then `client` (the bridge's client version) | `auth_token.py:20–73`; `bridge/mqtt_manager.py:312–337` |
| WebSocket path | From the URL (`/mqtt` for most presets) | **Always `/`** | `bridge/broker_client.py:91–92` |
| Offline status | None | **Last will** = status `"offline"` (no stats), plus an explicit offline on shutdown | `bridge/mqtt_manager.py:375–379`; `bridge/broker_client.py:74`; `bridge/runner.py:261–266` |
| Status retain | Per preset; custom = off | Always unretained (`retain=False`); LWT retain per broker config (default true) | `bridge/mqtt_publish.py:87–101`; `bridge/mqtt_manager.py:379` |
| Status fields | §5.1 incl. `repeat` and connection-health stats | `status`, `timestamp`, `origin`, `origin_id`, `radio`, `model`, `firmware_version`, `client_version`, `stats` (device stats object); missing values are the string `"unknown"` | `bridge/mqtt_publish.py:68–82` |
| Packet `SNR`/`RSSI` | `%.1f` / int strings | Integers as parsed from the serial log (regex `-?\d+`) | `bridge/message_parser.py:19–24`, `:80–86` |
| Packet extras | `score` scaled ×1000; `hash` on rx and tx | `duration` (rx); `score` as printed; `hash` only on rx | `bridge/message_parser.py:80–86` |
| `path` | JSON array, direct only | A **string** (the bracketed serial text), direct only | `bridge/message_parser.py:89–90` |
| Timestamp | Microseconds, `+00:00` | Python `isoformat()`, `+00:00` | `bridge/message_parser.py:37` |
| Extra topics | `neighbors` | `debug`; remote serial `serial/commands` / `serial/responses` | `config.toml.example:40–44`, `:46–60`; `bridge/remote_serial.py:53` |
| Topic variables | `{iata}`, `{device}`, `{token}`, `{type}` | `{IATA}`, `{PUBLIC_KEY}` | `config.toml.example:41` |

## 7. CMAT broker requirements that follow

Inferred from §3–§6; these become M2 spec items.

1. Accept WebSocket upgrades on **both** `/mqtt` and `/` (firmware and meshcoretomqtt).
2. Expected audience: one fixed string; both clients send the value the owner typed. **`mqtt.meshsonar.com`
   (approved by Andy, Oct 17)**, matching the host-name convention of every built-in preset (`MQTTPresets.h:138–141`).
3. Require `exp` and cap lifetime at ≥ 24 h + skew (firmware tokens are 24 h); reject `iat` far in the future. The
   reference broker does neither (§3.1, row 6).
4. Treat silence, not an "offline" message, as the observer-down signal (firmware sends none).
5. Do not rely on retained status (custom slots send none).
6. Parse numbers that arrive as strings; tolerate integer and one-decimal SNR.
7. Decode the flood path from `raw`; use `hash` to join one packet across observers.
8. Check `origin_id` and the topic key against the authenticated key, as the reference broker does (§3.1, rows 12, 14).
9. Accept IATA codes of 3 letters **or digits**, as the firmware does, not the reference broker's letters-only rule
   (§3.1, row 11). CMH passes both.

## 8. Owner setup: exact commands

For an observer joining CMAT's broker. Typed on the serial console (115200 baud) or through a repeater-admin
login. Each `set mqttN.*` command restarts only that slot, so no reboot is needed
(`CommonCLI_Observer.cpp:508–628`, `restartBridgeSlot`). `set mqtt.iata` restarts the bridge (`:341`).

**Board with PSRAM (Heltec V4, T3S3, Station G2 and others): add CMAT in slot 3, keep the analyzers.**

```
set mqtt.iata CMH
set mqtt3.preset custom
set mqtt3.server wss://mqtt.meshsonar.com:443/mqtt
set mqtt3.audience mqtt.meshsonar.com
get mqtt.status
get mqtt3.diag
```

**Board without PSRAM (classic ESP32 / ESP32-S3 without PSRAM): only two secure brokers fit, so CMAT replaces
analyzer-eu in slot 2.**

```
set mqtt.iata CMH
set mqtt2.preset custom
set mqtt2.server wss://mqtt.meshsonar.com:443/mqtt
set mqtt2.audience mqtt.meshsonar.com
get mqtt.status
get mqtt2.diag
```

On a classic ESP32 T-LoRa V2.1–1.6 (one secure broker only, Doc `:240`), also `set mqtt1.preset none`.

Optional, once per node (adds `owner` / `email` to the token so CMAT can show who runs it; serial console only for
`get`):

```
set mqtt.owner <64-hex public key of the owner's companion>
set mqtt.email <owner email>
```

Expected replies: `OK - slot 3 preset: custom`, `OK`, `OK - slot 3 JWT audience: mqtt.meshsonar.com`
(`CommonCLI_Observer.cpp:531`, `:573`, `:619`). `get mqtt.status` should then show slot 3 connected. Prerequisites
already on any working observer: WiFi set, radio `910.525,62.5,7,5`, clock synced by NTP (Doc `:22–49`, `:909–914`).

The audience string above is the approved value from §7, item 2 (Andy, Oct 17); the broker must be configured
with the same audience before owners are sent these commands.
