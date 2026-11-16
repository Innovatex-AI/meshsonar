# MeshTrack core API (lib/core/meshtrack)

This is pure Dart, with no Flutter imports and no new dependency. Spec: meshsonar-infra `docs/planning/meshtrack-plan-2026-11-16.md`.
The app wires **one** `MeshTrackService`. Everything else here is a helper that the service uses or that the UI can call directly.

## Files
| File | What it holds |
|---|---|
| `plus_code.dart` | `PlusCode.encode / tryDecode / isValid / isFull / isShort / recoverNearest / shorten`, and `PlusCodeArea` (centre `lat`/`lon`, `heightM`). It follows the Open Location Code spec and is tested against the upstream vectors in `test/fixtures/olc/`. |
| `mt_wire.dart` | `parseMeshTrack(body) -> MtMessage?`. It returns null when the text is not MT1, so the text stays chat. The sealed types are `MtPosition`, `MtRequest`, `MtMeet`, `MtMeetClear` and `MtStop`. Formatters: `formatMtPosition`, `formatMtParked`, `formatMtRequest`, `formatMtMeet`, plus the constants `kMtMeetClearText` and `kMtStopText`. |
| `smart_beacon.dart` | `MtFix` (the fix value type), `MtRate`, `SmartBeacon` (rate logic), `meshTrackPositionAirtime(sf:, bwKhz:, cr:)`, `bearingDeg`, `angleDiffDeg`. |
| `track_group.dart` | `MeshTrackGroup.eligible(Channel, {wardriveChannelName, secret})`, `TrackGroup` (one group's friends), `MtFriend`, `MtMeetPin`, `MtTrailPoint`, `MtStaleness`, `mtStaleness`, `mtEffectiveTime`. |
| `interop.dart` | `parseInterop(body, {refLat, refLon})`. It reads typed Plus Codes, `lat, lon`, `geo:` URIs and MeshCore-TEAM `#TEL:` / `#CAP:` messages. It also defines `MtSource`. |
| `meshtrack_service.dart` | `MeshTrackService` and its types: `MtGroupConfig`, `MeshTrackState`, `MtGroupView`, `MtEvent`, `MtResult`, `MtShareReason`, `MtInboundText`, `MtPingWindow`, `MtLastKnownStore`, `MtBudget`. It also re-exports the types the UI needs. |

## Construction (app wiring, MT-5)
```dart
final mt = MeshTrackService(
  sendChannelText: (channelId, text) async => ...,   // RadioSession.sendChannelMessage on that channel's slot,
                                                     // with the channel's regionScope, else the drive's flood scope
  budget: (channelId, text) => ...,                  // TxArbiter TxPriority.track + ChatService.maxTextBytes -> MtBudget
  zones: () => privacyZoneStore.current,             // PrivacyZones (loaded flag included; not loaded = nothing sent)
  selfName: () => radio.selfName,
  lastKnown: FileStore('<app support>/meshtrack_last.json'),   // implements MtLastKnownStore
  positionAirtime: () => meshTrackPositionAirtime(sf: p.sf, bwKhz: p.bw, cr: p.cr),
  log: diagnostics.add,                              // lines never carry codes, coordinates or names
  onGroupsChanged: (list) => settings.meshtrackGroups = list,  // persist as meshtrack.groups (MtGroupConfig.toJson)
);
await mt.start();                                    // reads last-known (24 h TTL), starts the 15 s staleness tick
mt.loadGroups(settings.meshtrackGroups);             // Share forced off at app start (never resumes by itself)
```
The clock (`now:`) and randomness (`random:`) are injected. Tests use fakeAsync.

## Inputs (who calls what)
| Call | Caller |
|---|---|
| `onFix(MtFix)` | Drive location stream, or the phone location while sharing without a drive. Map `GeoFix` fields lat, lon, accuracyM, speedMps, courseDeg and `at`. |
| `setRadioConnected(bool)` | Radio session state. Sends pause while disconnected; sharing ends after 5 min. |
| `setPingWindow(MtPingWindow(listening:, nextPingAt:))` | Every `EngineStatus`: `listening = state == pinging \|\| heardSoFar != null`, `nextPingAt = EngineStatus.nextPingAt`. |
| `driveStarted()` / `driveStopped()` | AppState drive start and stop. |
| `chat.addChannelTextTap(mt.channelTextTap)` | Register once (MT-4 seam, `lib/chat/channel_text_tap.dart`). Consumed MeshTrack text is never stored, notified, backed up or indexed. Typed positions pass, so they stay chat. |
| `onChannelText(MtInboundText) -> bool` | The same decision without the tap: `MtInboundText(text: 'name: body', ...)` or `MtInboundText.fromTapEvent(e)`. |
| `syncGroups(List<MtGroupConfig>)` | When channels change (rename, removal, `onRadio: false` for "Not on this radio"). |

## Commands (UI, MT-6)
| Command | Result |
|---|---|
| `addGroup(channelId, name)` | New, Join or Use with MeshTrack. Check `MeshTrackGroup.eligible` first. |
| `setShare(id, on, duration: thisDrive/oneHour/untilStopped)` | `MtResult.ok / tooManyGroups (max 3) / notOnRadio`. Turning Share off sends `MT1 x` once. |
| `setSee(id, on)`, `setShareEveryDrive(id, on)` | |
| `sendMyPosition(id)` | One shot. Returns `ok / privacyZone / zonesNotLoaded / waitingForGps / radioDisconnected`. |
| `askWhereAreYou(id, {name})` | Returns `ok`, or `tooSoon` within 60 s. `MtGroupView.askedUntil` drives the "Asked" label. |
| `meetHere(id, lat, lon, {label})`, `clearMeet(id)` | Meet pins obey the privacy zones. |
| `leaveGroup(id) -> MtGroupConfig?`, `restoreGroup(config)` | Leave, and its Undo. Leave sends `MT1 x` and forgets the group's friends. |
| `setPositionMode(exact/approximate)`, `setRate(smart/lowTraffic)`, `setAnswerRequests(bool)` | Settings > MeshTrack. Persist them in app Settings and pass them in at start. |
| `clearLastKnown()` | Delete my data. |

## Outputs
- `state` (`MeshTrackState`), `addListener` / `removeListener` (Listenable shape), and the `states` stream. Fields:
  - `reason` (`MtShareReason`) is the chip and sheet header text: off, sharing, waitingForDrive, waitingForGps, privacyZone, zonesNotLoaded, airtimeLimit, radioDisconnected.
  - `sharingNames` gives "Sharing: Family, Club". `myLastSent` is the hollow ring on the map. `canShareMore` tells whether a 4th Share switch is allowed.
  - `groups` is a list of `MtGroupView`:
    - `config`, `sharingNow`, `heardLast30Min`, `meet`, `askedUntil`, `lastSentAt`.
    - `friends` is a list of `MtFriend`: name, lat, lon, accuracyM, speedKmh, courseDeg, lastHeard, staleness (fresh/faded/grey/listOnly), `onMap`, `jumped` ("position jumped"), `typed`, `source`, `parked`, `stopped`, `snr`, `pathLen` (0 means direct), and `trail` (`breakBefore` marks a jump; draw no segment there).
- `events` stream:
  - `MtAskedWhileNotSharing(channelId, name)`: toast "Sam asked where you are" with a Send my position action.
  - `MtSharingStopped(channelId, cause)`: toast "Stopped sharing: radio disconnected" with Share again, or the Undo of a user stop.

## Rules the service enforces
- Smart rate, the airtime floor, and multi-group sends 3 s apart.
- No send inside a ping listen window, within 3 s of a due ping, or less than 1 s after the window closes.
- Privacy zones plus a 200 m buffer (plus the fix accuracy). Zones not loaded means nothing is sent.
- Accuracy must be 100 m or better and the fix at most 30 s old.
- Requests are answered after a random 2-10 s delay, at most once per 30 s per group, and only while sharing.
- Friends: per-name 5 s rate limit, 32-name cap, 256-entry duplicate LRU, 300 km/h jump rule.
- Staleness: fresh under 5 min, faded 5-15 min, grey 15 min to 2 h, list only 2-24 h, then dropped.
- Positions are never logged.
