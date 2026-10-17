# M1 spec: MeshSonar 0.4.0+5 (Report a problem, antenna picker, MeshMapper setting)

Status: draft for L approval. Author: S. Branch `m1/app-0.4.0` (from main 1735c26, 0.3.1+4). Plan: `meshmapper-build-plan.md`
M1 ("MeshSonar 0.4.0 ships in M1", Q4.19; Q4.14; Oct 17 follow-up to Q4.28), §6 ring 2, A3 (§16).
Server side: CMAT `docs/specs/m1-problem-reports.md` (branch `m1/problem-reports`), referred to below as **the CMAT spec**.
Release: rings 1 and 2 only (Andy, then invited testers).

## 1. User stories

- As a **tester** I tap "Report a problem", describe it, see exactly what will be sent, and send it; if I'm out of signal it waits for me.
- As a **driver** I tell MeshSonar once, per radio, how my antenna is mounted, its gain (or that I don't know) and its height,
  and change it later in Settings.
- As **Andy** I know MeshSonar sends drive data to one place only: the server in Settings.

## 2. Constraints

- **Drive Format v1 is unchanged** (`meshsonar.drive.v1`; CMAT `docs/MESHSONAR_DRIVE_FORMAT.md`, `src/lib/drive/validate.ts`).
  No new upload fields: v1.1 is held for Andy. `test/core/cmat_contract_test.dart` must pass unchanged against CMAT `main`.
- No new package dependencies.
- Bundle ID stays `net.innovatexit.meshsonar` (see §7).

## 3. Report a problem

**Where:**
- Settings → About section: new row "Report a problem" (key `report-problem`), above "About MeshSonar".
- Drive detail screen: overflow action "Report a problem with this drive" (pre-selects that drive).

**Needs a driver key** (`pending` or `approved`, matching the CMAT spec §5). Without a key, or with a rejected/revoked key,
the screen explains why and links to the Settings key section; Send is disabled.

**What the person fills in:** category (Bug, Radio, GPS, Upload, Map, Idea, Other → `bug|radio|gps|upload|map|idea|other`),
description (required, 1–4,000 chars, live counter), "Include app log" (on by default), "Attach drive" (none or one of the
recent drives; sends only its session id, never its pings).

**What the app adds automatically** (shown in the preview):
- `app`: name, version and build from `package_info_plus` (`loadAppInfo`, add `build`), platform.
- `device`: `{os: Platform.operatingSystem, osVersion: Platform.operatingSystemVersion, locale}` from `dart:io` / Flutter.
  No device model (would need a new dependency).
- `radio` (if connected): name, firmware, freq/bw/sf/cr/txDbm from `SelfInfo`. Not the radio's public key.
- `log` (if included): the in-app diagnostic log (below) plus a settings snapshot: server host, key status, channel, interval,
  minimum distance, auto-upload settings, antenna profile of the connected radio. **Never** the driver key or the full server URL path.

**Diagnostic log (new; the app has none today).** `lib/core/diagnostics.dart`, pure Dart: an in-memory ring of timestamped
(UTC ISO) lines, fed by: messages shown to the user (`_say`), radio connect/disconnect/errors, drive start/stop, each sync
attempt (counts, HTTP status, `friendlyError` text), repeater-directory refresh results, and caught exceptions (type + message,
no stack). **Decision (S, for L approval):** last 1,000 lines, memory only, cleared on app restart. Reason: nothing to migrate,
no file to secure, and it stays far below the 5 MB cap.

**Preview (required step):** "Review" opens a full screen showing the **exact JSON body** that will be sent, pretty-printed,
after redaction and rounding, with its size ("0.2 MB of 5 MB") and a line "We removed 2 keys and rounded 14 locations." The only
Send button is on this screen. Back returns to the form with nothing sent. The preview text is selectable and scrollable.

**Client-side redaction and rounding:** the CMAT spec §8 table (R1–R6, C1–C2), same order, same replacement text, applied
to description, log and every string in `app`/`device`/`radio`. Implemented in `lib/core/redact.dart` with Dart `RegExp`
(`caseSensitive: false` for the `i` patterns). Rounding: `sign × (|v| × 1000).round() / 1000`, printed with `toStringAsFixed(3)`.
The test copies CMAT's `redaction-vectors.json` to `test/fixtures/redaction-vectors.json` and must give identical output and counts.

**Size cap:** the encoded UTF-8 body must be ≤ 5,000,000 bytes (CMAT spec §5, A3). If it is larger, the oldest log lines are
dropped until it fits, and the preview says "Log shortened to fit 5 MB." If it is still too large without any log, Send is disabled
("Description too long").

**Sending:** `HttpCmatClient.reportProblem(driverKey, body)` → `POST <server>/api/cmh/problem-report` with `x-driver-key`,
timeout 30 s (the client's default). Contract exactly as the CMAT spec §5. Results:

| Server answer | App shows | Draft |
|---|---|---|
| 201 | "Sent. Thank you." + short report id (first 8 chars) | deleted |
| 401 / 403 | `friendlyError` text for the key | kept |
| 404 or 503 | "This server doesn't accept problem reports." | kept |
| 413 | "The report is too large." | kept |
| 429 | existing "server is busy" text | kept |
| network error / timeout / 5xx | "Not sent. Your report is saved on this phone; send it when you have signal." | kept |

**Offline: Decision (S, for L approval):** keep **one saved draft** on the phone (the last unsent report, as the previewed JSON
plus form state, in `report_draft.json` next to settings, written atomically like `FileSettingsStore`) and tell the person;
no background auto-send. Reason: the person approved one exact preview; sending later in the background would send a log they
can no longer see, and a second background sync path is new risk while drives are what must never break. Opening "Report a
problem" with a draft offers "Send saved report" (shows its preview again) or "Discard". A new report replaces the draft only
after confirming.

## 4. Antenna picker (Q4.14)

**Today:** one global `Settings.antenna` (`type` internal/external, optional `gainDbi`, `heightM`; `lib/core/api.dart`), set
in Settings → Antenna and by the Internal/External toggle on the drive screen (`AntennaToggle`, `drive_controls.dart:254`,
locked while driving). `startDrive` copies it into `DriveSession.antenna` (`app_state.dart:348`). Nothing is per radio.

**New model** (`lib/core/antenna_profile.dart`, pure Dart):
`AntennaProfile {mount: handheld | insideCar | roofMagMount | fixedMast, gainDbi: double? (null = "Don't know"), heightM: double, updatedAt}`.
Ranges as the server validator: gain −10…20 dBi, height 0…300 m (`validate.ts:77–79`). Height is required; only gain has
"Don't know" (Q4.14 wording).
Stored in settings as `antenna_profiles: {"<companion public key, lower-case hex>": {mount, gain_dbi, height_m, updated_at}}`.
Unknown mounts or out-of-range numbers in the file drop that one profile (never the rest of the settings), like `_antennaFrom`.

**Wire mapping (v1, unchanged):** `antenna.type` = `internal` for handheld / inside car, `external` for roof mag-mount /
fixed mast; `gain_dbi` = gain or `null`; `height_m` = height. The mount itself is not uploaded (no new field) and is not
stored in the drive; drive detail and report keep showing the v1 type as today.

**Required once at setup:** when a radio connects and its public key has no profile, the antenna sheet opens (title
"How is this radio's antenna set up?"): four mount choices with icons and one-line descriptions, gain field with a "Don't know"
switch, height field in metres. Save is disabled until mount and height are valid. "Start drive" is disabled with the hint
"Set up this radio's antenna" until a profile exists; tapping the hint reopens the sheet. Simulator radios follow the same rule.

**Existing drivers (migration, prompt once):** settings from 0.3.x have only `antenna`. On the first connect of each radio
after upgrading, the sheet opens prefilled from the old global setting: gain and height copied; mount left unselected but the
sheet notes "Before 0.4.0 you chose External" (or Internal) and offers the two matching mounts first. Once saved, that radio
never prompts again. The old `antenna` key is kept in the file (read-only, for this prefill) and is no longer used for drives.

**Editing later:** Settings → Antenna lists saved radios (name if known, else key prefix) with mount, gain and height; tap to
edit; "Forget" removes a profile (that radio prompts again on next connect). The drive-screen `AntennaToggle` becomes an
antenna chip showing the connected radio's mount ("Roof mag-mount · 5.8 dBi · 1.8 m"); tap opens the sheet; still locked while
driving. `setAntennaType` is removed.

**Drive start:** `startDrive` uses the connected radio's profile mapped as above.

## 5. Remove "also send to MeshMapper"

**Found in code:** there is **no** such setting and **no** code path that sends data to MeshMapper. `Settings` has no field
for it (`lib/core/api.dart`), the only HTTP clients are `HttpCmatClient` (the server in Settings) and `RepeaterDirectory`
(GET `https://map.meshcore.io/api/v1/nodes`, no location in the request), plus OSM map tiles. MeshMapper appears only in
attribution comments and the About screen's credits, which stay.
So the work is: (a) a test that guarantees it (AC-12), (b) `Settings.fromJson` keeps ignoring unknown keys, so any stray key
(e.g. `also_send_meshmapper: true`) is dropped on the next save (AC-13), (c) docs (`FEATURES.md`, `ROADMAP.md`) say
MeshSonar sends drives only to the configured server. No settings migration is needed.

## 6. Version

`pubspec.yaml` → `version: 0.4.0+5`. `test/app/app_version_test.dart`: the pubspec test expects `0.4.0+5` (name updated
to match). `CHANGELOG.md` gets a 0.4.0 entry.

## 7. Held decision: bundle ID

Changing to `com.meshsonar.app` is **out of scope** for this slice and held for Andy: a new ID installs as a separate app,
so the drives stored on his phone would not carry over. Plan §13.1 says the change happens "in M1 / 0.4.0 before the first
TestFlight upload"; that needs Andy's decision before ring 2 goes out on TestFlight.

## 8. Acceptance criteria

- **AC-1** `pubspec.yaml` is `0.4.0+5`; the version test checks it; no Dart file hard-codes a version.
- **AC-2** Report entry points exist (Settings row, drive-detail action); without a usable key Send is disabled with a link to the key section.
- **AC-3** Description 0 chars → Review disabled; 4,001 → blocked with the counter in error; 4,000 → allowed.
- **AC-4** Preview shows the exact bytes that `reportProblem` sends (test compares the preview string to the request body).
- **AC-5** Redaction: every vector in `test/fixtures/redaction-vectors.json` gives the expected output and counts;
  a log seeded with a driver key, a JWT, a bearer token, an MQTT URL password, `set mqtt1.password x` and
  `40.128091,-82.977705` reaches the request with none of them in clear and coordinates at 3 decimals.
- **AC-6** The driver key and full server URL never appear in the body, even when the log contains them.
- **AC-7** Body > 5,000,000 bytes → oldest log lines dropped, note shown, final body ≤ 5,000,000; never sent above.
- **AC-8** Each server answer in the §3 table gives the stated message and draft outcome (fake client).
- **AC-9** Offline: a network error keeps the draft on disk; after an app restart "Send saved report" shows the same preview
  and sends the same body; nothing sends without that tap.
- **AC-10** Contract: against CMAT's real `report-handlers.ts` (bun fixture, skipped when absent, like `cmat_contract_test.dart`)
  a report returns 201 and the stored text equals the app's redacted text.
- **AC-11** Antenna: connecting a radio without a profile opens the sheet and disables Start drive; saving enables it; the next
  connect of that radio doesn't prompt; a different radio does; profiles survive restart; edit and Forget work.
- **AC-12** Only the configured server, `map.meshcore.io` (GET) and tile hosts are ever contacted: a recording HTTP client
  through a full simulated drive, sync and report sees no other host, and no request body goes anywhere but the server.
- **AC-13** Settings JSON with an unknown `also_send_meshmapper` key loads normally and is gone after the next save.
- **AC-14** Upload mapping: handheld/inside car → `type:"internal"`, roof/mast → `"external"`; gain "Don't know" → `gain_dbi:null`;
  height passed through; the upload body validates with CMAT `readDriveUpload` and contains no new keys (golden JSON).
- **AC-15** Upgrade: 0.3.x settings with `antenna:{type:"external", gain_dbi:5.8, height_m:1.8}` prefill gain 5.8 and height 1.8,
  mount unselected, External-matching mounts first; nothing else in settings changes.
- **AC-16** Accessibility: every new control has a semantic label; sheet and preview work with large text (2.0×) and a
  screen reader; tap targets ≥ 48 dp; no overflow at 320 dp width.
- **AC-17** `flutter test` (whole suite) and `flutter analyze` pass.

## 9. Tests Q writes (red first)

Unit (pure Dart): `test/core/redact_test.dart` (AC-5, AC-6), `test/core/report_body_test.dart` (AC-4, AC-7),
`test/core/diagnostics_test.dart` (ring keeps 1,000, no key in snapshot), `test/core/antenna_profile_test.dart` (ranges,
mapping AC-14, bad entries dropped), `test/core/settings_store_test.dart` additions (AC-13, AC-15),
`test/core/cmat_client_test.dart` additions (`reportProblem` request shape, status mapping AC-8).
Widget: `test/ui/report_problem_test.dart` (AC-2, AC-3, AC-8, AC-9), `test/ui/antenna_setup_test.dart` (AC-11, AC-15, AC-16).
Contract: `test/core/cmat_contract_test.dart` extended + `test/fixtures/cmat_server.ts` serving `problem-report` (AC-10).
Network: `test/integration/hosts_test.dart` (AC-12). Version: `test/app/app_version_test.dart` (AC-1).
Fakes: `FakeCmatClient.reportProblem` records bodies and returns a scripted status; `FakeLink` gets distinct public keys.
Note: no Flutter SDK in the agent container; L runs `flutter test` on Andy's Mac (Q4.43) before review closes.

## 10. Out of scope

Bundle ID change (§7, held); Drive Format v1.1 fields, including mount on the wire (held); the default server URL change to
`cmh.meshsonar.com` (follows the M1 domain move); the Ping Standard and channel changes (M4); background report queue;
screenshots in reports; device model; persisting the diagnostic log; showing report status in the app (testers see it on
`/me/reports`).

## 11. Found in code / plan conflicts

- No MeshMapper sending code or setting exists (§5).
- Plan §13.1 schedules the bundle ID change for 0.4.0; held here (§7).
- Plan M1 lists "v1.1 basics" for 0.4.0 (Q4.19) and the default server URL change for 0.4.0; both are excluded here (v1.1 held
  by Andy, domain move not yet done).
- The app has no logging today; "sends app logs" (plan §6 ring 2) needs the new diagnostic log in §3.
