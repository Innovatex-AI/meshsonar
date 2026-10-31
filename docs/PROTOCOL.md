# MeshCore protocol, as MeshSonar implements it

This is the subset of the MeshCore companion protocol and over-the-air format that MeshSonar uses, written so a
reimplementation (another language, another BLE stack) can reproduce it byte for byte. All integers are
**little-endian**. Source files: `lib/radio/protocol.dart`, `lib/radio/packet.dart`, `lib/radio/crypto.dart`,
`lib/radio/companion_link.dart`, `lib/radio/wardrive_engine.dart`, `lib/radio/ble_transport.dart`.

**Sources of truth** (MIT, credited in `THIRD_PARTY_NOTICES.md`). When they disagree, the firmware wins:

| Source | Files used |
|---|---|
| MeshCore firmware (© 2025 Scott Powell / rippleradios.com) | `examples/companion_radio/MyMesh.cpp` (codes lines 9–140, `handleCmdFrame()` ~1055+, `logRxRaw()` ~291, `onControlDataRecv()` ~810), `docs/companion_protocol.md`, `src/Packet.h`, `src/Packet.cpp`, `src/Mesh.cpp` (`routeRecvPacket()` ~344, `createGroupDatagram()` ~540), `src/Utils.cpp`, `src/helpers/BaseChatMesh.cpp` (`sendGroupMessage()` ~518, `setChannel()` ~939), `examples/simple_repeater/MyMesh.cpp` (discovery ~786–857) |
| MeshMapper web client (© 2025 MrAlders0n) | `content/wardrive.js` (`buildPayload`, `deriveChannelKey`, `ensureChannel`, `handleTxLogging`, `decryptGroupTextPayload`), `content/mc/connection/connection.js` |
| MeshCore Open (© 2025 zjs81) | `lib/connector/meshcore_protocol.dart`, `meshcore_connector.dart`, `meshcore_uuids.dart`, `models/channel.dart` |

The line numbers are the ones cited in the code comments. They refer to the firmware checkout used during development
(`/home/claude/meshcore-dev/meshcore`).

## 1. Transport: Bluetooth LE

| Item | Value |
|---|---|
| Service UUID | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` (Nordic-UART style) |
| RX characteristic (app → radio, write) | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| TX characteristic (radio → app, notify) | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |
| Framing | **One BLE write = one companion frame; one notification = one frame.** No length prefix. |
| Scan | Filtered on the service UUID; 8 s timeout (`RadioScanner.scan`). Name = advertised name, else platform name, else device id. |
| Connect | 15 s connection timeout. Then `requestMtu(185)` on Android only (iOS negotiates its own; failures ignored). Then service discovery, subscribe to TX notifications. |
| Writes | `write(withoutResponse: rx.properties.writeWithoutResponse)` |
| Disconnect | Detected from `connectionState == disconnected`; the incoming stream closes, so the link fails its pending command and closes. |

Any other byte pipe works as long as it keeps frame boundaries: `ByteTransport` in `radio_api.dart` is just
`incoming: Stream<Uint8List>`, `send(Uint8List)`, `disconnect()`, `isConnected`. The simulator is one such pipe.

## 2. Companion frames

### 2.1 Codes used

| Kind | Name | Code | Used for |
|---|---|---|---|
| Command | `CMD_APP_START` | 1 | Session start → `SELF_INFO` |
| Command | `CMD_SEND_CHANNEL_TXT_MSG` | 3 | Sending the ping |
| Command | `CMD_GET_DEVICE_TIME` / `CMD_SET_DEVICE_TIME` | 5 / 6 | Set clock at start |
| Command | `CMD_SYNC_NEXT_MESSAGE` | 10 | Drain the radio's offline queue |
| Command | `CMD_DEVICE_QUERY` | 22 (0x16) | Firmware version, channel count |
| Command | `CMD_GET_CHANNEL` / `CMD_SET_CHANNEL` | 31 / 32 | Find / install the wardriving channel |
| Command | `CMD_SEND_CONTROL_DATA` | 55 (v8+) | Neighbour discovery request (optional) |
| Command | `CMD_GET_BATT_AND_STORAGE` | 20 | Radio health: battery mV, storage (stream 7) |
| Command | `CMD_GET_STATS` | 56 (v8+) | Noise floor (type 1, per ping); radio health (types 0, 1, 2, every 60 s during a drive) |
| Reply | `RESP_CODE_OK` / `ERR` | 0 / 1 | `ERR` byte 1 = error code (1 unsupported, 2 not found, 3 table full, 4 bad state, 5 file I/O, 6 illegal arg) |
| Reply | `SELF_INFO` | 5 | |
| Reply | `SENT` | 6 | Accepted as a send reply (see §7) |
| Reply | `CONTACT_MSG_RECV` / `_V3` | 7 / 16 | Recognised, ignored |
| Reply | `CHANNEL_MSG_RECV` / `_V3` | 8 / 17 | Drained, ignored by the engine |
| Reply | `CURR_TIME` | 9 | Decoded only |
| Reply | `NO_MORE_MESSAGES` | 10 | End of drain |
| Reply | `BATT_AND_STORAGE` | 12 | |
| Reply | `DEVICE_INFO` | 13 | |
| Reply | `DISABLED` | 15 | Decoded only |
| Reply | `CHANNEL_INFO` | 18 | |
| Reply | `STATS` | 24 | |
| Push | `PUSH_CODE_MSG_WAITING` | 0x83 | Triggers a drain |
| Push | `PUSH_CODE_LOG_RX_DATA` | 0x88 | **Every packet the radio hears**: the echo source |
| Push | `PUSH_CODE_CONTROL_DATA` | 0x8E (v8+) | Discovery responses |

Codes ≥ 0x80 are unsolicited pushes. Anything below is the reply to the one outstanding command.

### 2.2 Command sequencing

There is one command in flight at a time. The link waits up to **5 s** for the reply. A reply that arrives with no
command waiting (for example, late after a timeout) is dropped. Malformed frames are ignored without killing the link.

```mermaid
sequenceDiagram
  participant App as MeshCoreCompanionLink
  participant R as Companion radio
  App->>R: 01 01 00×6 "MeshSonar"            (APP_START)
  R-->>App: 05 … (SELF_INFO)
  App->>R: 16 03                              (DEVICE_QUERY, app_target_ver 3)
  R-->>App: 0D … (DEVICE_INFO)  [ERR tolerated: very old firmware]
  App->>R: 06 <epoch u32>                     (SET_DEVICE_TIME)
  R-->>App: 00 OK  or 01 06 (ERR illegal arg = clock would go backwards; ignored)
  App->>R: 0A (SYNC_NEXT_MESSAGE) … until 0A NO_MORE_MESSAGES (≤256)
  Note over App,R: ensureChannel at Start drive
  App->>R: 1F 00, 1F 01, …                    (GET_CHANNEL until ERR not-found or max_channels)
  R-->>App: 12 idx name×32 secret×16
  App->>R: 20 idx name×32 secret×16           (SET_CHANNEL into first empty slot, only if missing)
  R-->>App: 00 OK
  Note over App,R: each ping
  App->>R: 38 01                              (GET_STATS radio)
  R-->>App: 18 01 noise… / 01 01 (unsupported → never asked again)
  App->>R: 03 00 idx <ts u32> "MS:<tag>" (SEND_CHANNEL_TXT_MSG)
  R-->>App: 00 OK
  R-->>App: 88 snr rssi <raw packet> …        (LOG_RX_DATA pushes, for 7 s)
```

### 2.3 Byte layouts (app → radio)

| Command | Bytes |
|---|---|
| APP_START | `[0x01][app_ver=1][0×6][app_name UTF-8, ≤64 bytes]`. Firmware needs length ≥ 8 and ignores bytes 1–7. |
| DEVICE_QUERY | `[0x16][app_target_ver=3]`. ≥ 3 selects the `_V3` message formats. MeshCore Open sends 4. |
| SET_DEVICE_TIME | `[0x06][epoch_secs u32]` |
| GET_CHANNEL | `[0x1F][idx]` |
| SET_CHANNEL | `[0x20][idx][name ×32, NUL-padded, ≤31 bytes][secret ×16]` = **50 bytes**. The 66-byte 32-byte-secret variant is rejected by the firmware. |
| SEND_CHANNEL_TXT_MSG | `[0x03][txt_type=0 plain][channel_idx][timestamp u32][text UTF-8 to end of frame, no NUL]` |
| SYNC_NEXT_MESSAGE | `[0x0A]` |
| GET_BATT_AND_STORAGE | `[0x14]` |
| GET_STATS | `[0x38][stats_type]` (0 core, 1 radio, 2 packets; unknown type = `ERR illegal arg`) |
| SEND_CONTROL_DATA | `[0x37][payload…]`, `payload[0] & 0x80` must be set; sent zero-hop |

### 2.4 Byte layouts (radio → app)

| Frame | Offset: field |
|---|---|
| SELF_INFO (≥ 58 B) | 0 `0x05` · 1 adv_type · 2 tx_power_dbm i8 · 3 max_tx_power i8 · 4–35 public key ×32 · 36 adv_lat i32 (×1e-6) · 40 adv_lon i32 · 44 multi_acks · 45 advert_loc_policy · 46 telemetry_modes · 47 manual_add · 48 **freq u32 in kHz** · 52 **bw u32 in Hz** · 56 sf · 57 cr · 58… name (to NUL/end) |
| DEVICE_INFO | 0 `0x0D` · 1 fw_ver_code · 2 max_contacts/2 · 3 max_channels · 4 ble_pin u32 · 8 build_date ×12 · 20 manufacturer ×40 · 60 fw_version ×20 · 80 repeat (v9+) · 81 path_hash_mode (v10+). Shorter frames: missing fields are null. |
| CHANNEL_INFO (≥ 50 B) | 0 `0x12` · 1 idx · 2–33 name ×32 (C string) · 34–49 secret ×16. Empty slot = empty name and all-zero secret. |
| STATS / radio (≥ 14 B) | 0 `0x18` · 1 `0x01` · 2 noise_floor i16 dBm · 4 last_rssi i8 · 5 last_snr i8 (÷4) · 6 tx_air_secs u32 · 10 rx_air_secs u32 |
| STATS / core (11 B) | 0 `0x18` · 1 `0x00` · 2 battery_mv u16 · 4 uptime_secs u32 · 8 err_flags u16 (**bitmask**: bit 0 queue full, bit 1 CAD timeout, bit 2 start-RX timeout; sticky) · 10 queue_len u8 |
| STATS / packets (30 B; 26 B accepted) | 0 `0x18` · 1 `0x02` · then u32: 2 recv · 6 sent · 10 flood_tx · 14 direct_tx · 18 flood_rx · 22 direct_rx · 26 recv_errors (absent in the 26 B form) |
| BATT_AND_STORAGE (11 B; 3 B accepted) | 0 `0x0C` · 1 battery_mv u16 · 3 used_kb u32 · 7 total_kb u32 (absent in the 3 B legacy form) |
| CHANNEL_MSG_RECV_V3 | 0 `0x11` · 1 snr i8 (÷4) · 2–3 reserved · 4 ch_idx · 5 path_len (0xFF = direct) · 6 txt_type · 7 ts u32 · 11… text |
| CHANNEL_MSG_RECV (legacy) | 0 `0x08` · 1 ch_idx · 2 path_len · 3 txt_type · 4 ts u32 · 8… text |
| LOG_RX_DATA push | 0 `0x88` · 1 snr i8 (= SNR×4) · 2 rssi i8 dBm · 3… **raw over-the-air packet** (§3) |
| CONTROL_DATA push | 0 `0x8E` · 1 snr i8 (×4) · 2 rssi i8 · 3 path_len · 4… control payload |

`MeshCoreCompanionLink.start()` maps SELF_INFO to `SelfInfo`: `public_key` as lower-case hex. Radio fields that read
0 become `null`. `freq_mhz = freq/1000`, `bw_khz = bw/1000`, `tx_dbm = tx_power_dbm`. `firmware` is the DEVICE_INFO
`fw_version` string, else `"ver <code>"`.

## 3. Over-the-air packet (inside LOG_RX_DATA)

```
[header u8][transport_code1 u16, transport_code2 u16 — only for TRANSPORT_* routes][path_len u8][path …][payload …]
```

| Field | Meaning |
|---|---|
| header bits 0–1 | route: 0 TRANSPORT_FLOOD, 1 FLOOD, 2 DIRECT, 3 TRANSPORT_DIRECT |
| header bits 2–5 | payload type: 0x05 = **GRP_TXT** (others listed in `PayloadType`) |
| header bits 6–7 | payload version |
| path_len bits 0–5 | **hop count** = number of path entries |
| path_len bits 6–7 | **hash size − 1** → 1, 2 or 3 bytes per entry; 4 is reserved and invalid |
| path | `hop_count × hash_size` bytes, ≤ 64 (MAX_PATH_SIZE) |
| payload | Must be non-empty |

Each repeater **appends** its own hash (a prefix of its public key) before it re-floods (`Mesh.cpp
routeRecvPacket`). So `path[0]` is the repeater that heard the phone directly, and the number of entries is the
number of repeats. `MeshPacket.tryParse` returns null for anything `Packet::readFrom` would reject.

## 4. Channels and crypto

### 4.1 Channel secret derivation

| Channel | Secret (16 bytes) |
|---|---|
| `#name` (hashtag) | `SHA-256(lower(trim(name)))[0..16]`, with `#` prepended if missing. Example: `#wardriving` → `e3c26491e9cd321e3a6be50d57d54acf`. |
| `Public` | Fixed key `8b3387e9c5cdea6ac9e5edbaa115cd72` |
| Anything else | Unknown. It must already be on the radio (its secret is read back with GET_CHANNEL). |

The firmware docs hash the name exactly as typed (`sha256("#test")` → `9cd8fcf22a47333b591d96a2b848b73f`).
MeshSonar lower-cases first, like MeshMapper, so `#Wardriving` and `#wardriving` are the same community channel.

**`ensureChannel(name)`** reads slots `0…max_channels−1` (64 if unknown) until `ERR not-found`. It picks the first slot
whose secret equals the derived secret, otherwise a non-empty slot whose name matches (case-insensitive). If neither
exists, it writes `(name, derived secret)` into the first empty slot. It throws if the key is unknown or no slot is
free. Every secret it reads is cached per index and later used to decrypt echoes.

### 4.2 Channel hash and GRP_TXT payload

- **Channel hash** (1 byte) = `SHA-256(secret16)[0]`. For `#wardriving` that's `0x81`, and for Public `0x11`.
- **GRP_TXT payload** = `[channel_hash][MAC ×2][AES-128-ECB(ciphertext)]`
- **Plaintext** = `[timestamp u32][flags u8 = 0][ "<sender name>: <text>" UTF-8 ]`, zero-padded to 16-byte blocks.
- **AES key** = the 16-byte secret; ECB, one block at a time.
- **MAC** = first 2 bytes of `HMAC-SHA256(key = secret padded with zeros to 32 bytes, data = ciphertext)`.
- Decrypt (`meshMacThenDecrypt`) checks the MAC first, needs a whole number of blocks, then strips trailing zero
  padding from the text.

`crypto.dart` contains textbook SHA-256 (FIPS 180-4), HMAC (RFC 2104) and AES-128 (FIPS 197) so the app needs no
crypto package.

## 5. The ping and its echoes

### 5.1 Ping text (MeshMapper-compatible)

```
MS:<10 random chars 0-9a-z>
e.g.  MS:m3jnr7dan5
(no position, no power, nothing about the driver: the channel is public. 0.7.1 and 0.7.2 sent "@[MeshSonar] [power]"; 0.7.0 and earlier sent "@[MapperBot] lat, lon [power]".)
```

- Prefix `MS:` and a random tag (stored as `wire_tag`). Unlike MeshMapper's `buildPayload()` (`@[MapperBot] lat, lon`), MeshSonar puts NO position on the
  channel: it is public. The site joins observer receptions by packet hash instead (v1.1 `pkt_hash`).
- The power suffix is appended when the radio's TX power is known: `W = 10^(tx_dbm/10) / 1000`, formatted with one
  decimal (two below 0.1 W) plus `w`. MeshMapper offers fixed choices (`0.3w`, `0.6w`, `1.0w`, `2.0w`). MeshSonar
  derives the value from SELF_INFO, so a 22 dBm radio sends `0.2w` (see §7).
- The timestamp in SEND_CHANNEL_TXT_MSG is the phone's UTC epoch second, forced **strictly increasing** per link
  (`ts = max(now, last + 1)`). It ends up inside the encrypted payload, so each send has its own fingerprint.

### 5.2 Echo recognition (`matchEcho` in `packet.dart`)

A heard packet counts as an echo of *this* ping only if **all** of these hold:

1. It parses (§3), its payload type is **GRP_TXT**, and its route is **FLOOD or TRANSPORT_FLOOD**.
2. Its path is **not empty**. An empty path is our own transmission or a direct copy, not a repeat.
3. `payload[0]` equals our **channel hash**, and the **MAC** verifies with our secret.
4. The decrypted **timestamp** equals the one we put in the send command. This check runs when the link is a
   `MeshCoreCompanionLink`, so an earlier ping with the same text can't claim this ping's echoes.
5. The decrypted **text** equals the ping text or ends with `": " + ping text` (the firmware prefixes the sender name).

Result: `repeater = path[0]` as lower-case hex (1–3 bytes), `hops = hop count`, `path = every entry as hex`.

### 5.3 From matches to `Echo`s (`DefaultWardriveEngine._buildEchoes`)

- `snr_db` and `rssi_dbm` come from the LOG_RX_DATA push, range-checked (SNR −40…40, RSSI −160…0, else null).
  **They describe the last hop (the transmitter we actually heard), not `path[0]`**, unless `hops == 1`. That is
  why `hops: 1` is the only echo that measures the phone↔repeater link.
- `delay_ms` = arrival time by the phone's clock minus the time just before the send command, floored at 0. It
  includes BLE and queueing latency.
- **One echo per repeater** (`path[0]`). When several copies arrive, the copy with the **fewest hops** wins, and among
  equal hops the best SNR wins. Echoes keep first-heard order.

### 5.4 Listen window and cut-short pings

The engine listens for **7 s** (`WardriveConfig.listenWindow`). It polls every 250 ms and stops early if the radio
disconnects or the drive stops. A ping whose window was cut short **and** that heard nothing is discarded rather than
recorded as "heard nothing".

## 6. Other measurements

### 6.1 Noise floor (GET_STATS)

Before each ping the engine calls `noiseFloor()`: `[0x38][0x01]` → `STATS/radio`. `noise_floor i16` is used as
dBm. **0 means "not calibrated yet"** (RadioLib starts at 0) and becomes `null`. `ERR unsupported` sets a per-link flag
so the app never asks again. Timeouts and errors give `null`. The value is range-checked to −160…0.

### 6.1a Radio health (stream 7)

`MeshCoreCompanionLink.coreStats()`, `radioStats()`, `packetStats()`, `batteryAndStorage()` read the frames above
through the same one-at-a-time command queue. `ERR unsupported` for GET_STATS (firmware < v8) turns off every
GET_STATS read for the link, `ERR illegal arg` turns off that sub-type, `ERR unsupported` for GET_BATT_AND_STORAGE
turns that off; each is asked once per link. Timeouts/errors give null for that call. Unmeasured is null, never 0:
battery 0 mV (board without battery sense), noise floor 0, last RSSI 0 (nothing heard yet; its SNR is then dropped
too), storage total 0. `RadioHealthPoller` (`lib/radio/radio_health.dart`) asks radio, core, packets every 60 s
(battery+storage every 15 min, or every poll when core stats are missing), and checks before **each** command that
no ping is in flight (engine state `pinging`, which spans the noise-floor read, the send and the listen window); it
waits up to half the interval, then skips. The layouts were re-read from MeshCore `main` b204f9a (FIRMWARE_VER_CODE 14). Wired into drives by
`lib/app/drive_context_hook.dart` / `lib/core/drive_context_session.dart` (every 60 s while a drive runs and the
`radio_health` category is on).

**Verification status (no real-radio capture of any of these frames exists yet; every test vector is built from the
documented byte layout, `test/radio/protocol_test.dart`):**

| Frame | Layout | Source | Verified on hardware |
|---|---|---|---|
| STATS radio `[18][01]` 14 B | noise i16, rssi i8, snr i8/4, tx/rx air u32 | firmware `MyMesh.cpp` memcpy order | No (noise floor read by GET_STATS is older code, used since 0.5) |
| STATS core `[18][00]` 11 B | battery u16, uptime u32, err_flags u16, queue u8 | firmware `MyMesh.cpp` | No |
| STATS packets `[18][02]` 30 B | 7 x u32 | firmware `MyMesh.cpp` | No |
| STATS packets 26 B form (no recv_errors) | 6 x u32 | radio plan doc only, no firmware source | No, and unconfirmed to exist |
| BATT_AND_STORAGE `[0C]` 11 B | mv u16, used_kb u32, total_kb u32 | firmware `MyMesh.cpp` | No |
| BATT_AND_STORAGE 3 B form | mv u16 only | firmware comment only | No |

To close the gap, capture the raw frames from a real companion radio (diagnostics log) and add them to the test file as
literal byte vectors. Until then, a layout mismatch would show as nonsense health values, not a crash: decoders throw
`ProtocolException` on short frames and the poller records null for that read.

### 6.2 Neighbour discovery (off by default)

`DefaultWardriveEngine.discoverNeighbors` defaults to **false**, and nothing in the app turns it on today. When it is
true, the link is a `MeshCoreCompanionLink`, and `firmware_ver_code ≥ 8`, then after each ping the engine:

1. Sends `SEND_CONTROL_DATA` with a **NODE_DISCOVER_REQ** payload:
   `[0x80 | prefix_only(0)][type_filter = 1<<2 (repeaters)][tag u32, random 1…2³¹][since u32 = 0]`.
2. During the listen window, collects `CONTROL_DATA` pushes with `path_len == 0` whose payload is a
   **NODE_DISCOVER_RESP**: `[0x90 | node_type][snr_in i8 (×4) — how the repeater heard us][tag u32][pub_key ×32 (or ×8)]`.
   The tag must match and node_type must be 2 (repeater).
3. Records the response with the best local SNR as `neighbor = {repeater: key hex, local_snr_db, local_rssi_dbm,
   remote_snr_db}`.

It's off because it adds airtime on every ping and repeaters rate-limit discovery (4 per 2 minutes,
`simple_repeater/MyMesh.cpp discover_limiter`).

### 6.3 Offline queue drain

After `start()`, and on every `PUSH_CODE_MSG_WAITING`, the link sends `SYNC_NEXT_MESSAGE` (up to 256 times) until
`NO_MORE_MESSAGES`, an error, or an unexpected frame. Channel messages go to `channelMessages` (nobody listens to it
today). This only exists so the radio's queue never fills.

## 7. Known discrepancies and choices

| # | Topic | What MeshSonar does |
|---|---|---|
| 1 | SEND_CHANNEL_TXT_MSG reply | Firmware sends `RESP_CODE_OK` (`writeOKFrame`); `docs/companion_protocol.md` says `RESP_CODE_SENT`. Both are accepted. |
| 2 | Flood route | MeshMapper accepts only header `0x15` (FLOOD + GRP_TXT, version bits 0 — the firmware's "payload version 1"). Firmware uses TRANSPORT_FLOOD (`0x14`, 4 transport-code bytes) when a flood scope/region is set. Both are accepted. |
| 3 | Path hash size | MeshMapper treats each path byte as one hop. Firmware ≥ 1.12 supports 2- and 3-byte hashes (`path_len` bits 6–7). MeshSonar decodes the size, so hops and prefixes stay right. |
| 4 | Extra checks | MeshSonar also verifies the MAC and the 4-byte timestamp. MeshMapper matches on text only. |
| 5 | SELF_INFO units | Firmware sends freq in kHz and bw in Hz. MeshCore Open calls them `freqHz`/`bwHz`, but its maths treats freq as kHz. |
| 6 | DEVICE_QUERY version | MeshSonar sends 3, MeshCore Open sends 4. The firmware only branches on ≥ 3. |
| 7 | Hashtag secret case | Firmware docs hash the name as typed. MeshSonar and MeshMapper lower-case it first. A slot created case-sensitively by another app is still found by name, and its own secret is used. |
| 8 | Power suffix | MeshMapper uses fixed labels (`0.3w`/`0.6w`/`1.0w`/`2.0w`). MeshSonar computes the value from `tx_dbm`, so it can send values outside that set (22 dBm → `0.2w`). Tools that parse only MeshMapper's set may not recognise it. |
| 9 | "Heard" with a neighbour | In the app, a ping with no echoes but a `neighbor` counts as heard (`DrivePing.heardNothing`). CMAT's `drive-read` counts heard as `echoes.length > 0`. This only matters if discovery is turned on. |
| 10 | Echo SNR on multi-hop | SNR/RSSI belong to the last transmitter, but are stored on the echo keyed by `path[0]`. Consumers should use `hops == 1` echoes for link quality (CMAT does: `hops` 1 or null). |
| 11 | Echo timestamp check | Only applies with `MeshCoreCompanionLink` (it exposes `lastSentTimestamp`). Other `CompanionLink`s match on text only. |

## 8. Test vectors

| What | Where |
|---|---|
| SHA-256 (FIPS 180-4), HMAC-SHA256 (RFC 4231 case 2), AES-128 (FIPS 197 C.1), hashtag secret (`#test` from firmware docs, `#wardriving`), channel hash, encrypt-then-MAC round trip | `test/radio/crypto_test.dart` |
| Every command encoder and frame decoder, with byte arrays and firmware line references (SELF_INFO, DEVICE_INFO, CHANNEL_INFO, STATS, LOG_RX_DATA, CONTROL_DATA + DISCOVER_RESP, CHANNEL_MSG_RECV v3/legacy) | `test/radio/protocol_test.dart` |
| Full over-the-air packets built independently in Python (hashlib/hmac/cryptography): FLOOD `0x15` with 1-byte path `df 4e`, TRANSPORT_FLOOD `0x14` with 2-byte hash `df01`, sender "Car" on `#wardriving`; decrypt, rebuild byte-for-byte, `matchEcho` accept/reject cases | `test/radio/packet_test.dart` (`pktFlood`, `pktTransport`) |
| Link behaviour over real frames (start sequence, channel install, increasing timestamps, stats, timeout, disconnect) | `test/radio/companion_link_test.dart` |
| Ping text format | `test/radio/wardrive_engine_test.dart` ("ping text matches MeshMapper buildPayload") |

The simulator (`lib/radio/simulator.dart`) is a second, executable reference. It answers every command above with
firmware-shaped frames and emits real encrypted GRP_TXT floods (1- and 2-hop, any `pathHashSize`), plus background
Public-channel traffic that must *not* match.
