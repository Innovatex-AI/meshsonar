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

### 2.5 Claim frames: login, CLI, status, sign (0.24, unreleased)

Used only by "Claim my radio" and "Claim a repeater" (`lib/radio/claim_radio.dart`, implemented by
`MeshCoreCompanionLink`; flows in `lib/core/claim_flow.dart`). **Verified Oct 31 2026 against the MeshCore firmware
source on `main`** (`examples/companion_radio/MyMesh.cpp` FIRMWARE_VER_CODE 14, `examples/simple_repeater/MyMesh.cpp`,
`src/helpers/CommonCLI.cpp`, `BaseChatMesh.cpp`, `AdvertDataHelpers.cpp`, `TxtDataHelpers.h`). **Exercised against a physical radio on Oct 31 2026** (companion Seeed Wio Tracker L1, `v1.17.1`, FIRMWARE_VER_CODE 13, to a Heltec V4.3 observer repeater `v1.17.1.5-observer-7403067`); see the verified notes after the table. The fake radio in `test/support/claim_fakes.dart` speaks these exact layouts.

App to radio:

| Command | Bytes | Reply |
|---|---|---|
| GET_CONTACT_BY_KEY (30) | `[30][pub_key ×32]` | `CONTACT` (3) or `ERR(NOT_FOUND)` |
| ADD_UPDATE_CONTACT (9) | `[9][pub_key ×32][type][flags][out_path_len=0xFF][out_path ×64][name ×32][last_advert u32][lat i32][lon i32]` (144 B); type 2 = repeater | `OK`, or `ERR(TABLE_FULL)` |
| SEND_LOGIN (26) | `[26][pub_key ×32][password UTF-8, NUL]`; the radio keeps at most **15 bytes** of password (`sendLogin`) | `SENT` (6): `[6][is_flood][tag u32][est_timeout_ms u32]`; `ERR(NOT_FOUND)` if the repeater is not a contact |
| SEND_TXT_MSG (2) as CLI | `[2][txt_type=1 CLI_DATA][attempt][timestamp u32][pub_key_prefix ×6][text]`; no ack. **Verified on a real radio (Oct 31 2026): type 3 (CLI_COMMAND) is refused at once with `ERR 1`; type 1 works** | `SENT` (6), then `PUSH_MSG_WAITING` ~1 s later and a queued `CONTACT_MSG_RECV_V3` with the reply |
| SEND_STATUS_REQ (27) | `[27][pub_key ×32]` | `SENT`, later push `0x87` |
| LOGOUT (29) | `[29][pub_key ×32]` | `OK` (local only, nothing goes over the air) |
| SIGN_START (33) | `[33]` | `SIGN_START` (19): `[19][reserved][max_len u32 = 8192]` |
| SIGN_DATA (34) | `[34][chunk…]` (we send 120-byte chunks) | `OK`; `ERR(BAD_STATE)` without a start; `ERR(TABLE_FULL)` past 8 KB |
| SIGN_FINISH (35) | `[35]` | `SIGNATURE` (20): `[20][Ed25519 signature ×64]` by the radio's own identity key |
| EXPORT_CONTACT (17) | `[17]` (no key = the radio's own advert) | `EXPORT_CONTACT` (11): `[11][advert packet…]` |

Radio to app (pushes arrive at any time, not as the reply to a command):

| Frame | Layout |
|---|---|
| LOGIN_SUCCESS push `0x85` | `[0x85][is_admin][pub_key_prefix ×6][server time u32][acl permissions][firmware level]` (14 B). The pre-v7 form is `[0x85][0][prefix ×6]` (8 B) and always reads as **not admin**. A **guest** password also succeeds, with `is_admin` 0. |
| LOGIN_FAIL push `0x86` | `[0x86][reserved][pub_key_prefix ×6]` |
| STATUS_RESPONSE push `0x87` | `[0x87][reserved][prefix ×6]` then the repeater's `RepeaterStats` (little endian, 56 B): batt_mv u16, tx_queue u16, noise_floor i16, last_rssi i16, recv u32, sent u32, air_secs u32, up_secs u32, flood_tx u32, direct_tx u32, flood_rx u32, direct_rx u32, err_events u16, last_snr i16 (÷4), direct_dups u16, flood_dups u16, rx_air_secs u32, recv_errors u32. Older builds send a prefix of it. |
| CONTACT_MSG_RECV_V3 (a repeater's CLI reply) | `[0x10][snr i8 ×4][r][r][prefix ×6][path_len][txt_type=1 CLI_DATA][timestamp u32]([signer prefix ×4] when txt_type = 2)[text]`; legacy `[0x07][prefix ×6][path_len][txt_type][timestamp u32][text]`. Queued in the radio and fetched by SYNC_NEXT_MESSAGE after `MSG_WAITING` (§6.3); the link hands CLI replies to the claim call that is waiting. |

Firmware facts the flows depend on (all read from source):

1. **A wrong repeater password gets no reply at all** (`simple_repeater` `handleLogin` returns 0), so LOGIN_FAIL is
   not what a wrong password looks like. "No answer" means out of range **or** wrong password; the app says both.
2. The repeater runs CLI text only for an **admin** (`client->isAdmin()`); a guest login cannot rename it.
3. The radio must have the repeater as a **contact** before SEND_LOGIN / SEND_TXT_MSG (`lookupContactByPubKey`), so the
   app does GET_CONTACT_BY_KEY and, if missing, ADD_UPDATE_CONTACT first.
4. CLI: `get name` replies `> <name>`; `set name <x>` replies `OK` (or `Error, bad chars`: `[ ] \ : , ? *` are refused);
   `advert` replies `OK - Advert sent` and floods the advert about 1.5 s later.
5. **Name limits.** `node_name` is `char[32]`: at most 31 bytes. An ADVERT carries `MAX_ADVERT_DATA_SIZE` 32 bytes =
   1 flag byte + 8 bytes of position (when the repeater has one) + the name, so the name in an advert is cut to
   **23 bytes**. The claim code goes at the END of the name, so the app cuts the ORIGINAL part to 16 bytes
   (`<original> MSxxxx`, 23 bytes) while the code is on; the full original is restored afterwards.
6. The Ed25519 signature is over exactly the bytes the server sent (the hex in `message` decoded), not over the hex text.

Verified on hardware (Oct 31 2026, `meshsonar-infra/docs/planning/repeater-observer-live-research-2026-11-01.md`):

- Companion code 13 refuses `txt_type 3` and `CMD_RUN_CLI_COMMAND` (66) with `ERR 1`; type 1 works. The companion ignores the app's CLI timestamp (types 1 and 3 use its own clock; a 1970 stamp was accepted). A plain type 0 command uses the app's clock and is silently dropped by the repeater when older than the last accepted one.
- CLI round trip: `SENT` (tag 0), `0x83` about 1.1 s later (median, 0.97 to 3.5 s), about 3% of replies never arrive. A leading `NN|` on the command text is reflected on the reply (use it to match replies).
- Command text of 160 characters passed; 165 was dropped silently by the companion. Replies are capped near 160 characters.
- A **blank** password re-admits a key already in the repeater's ACL as its stored role (`0x85` is_admin 1); a wrong non-blank password from the same key gets no answer. A successful login proves the password only if it was non-blank.
- Responses to requests (`0x87`, `0x8B`, `0x8C`) carry zero padding to a 16-byte block (status struct arrives as 60 bytes: 56 + 4). Telemetry is Cayenne LPP, big endian.
- `0x85` is 14 bytes as documented; `STATS` core 11 B, radio 14 B, packets 30 B and `BATT_AND_STORAGE` 11 B match section 6.1a.

Not supported: claiming a **room server** (its login frame carries an extra `sync_since` field and the radio treats the
contact type differently); the claim button is hidden for rooms.

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

Now `MessageSync` (`lib/radio/message_sync.dart`). After `start()`, on every `PUSH_CODE_MSG_WAITING`, and (once something listens
to the session's `inbound` stream) every 5 s as a safety poll, the link sends `SYNC_NEXT_MESSAGE` until `NO_MORE_MESSAGES`, an
error or an unexpected frame (cap 512 per drain; the radio holds 16 or 256). Why the poll: `MSG_WAITING` is a one-byte push through
the radio's BLE queue, which is 4 frames deep on ESP32 and DROPS frames when full (`SerialBLEInterface`), so it can be lost.
Why persist-first: `SYNC_NEXT_MESSAGE` is destructive; each frame goes through the persister (awaited) before the next
command and before the typed message is emitted. Channel and contact text frames become `InboundMessage`s; CLI replies
(txt_type 1) go only to the claim call waiting for them; `CHANNEL_DATA_RECV` (27) datagrams share the queue and are stepped
over. A message with the same conversation, sender timestamp and text as one already seen is dropped (the radio gives no
message id; a retried DM arrives again as a new frame). A `MSG_WAITING` that arrives while a drain is finishing starts one
more round.

### 6.4 Chat frames (Nov 2026)

Layouts below are from MeshCore `examples/companion_radio/MyMesh.cpp` at 81dbae5 (MIT), re-read line by line; byte fixtures
are in `test/radio/chat_frames_test.dart` (written from the firmware, not through our encoders).

| Frame | Layout | Firmware |
|---|---|---|
| `GET_CONTACTS` (4) | `[4]` or `[4][since u32]` | 1238-1258. Only contacts with `lastmod > since`. A second one while it runs gets ERR(BAD_STATE=4): the session serialises them |
| `CONTACTS_START` (2) | `[2][total u32]`, the TOTAL on the radio, not the filtered count | 1252-1256 |
| `CONTACT` (3) | `[3][pub x32][type][flags][out_path_len][out_path x64][name x32][last_advert u32][lat i32 1e-6][lon i32 1e-6][lastmod u32]` = 148 B | `writeContactRespFrame` 171-193 |
| `END_OF_CONTACTS` (4) | `[4][most recent lastmod u32]`, the next `since` | 2404-2408 |
| `ADD_UPDATE_CONTACT` (9) | the CONTACT layout; the firmware reads lat/lon only if len >= 144 and lastmod only if len >= 148 | `updateContactFromFrame` 195-217 |
| `SEND_TXT_MSG` (2) | `[2][txt_type][attempt][ts u32][pub prefix x6][text]` -> `SENT` `[6][flood][expected_ack u32][est_timeout u32]`; unknown recipient ERR(NOT_FOUND), bad type ERR(UNSUPPORTED), no pool ERR(TABLE_FULL); plain text expects an ACK, CLI types do not (`expected_ack` 0) | 1132-1177 |
| `SEND_CONFIRMED` (0x82) | `[0x82][ack u32][trip ms u32]` | `processAck` 417-436. The ack table holds 8; the entry is cleared after the first match |
| `PATH_UPDATED` (0x81), `ADVERT` (0x80) | `[code][pub x32]` | 409-415, 358-407 |
| `NEW_ADVERT` (0x8A) | a full contact frame under code 0x8A | 358-407 |
| `CONTACT_DELETED` (0x8F), `CONTACTS_FULL` (0x90) | `[0x8F][pub x32]`, `[0x90]` | |
| `CONTACT_MSG_RECV_V3` (16) | `[16][snr i8 x4][0][0][sender prefix x6][path_len][txt_type][ts u32]([signer x4] if txt_type 2)[text]` | `queueMessage` 441-469 |
| `CHANNEL_MSG_RECV_V3` (17) | `[17][snr i8 x4][0][0][ch][path_len][txt_type][ts u32][text]`; the text is `"sender name: body"` (no sender key) | 558-585 |
| `CHANNEL_DATA_RECV` (27) | `[27][snr][0][0][ch][path_len][data_type u16][len u8][data]` | `onChannelDataRecv` |
| `DEVICE_INFO` (13) | byte 2 = MAX_CONTACTS / 2 (doubled by us), byte 3 = MAX_GROUP_CHANNELS | 1056-1075 |
| `SET_FLOOD_SCOPE_KEY` (54) | `[54][0][key x16]` per-connection override, `[54][0]` clear, `[54][1]` unscoped (ver 12+) | 1978-1992 |

`path_len` (also a contact's `out_path_len`): low 6 bits = hop count, top 2 bits = hash size - 1 (`src/Packet.h` 79-83), so a path is
`hops x hash size` bytes (`pathByteLength`); 0xFF in a message frame means it came over a direct route, in a contact it
means the path is unknown (OUT_PATH_UNKNOWN: the next DM floods and the radio learns the path).

Sending (priority P0, `LinkRadioSession`): channel text is cut off at `160 - len("name: ")` bytes, a DM at 160. A channel send
answers only OK, never an ack. ERR(NOT_FOUND) is the firmware's answer both for a bad slot and for a full packet pool
(1190-1195): for a slot that exists the session retries once after 300 ms, then reports `noSuchChannel`. A command that gets no
answer within 5 s is reported as `queued` ("may still send"), never as failed. The flood scope (`ScopeGuard`) is set inside the
same queue slot, right before the send; a ping that follows a scoped chat message first clears the override, so a scope can
not leak into the wardrive channel (the override is global radio state, 491-525).

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
| 12 | Repeater login failure | `PUSH_CODE_LOGIN_FAIL` exists but a repeater never sends it for a wrong password; the app treats silence as "out of range or wrong password" (§2.5). |
| 13 | Companion CLI vs remote CLI | `CMD_RUN_CLI_COMMAND` (66, v14+) runs a CLI command on the COMPANION itself. Claims need the REMOTE repeater's CLI, which is `SEND_TXT_MSG` with txt_type 1 (CLI_DATA) after a login. |

| 14 | Message dedupe | The radio gives messages no id. The key is conversation + sender timestamp + delivered text (`InboundMessage.contentKey`), so a retried DM is one message. Two different messages with identical text in the same second from the same sender merge. |
| 15 | Ping airtime | Estimated with the Semtech formula from SELF_INFO's SF/BW/CR (`airtime.dart`; uses MeshCore's `preambleLengthForSF`: 32 symbols at SF8 and below, 16 above; a 37-byte ping is 386 ms at SF8/BW62.5 and 213 ms at SF7/BW62.5). Unknown radio settings: 500 ms. |

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

## 9. `meshcore://` links and QR payloads (chat)

Used to share a channel or a contact (a QR code carries exactly the link text). Source: MeshCore `docs/qr_codes.md` and MeshCore
Open `lib/utils/contact_qr.dart` (both MIT), re-implemented in `lib/chat/mesh_links.dart`; verified against the documented
examples in `test/chat/links_test.dart`.

| Link | Parameters |
|---|---|
| `meshcore://channel/add?name=<name>&secret=<32 hex>[&region_scope=<scope>]` | `secret` is the 16-byte channel key (the Public channel is `8b3387e9c5cdea6ac9e5edbaa115cd72`, base64 `izOH6cXN6mrJ5e26oRXNcg==`); `region_scope` needs MeshCore app 1.47+ |
| `meshcore://contact/add?name=<name>&public_key=<64 hex>&type=<1..4>` | type 1 companion, 2 repeater, 3 room server, 4 sensor |
| `meshcore://<hex>` (legacy) | a raw advert packet, 98..171 bytes, imported with `CMD_IMPORT_CONTACT` |

Names are URL-encoded (`+` or `%20` for a space on input; we emit `+`). Input is untrusted (camera, clipboard), so the parser
never throws and rejects with a reason: more than 2,048 characters; a name that is empty, over 31 UTF-8 bytes, or contains a
control, bidi-override or zero-width-no-break character; a secret or key that is not exactly 32 / 64 hex characters; an advert
outside 98..171 bytes. An out-of-range `type` is tolerated as unknown (like MeshCore Open). Hashtag channel secrets are the first 16 bytes of SHA-256
of the lower-cased name including `#` (§4); importing a link whose secret equals that derivation marks the channel `hashtag`,
one equal to the Public key marks it `public`, anything else `private`.

## 10. Chat on the radio link (what `lib/chat` expects from the radio layer)

Chat is decoupled from frames by two interfaces in `lib/chat/radio_bridge.dart`; `lib/chat/session_adapter.dart` adapts
`RadioSession` (lib/radio/session.dart) to them. Inbound texts arrive through `RadioSession.setInboundPersister`, so a message is
in SQLite before the radio's destructive queue is asked for the next one. `SEND_CONFIRMED` becomes an ACK match on any attempt of
a waiting DM. A `queued` send result (no answer from the radio in time) is retried with the SAME timestamp, which is safe because
receivers dedupe on (conversation, timestamp, text). The last DM attempt floods: the adapter sends `RESET_PATH` first (section 11). DM frames of text type 1 (CLI data) are not chat and are ignored.

## 11. Contacts: management frames, auto-add and the phone-is-master sync (M2, Nov 2026)

Layouts are from MeshCore `examples/companion_radio/MyMesh.cpp` and `src/helpers/BaseChatMesh.cpp` at 81dbae5 (MIT). Byte
fixtures written from the firmware, not through our encoders: `test/radio/contact_frames_test.dart`. "Hardware" is what has been
exercised on a real radio; everything else is **firmware-only** until Andy runs the checklist at the end of this section.

| Frame | Layout and behaviour | Firmware | Hardware |
|---|---|---|---|
| `GET_CONTACT_BY_KEY` (30) | `[30][pub x32]` -> `CONTACT` or ERR(NOT_FOUND) | MyMesh 1371 | verified (claims, Oct 31) |
| `ADD_UPDATE_CONTACT` (9) | adds if absent (ERR(TABLE_FULL) when the table is full), else updates; the radio re-stamps `lastmod` itself | 1328-1348 | verified for a new contact (claims); update / TABLE_FULL firmware-only |
| `EXPORT_CONTACT` (17) no key | the radio's own advert packet | 1379-1393 | verified (claims) |
| `EXPORT_CONTACT` (17) + key | `[17][pub x32]` -> `[11][advert packet]` or ERR(NOT_FOUND). The packet exists only if the RADIO heard that advert itself (`putBlobByKey`, BaseChatMesh 189-190): a contact written by `ADD_UPDATE_CONTACT` has none | 1394-1408 | firmware-only |
| `REMOVE_CONTACT` (15) | `[15][pub x32]` -> OK / ERR(NOT_FOUND); frees the slot | 1349-1358 | firmware-only |
| `RESET_PATH` (13) | `[13][pub x32]` -> OK / ERR(NOT_FOUND); `out_path_len` becomes 0xFF so the next message floods | 1317-1327 | firmware-only |
| `SHARE_CONTACT` (16) | `[16][pub x32]` -> OK after a zero-hop send of the stored advert packet, ERR(TABLE_FULL) when there is none | 1359-1370, BaseChatMesh 570-582 | firmware-only |
| `IMPORT_CONTACT` (18) | `[18][advert packet]` (> 98 bytes) -> OK, ERR(ILLEGAL_ARG) when it is not an advert. The packet is looped back **as if heard**: signature checked, the auto-add rules below apply | 1409-1415, BaseChatMesh 588-601 | firmware-only |
| `SET_OTHER_PARAMS` (38) | `[38][manual_add][telemetry][advert_loc_policy][multi_acks]`; **overwrites all of them**, so the app sends back what `SELF_INFO` reported for the three it does not change | 1488-1503 | firmware-only |
| `SELF_INFO` bytes 44-47 | `multi_acks, advert_loc_policy, telemetry_modes, manual_add` (before freq/bw); `manual_add` bit 0 = "ask before adding" | 1100-1104 | position verified (freq and bandwidth after them parse correctly on a real radio); the four values themselves firmware-only |
| `SET_AUTOADD_CONFIG` (58) | `[58][config][max_hops optional]` -> OK; max_hops clamps to 64 | 2023-2029 | firmware-only |
| `GET_AUTOADD_CONFIG` (59) | `[59]` -> `[25][config][max_hops]`; an older firmware answers ERR(UNSUPPORTED_CMD) and the app hides the per-type switches | 2030-2036 | firmware-only |

**Auto-add rules** (BaseChatMesh.cpp 156-186, MyMesh.cpp 304-340). A node heard advertising that the radio does not have:

- `manual_add` bit 0 **clear** (factory): the radio adds it to its table, whatever the type or hop count, and pushes plain `ADVERT` (0x80) with the
  key only (`is_new` is false once it is added), so the phone must read the contact back with `GET_CONTACT_BY_KEY`.
- `manual_add` bit 0 **set** ("ask before adding"): the radio adds it only if `autoadd_config` has the bit for its type
  (`0x02` chat, `0x04` repeater, `0x08` room, `0x10` sensor; default 0 = none) and the hop limit allows; otherwise it pushes
  `NEW_ADVERT` (0x8A, a full contact frame) and adds nothing. This is what "New nodes nearby" shows.
- The table is full: `NEW_ADVERT` then `CONTACTS_FULL` (0x90), unless `autoadd_config` bit 0 (overwrite oldest) is set, in which
  case the oldest **non-favourite** contact (`flags` bit 0) is replaced and `CONTACT_DELETED` (0x8F) tells the phone.
- Pushes only reach the phone while it is connected: adverts heard while the app was away are not remembered by the radio.
- A contact's `last_advert` must be the advert's **own** timestamp: the radio ignores an advert whose time is not newer than the
  stored one (replay check, BaseChatMesh 133). The app therefore stores the advert time with each node it offers and never
  writes the phone's clock there.

**Sync** (`lib/chat/contact_manager.dart`): the phone is the master copy of the contact list; the radio's table (DEVICE_INFO says
how big, 100 by default) is a cache of what it needs to send and receive DMs.

1. `GET_CONTACTS since <cursor - 1>`; a contact is merged into SQLite as its frame arrives (batches of 25), so a link that drops half way keeps what came. The cursor
   (`END_OF_CONTACTS` value) is stored only when a list ends properly; the `- 1` covers a contact that changed again in the same
   second as the cursor (the radio filters with `lastmod > since`).
2. `CONTACTS_START` carries the **total** on the radio. If it differs from the number the phone believes are on the radio, the
   phone reads everything (`since 0`) and marks the rest "not on radio" (never deletes them).
3. Then, in order: removals the user made while the radio was away; the favourite flag (`flags` bit 0) pushed for favourites; contacts the user added by hand, favourites and
   anyone with a conversation uploaded with `ADD_UPDATE_CONTACT` while there is room (a reserve of 5 slots is kept free for the radio's own use,
   except for contacts the user added on purpose).
4. Before every DM the adapter makes sure the radio holds the recipient (`GET_CONTACT_BY_KEY`, then `ADD_UPDATE_CONTACT`); a full table frees ONE slot
   by removing the least useful non-favourite contact with no conversation from the radio only, and the user is told.
5. A flood retry uses `RESET_PATH` instead of rewriting the contact; `PATH_UPDATED` reads that one contact back (`GET_CONTACT_BY_KEY`).
6. The download blocks the radio's command queue for its whole length (about 16 frames a second on BLE, so 350 contacts take about
   22 s). While a drive is running the automatic sync is held back (`ContactManager.shouldDefer`); a button press is not.

**Hardware checklist for Andy** (each step names what it proves; nothing here can hurt the radio's identity or keys):

1. Connect, open Chat > Contacts. The count under the search box ("On your radio: N of M") must match the official app's contact list. Note how long the
   first list takes (GET_CONTACTS pace). Proves GET_CONTACTS, DEVICE_INFO limits.
2. Pull down to refresh: it must finish at once with no change (incremental `since`).
3. Contact settings > turn on "Ask me before adding new nodes". Proves SET_OTHER_PARAMS keeps your other radio settings: check radio name, position policy, telemetry in the official app are unchanged.
4. Make a node the radio does not know advertise (a second radio, or `advert` on a repeater you manage). It must appear under New nodes
   nearby with the right name and type, and the radio's count must not grow. Proves NEW_ADVERT and the manual-add rule.
5. Add it: the count grows by one and you can message it. Ignore another: it disappears and does not come back.
6. Contact settings > "Still add automatically: Repeaters" on, then advertise another repeater: it is added by the radio. Proves SET_AUTOADD_CONFIG
   (if the switches are hidden, the firmware is older and answered UNSUPPORTED_CMD).
7. Message a person: the first message shows "flood", then "Delivered in N s"; open their details: a route with hops appears. The second message goes "direct". Proves
   SEND_TXT_MSG, SEND_CONFIRMED, PATH_UPDATED.
8. Switch the other radio off and send: three tries, then "Not delivered" with the reason in words.
9. Contact details > Reset route, then send: it floods again. Proves RESET_PATH.
10. Remove a contact you added: it must also be gone from the official app's list. Proves REMOVE_CONTACT.
11. Contact details > Send to radios nearby, with a second radio in range: it should offer the contact. Proves SHARE_CONTACT (needs a contact this radio heard itself).
12. Scan a contact QR from the official app, and show yours to it. Proves the `meshcore://contact/add` round trip.

## 12. Repeater and room administration (M4 part 1, Nov 2026)

Everything here was measured on a real repeater on Oct 31 2026 (INNO-OB-2, observer firmware v1.17.1.5, over a companion with firmware code
13) unless it says "firmware source". Full evidence, timings and logs: `meshsonar-infra/docs/planning/repeater-observer-live-research-2026-11-01.md`
and `research-logs/`. The parsers are pinned by `test/radio/repeater_wire_test.dart` with the captured hex.

**Requests (app to radio).** `CMD_SEND_BINARY_REQ 50 [pub_key x32][request]`, `CMD_SEND_ANON_REQ 57 [pub_key x32][request]`,
`CMD_SEND_TELEMETRY_REQ 39 [0 0 0][pub_key x32]` (the 4-byte form is the radio's own), `CMD_SEND_STATUS_REQ 27`. All answer `RESP_SENT [6][flood][tag u32][est_timeout u32]`; the answer is a later push. One request of each kind at a time (the companion keeps one pending slot per kind).

| Request | Bytes after the key | Answer |
|---|---|---|
| Neighbours (binary) | `[6][0][count][offset u16][order][prefix len][random x4]` (order 0 newest, 1 oldest, 2 strongest, 3 weakest) | `0x8C [0][tag u32][total u16][returned u16][per entry: prefix, seconds ago u32, snr i8 / 4]` |
| Access list (admin only) | `[5][0][0]` | `0x8C` data: 7-byte entries `[pub6][perm]`; perm 0 and all-zero entries are padding |
| Owner info | `[7]` | `0x8C` data: `version\nname\nowner` |
| Anonymous clock | `[3][0]` | `0x8C` data: `[clock u32][features u8]` (0x80 repeat disabled) |
| Anonymous regions | `[1][0]` | `0x8C` data: `[clock u32]["*,cmh"]` |
| Anonymous owner | `[2][0]` | `0x8C` data: `[clock u32]["name\nowner"]` |
| Status | (command 27) | `0x87 [0][pub6][RepeaterStats 56 bytes + 4 zero]` |
| Telemetry | (command 39) | `0x8B [0][pub6][Cayenne LPP, big endian, zero padded]`: `01 74 01 82` = 3.86 V, `01 67 01 C2` = 45.0 C |

The binary push `0x8C` carries the tag of the matching SENT frame (firmware source, `pending_req`); the app matches on it. Every answer is
zero padded to 16-byte blocks: trust the counts, not the length. Anonymous requests need no login, go direct only, and the repeater answers
4 per 180 s to everybody together (the 5th is silence). `RepeaterStats` (little endian, MyMesh.h): battery mV u16 @0, queue u16 @2, noise
floor i16 @4, last RSSI i16 @6, received u32 @8, sent u32 @12, air seconds u32 @16, uptime u32 @20, sent flood @24, sent direct @28, received
flood @32, received direct @36, error events u16 @40, last SNR x4 i16 @42, direct dups u16 @44, flood dups u16 @46, rx air seconds u32 @48,
receive errors u32 @52.

**CLI.** `SEND_TXT_MSG` type 1 (`CLI_DATA`) after an admin login; the reply is a queued contact message (type 1). The app prefixes every
command with a two-digit tag and a bar (`07|get radio`): the repeater reflects the tag (only when the command is longer than 4 characters),
so a late reply to an earlier command is never taken for the answer. Replies are cut near 160 characters (the tag counts); a command over
160 characters is dropped silently by the companion, the app caps at 150. About 3% of replies never arrive: reads are retried twice, writes
never (the value is read back instead). The repeater runs a CLI command only if its timestamp is newer than the last one it accepted; the
companion stamps CLI data with its own clock, and the app's counter only ever increases.

**Firmware quirks the app respects** (source: `CommonCLI.cpp`, `CommonRadioPrefs.cpp`, `simple_repeater/MyMesh.cpp`, `simple_room_server/MyMesh.cpp`
at MeshCore main, Oct 2026): commands match by PREFIX (`advertXYZ`, `rebootXYZ`, `verXYZ`, `clockXYZ`), so the app sends only exact strings it
has classified (`lib/radio/repeater_cli.dart`); `set repeat` treats anything but `off` as on; `setperm <key>` without a permission answers
`Err - bad params` (remove with `setperm <key> 0`, a partial key works only for removal, never the key you are logged in with);
`region load` swallows every following line and is never sent; `region default <name>` CREATES the region when the name is unknown, and
`region get/allowf/denyf/home` match by prefix, so the app only passes names it has just read; `password <new>` echoes the new password and
`get guest.password` prints it in clear: both are masked and never logged; a blank password re-admits any key already in the access list; a
password change does not remove admins; `set tx`, `set lat`, `set lon` have no range check (the app imposes one; a Heltec V4 reads `tx` 28);
`advert.interval` is stored halved and values under 60 turn it off; `set radio` is saved and used after a reboot (`OK - reboot to apply`);
`clock sync` only moves a clock forward.

**Rooms.** Login is the same `SEND_LOGIN`; the companion adds the 4-byte `sync_since` for a contact of type room (3). The room PUSHES each post
to every logged-in client as a normal text with `txt_type 2` (signed plain): `[timestamp][2 << 2 | attempt][author key prefix x4][text]`; the
companion queues it as `CONTACT_MSG_RECV_V3` with the 4-byte signer prefix. A post is a plain direct message (`txt_type 0`) to the room; the
room acknowledges it and echoes it to everyone. The room password gives read and write, the admin password admin, and with `allow.read.only`
on anyone logs in as a read-only guest who gets neither an ack nor the right to post. `RemoteLogin.aclPermissions` carries the stored role
(login push byte 12).
