# Improvement passes (field-test fixes before release)

Each pass: a real drive or device test, a list of what was found, what was fixed (with the PR), and what is still to verify on hardware. Add a new section per pass; keep the "Verify on device" list honest.

## Pass 1 (Oct 30-31, 2026), build 0.22.0+27

Found on Andy's first test drive (0.21.0): weather not logged, repeater names only on tap, hex grid not matching the zoom, "other items".

| # | Finding | Fix | PR |
|---|---|---|---|
| 1 | Weather not logged | Two app causes: a drive uploaded as plain v1, or before Weather was switched on, never sent `enrich.weather=true` (now re-sent once as a small ping-less v1.2 upload when the choice differs, on switch change and at launch, drives under 60 days); the report's Weather block went silent when config/key/switch/upload was missing (now always shows the missing condition or "added after upload, expect 2 to 3 hours"). Launch catch-up now retries after an offline failure. | #73 |
| 2 | Repeater names only on tap | Name beside every repeater (Drive, full-screen, drive detail, drive report), collision-avoided, zoom budget (none below zoom 9; 8/14/24/36/60 labels by zoom; heard-this-drive first, then nearest), halo for light/dark, Dynamic Type, VoiceOver "Repeater <name>". New **Repeater names** layer toggle (default on, `map_repeater_labels`). | #74 |
| 3 | Grid not matching zoom | Drive hexes were fixed at res 9 while the network layer followed zoom (5x larger at street level). One table (`coverageResForZoom`: res 7 from zoom 0, 8 from 11.5, 9 from 12.5, 10 from 14, 11 from 15.5) drives both; drive cells re-roll from res 11 on a band change. | #74 |
| 4 | Map overlays | Result flash / report card no longer cover the SIMULATED tag and age legend; captions only from zoom 10 (no piling on clusters); names avoid the heard box; no orphan names. | #74 |
| 5 | Stop drive without confirm | "Stop this drive?" with Keep driving default. | #76 |
| 6 | Drive tab unusable at large Dynamic Type (Start off screen) | Scrolling status area, pinned Start/Stop/Ping; chips cap their growth; test at 2x and 3.1x. | #76 |
| 7 | Stale wording: approval, "Request key", "server admin", "(or the simulator)" | About 25 strings reworded; key badge Waiting for the server / Ready to upload / Turned down / Switched off; `copy_consistency_test` fails if it returns. | #76 |
| 8 | Dropped radio showed "Not connected" while reconnecting | "Reconnecting..." with spinner. | #76 |
| 9 | Bluetooth permission refused, no way forward | Open Settings button. | #76 |
| 10 | Raw dBm to users | Strong / Good / Weak signal. | #76 |
| 11 | Tap targets under 44 px; VoiceOver stat tiles, onboarding dots | 48 px; one label per stat; "Page 2 of 3". | #76 |
| 12 | Layers sheet credited MeshCore Map twice | One line: "Data: MeshCore Map (map.meshcore.io), as of ...". | #75 |
| 13 | Simulator in a store app | Removed from release builds (`simulatorAvailable`); `scripts/verify_release_no_sim.sh` checks the binary. | #72 |
| 14 | Auto key, account deletion by key, BLE package, privacy page | See CHANGELOG 0.21.0/0.22.0 and HANDOFF §52-§53. | #70 #71 #177 #178 |

Gate on `main` for this build: `flutter analyze` clean, `flutter test` 1720 passed / 0 failed, release build verified free of Simulator strings.

### Verify on device (not provable in a simulator)
- Radio over the new Bluetooth package (flutter_reactive_ble): scan, connect, notifications, writes, drop and reconnect mid-drive, Bluetooth off and on.
- Drive tab during a live drive at the largest text size.
- Weather: after an upload, wait 2 to 3 hours; the report should show weather or a plain reason. Needs the website deploy for account deletion (separate).
- Locked-screen drive with navigation in front; the one-time "Always" location explainer.
- Hex grid on the live drive while pinching in and out; repeater labels density at your usual zoom.

### Next pass candidates
- Map: result flash can sit over a repeater on the small phone map.
- Settings order (Account & driver key first) kept; revisit once the automatic key has proven itself.
- MeshMapper share-back waits on their team (HANDOFF §54).
