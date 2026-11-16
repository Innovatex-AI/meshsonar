# Asking a person for their location: MeshCore telemetry request (MeshTrack MT-13)

**Status: read from the firmware source only. NOT verified on hardware.** Andy decided on Nov 16 2026 to skip the spike
against a stock companion radio and ship "Ask for location" on this source reading. The first real answer from a stock
companion (with location allowed and not allowed) should be checked against this note; until then the app treats every
outcome it cannot see (no answer) the same way.

Source: `meshcore-dev/MeshCore` at commit
[`75b04ef`](https://github.com/meshcore-dev/MeshCore/tree/75b04ef06def54b348400cb1b138afb6749ffd4f) (main, Nov 15 2026).
Links below point at that commit. Companion protocol docs: [docs.meshcore.io/companion_protocol](https://docs.meshcore.io/companion_protocol)
(the same text as `docs/companion_protocol.md` in the repo); it documents the telemetry mode byte of SELF_INFO but not the
request or the 0x8B answer, so the frames below come from the C++.

Base for links: `https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/`

## 1. The request (phone -> our radio -> their radio)

| What | Where |
|---|---|
| `CMD_SEND_TELEMETRY_REQ = 39`, marked "can deprecate" in favour of `CMD_SEND_BINARY_REQ` | [examples/companion_radio/MyMesh.cpp L47](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L47) |
| Frame `[39][3 reserved][public key x32]` (length >= 36): looks up the contact, `sendRequest(contact, REQ_TYPE_GET_TELEMETRY_DATA, tag, est_timeout)`, answers `RESP_CODE_SENT [6][flood?][tag u32][est_timeout u32]`, or `ERR_CODE_NOT_FOUND` when the contact is not on the radio, `ERR_CODE_TABLE_FULL` when the send failed | [MyMesh.cpp L1680-L1699](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L1680-L1699) |
| Length exactly 4 = the radio's **own** telemetry (no air traffic) | [MyMesh.cpp L1700-L1718](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L1700-L1718) |
| `clearPendingReqs()` before the send: the radio keeps **one** pending remote request (login, status, telemetry, path discovery, binary). A second request of any kind makes the first answer unmatched, so the app serialises them (shared `RemoteRequestQueue`) | [MyMesh.h L192-L194](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.h#L192-L194) |
| `REQ_TYPE_GET_TELEMETRY_DATA = 0x03` | [MyMesh.h L76](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.h#L76) |
| On air: an encrypted `PAYLOAD_TYPE_REQ` datagram `[tag u32][0x03][4 reserved = 0][4 random]` to the contact. Direct along `out_path` when known, else flooded (scoped). `est_timeout` = `500 + 16 x airtime` (flood) or `500 + (6 x airtime + 250) x (hops + 1)` (direct) | [src/helpers/BaseChatMesh.cpp L690-L715](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/src/helpers/BaseChatMesh.cpp#L690-L715), [MyMesh.cpp L108-L111, L888-L896](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L888-L896) |

The 4 reserved bytes are zero, and the first of them is the receiver's **inverse permission mask** (`~0 = 0xFF`: nothing
masked), so this request asks for everything the other person allows.

## 2. What their radio does (companion firmware)

[`MyMesh::onContactRequest`, MyMesh.cpp L639-L686](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L639-L686):

1. Permissions start at 0. For each of base (battery), location and environment the owner's mode decides:
   `TELEM_MODE_DENY 0` (nobody), `TELEM_MODE_ALLOW_FLAGS 1` (contacts whose own flag bit is set), `TELEM_MODE_ALLOW_ALL 2`
   ([NodePrefs.h L7-L9](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/NodePrefs.h#L7-L9);
   all three default to 0 = deny, [NodePrefs.h L26-L28](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/NodePrefs.h#L26-L28)).
   With ALLOW_FLAGS the per-contact bits are `contact.flags >> 1` (bit 0 of `flags` is "favourite"), so the asker's
   location permission is bit 2 (`0x04`) of the contact's flags on **their** radio.
   Bits: `TELEM_PERM_BASE 0x01`, `TELEM_PERM_LOCATION 0x02`, `TELEM_PERM_ENVIRONMENT 0x04`
   ([src/helpers/SensorManager.h L6-L8](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/src/helpers/SensorManager.h#L6-L8)).
2. `permissions &= ~data[1]` (the mask from the request; 0 from our request, so no change).
3. **Only if the BASE bit is set** does it answer at all (L666). With base denied it returns 0: **no reply is sent** and the
   asker sees silence, exactly like out of range. On a factory radio all modes are DENY, so **the common answer is no answer**.
4. The answer is `[sender_timestamp u32][CayenneLPP]`: `addVoltage(1, battery)`, then `sensors.querySensors(permissions, lpp)`,
   then `addTemperature(1, MCU temperature)` when the board has one.
5. The owner sets the modes with `CMD_SET_OTHER_PARAMS [38][manual_add][telemetry_modes][advert_loc_policy][multi_acks]`,
   byte layout `env << 4 | location << 2 | base` ([MyMesh.cpp L1488-L1503](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L1488-L1503)),
   read back in SELF_INFO byte 46 ([MyMesh.cpp L1101-L1102](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L1101-L1102);
   docs "Byte 46: Telemetry Mode"). In the official app this is the telemetry settings (per the app guide cited in the
   MeshTrack plan section 16); the app copy says "their MeshCore app's telemetry settings" for that reason.

## 3. Which position is reported (GPS or advert lat/lon)

- The base `SensorManager::querySensors` adds **nothing** ([SensorManager.h L19](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/src/helpers/SensorManager.h#L19)).
  A board without a GPS-capable sensor manager never sends a position, whatever the permission.
- `EnvironmentSensorManager::querySensors` adds the GPS record only when `TELEM_PERM_LOCATION` is set **and** `gps_active`
  (GPS present and switched on): `addGPS(1, node_lat, node_lon, node_altitude)`
  ([src/helpers/sensors/EnvironmentSensorManager.cpp L684-L690](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/src/helpers/sensors/EnvironmentSensorManager.cpp#L684-L690)).
- `node_lat` / `node_lon` are **shared with the advert position**: loaded from the saved prefs at boot
  ([MyMesh.cpp L981-L982](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L981-L982)),
  set by the phone app's `CMD_SET_ADVERT_LATLON` ([MyMesh.cpp L1265-L1280](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L1265-L1280)),
  and overwritten by every valid GPS fix while the GPS is on
  ([EnvironmentSensorManager.cpp L931-L951](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/src/helpers/sensors/EnvironmentSensorManager.cpp#L931-L951)).
- So: **GPS on with a fix -> the live GPS position.** GPS on without a fix yet -> the last saved/advert position (possibly
  old), or **0, 0** if none was ever set. **GPS off or absent -> no position**, even if the person allows location and has a
  position in their adverts. The app drops 0, 0 as "no position" (`askedPositionUsable`).

## 4. The answer (their radio -> our radio -> phone)

- Our radio matches the response tag to `pending_telemetry` and pushes
  `PUSH_CODE_TELEMETRY_RESPONSE 0x8B`: `[0x8B][0 reserved][their public key prefix x6][CayenneLPP]`
  ([MyMesh.cpp L128](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L128),
  [L739-L749](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/companion_radio/MyMesh.cpp#L739-L749)).
  The LPP is the decrypted payload minus the 4-byte tag, so it is zero padded to the 16-byte cipher block.
- LPP GPS (type `LPP_GPS = 136`, 9 data bytes): latitude and longitude as signed 24-bit **big-endian** integers in units of
  **0.0001 degree** (about 11 m of latitude), altitude signed 24-bit in **0.01 m**
  ([src/helpers/sensors/LPPDataHelpers.h L29, L56-L57, L266-L285](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/src/helpers/sensors/LPPDataHelpers.h#L266-L285)).
  The value is `int32_t(lat * 10000)` of a `float`: **truncated toward zero**, so the reported point can be up to about 11 m
  off in each axis. Example (test fixture in `test/radio/tools/ask_location_test.dart`): 40.14725, -82.90461, 268.5 m ->
  `01 88 06 20 40 F3 59 8A 00 68 E2` -> 40.1472, -82.9046, 268.5 m.
- Big-endian LPP was verified on hardware earlier for battery and MCU temperature from a repeater (`lib/radio/tools/lpp.dart`
  header); the GPS record itself is unverified.

## 5. Repeaters and rooms

Repeaters and room servers answer telemetry only inside a logged-in session, and a guest gets base telemetry only (GPS is
masked off: [examples/simple_repeater/MyMesh.cpp L240-L250](https://github.com/meshcore-dev/MeshCore/blob/75b04ef06def54b348400cb1b138afb6749ffd4f/examples/simple_repeater/MyMesh.cpp#L240-L250)).
They are fixed sites whose position is in their announcement anyway. **Decision: Ask for location is offered for people
(companions) only.** Sensors keep their Telemetry tile, which already shows a position when the node sends one.

## 6. What the app does with this (MeshSonar)

| Rule | Value | Why |
|---|---|---|
| Who | companions (people), not blocked | section 5 |
| Request | `encodeTelemetryReqFor(key)` = `[39][0 0 0][key]` through the shared `RemoteRequestQueue`, `CommandPriority.user`; airtime recorded with `TxArbiter.admitUserSend` | one pending request in the firmware; user-initiated send |
| Wait for the answer | `askLocationWait`: at least 30 s when SENT says direct, 45 s when flooded, `2 x est_timeout + 3 s` if longer, never over 60 s | section 1 timeouts are 1-6 s on US presets; the floor covers busy repeaters and the radio's own queue |
| Same person again | once per 30 s (`AskLimiter`), kept across screens of one radio session; a request that never left the phone (no radio, not on the radio, radio busy) does not count | airtime |
| Outcomes | position -> distance and direction (Units) + an "Asked" pin on the Friends layer + Open on map; answer without position (or 0, 0) -> "did not share a location"; silence -> "No answer" + Try again; Cancel stops waiting (a late answer is ignored) | sections 2-4 |
| Privacy | the position is kept in memory only (radio session hub + map pin, off the map after 2 h, cleared by Delete my data), never uploaded, never in the last-known file, never logged with coordinates or names | MeshTrack plan section 6 |
| Our own radio's answers to others | unchanged: MeshSonar does not change the telemetry modes | Andy's MT-13 brief |

## 7. To check on hardware (when a stock companion is at hand)

1. Factory radio (all DENY): no 0x8B, the app shows "No answer" after 30-45 s.
2. Base allowed, location denied: 0x8B with voltage (+ temperature), no type 136; "did not share a location".
3. Location allowed (ALLOW_ALL), GPS on with a fix: type 136 present, the pin within about 11 m of the radio.
4. Location allowed, GPS off: no type 136 (expected from section 3).
5. Record the 0x8B bytes of cases 2 and 3 into `test/radio/tools/ask_location_test.dart` as captured fixtures.
