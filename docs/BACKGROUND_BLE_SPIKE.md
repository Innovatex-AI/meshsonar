# Spike S1: does the radio link survive iOS backgrounding?

Wave 2C, Nov 1 2026. Design doc: `meshsonar-infra/docs/planning/meshsonar-one-app-one-radio-design-2026-10-31.md` sections 4.1, 8 (M0, M3), 11 (R1, S1).
Results go in `meshsonar-infra/docs/planning/s1-ios-background-ble-results-template.md` (copy it, fill it in).

## 0. Status in one paragraph (read this first)

**Nothing about background delivery has been proven on a device.** What is proven is source reading and unit tests with a fake
radio: the app persists a frame before it asks the radio for the next, builds a local notification from the committed row,
and reconnects to the remembered radio after a start. What is unproven: that iOS keeps the link, wakes the app on a radio
message, or restarts a closed app. `flutter_reactive_ble` **cannot** be restarted by iOS (section 1). Three candidate fixes
are built, off by default, and the manual matrix in section 5 decides between them. Until it is run, the UI promises only:
"open the app to catch up; the radio keeps about 16 waiting messages".

## 1. Facts from source (nothing assumed)

`flutter_reactive_ble 5.4.1` / `reactive_ble_mobile 5.4.1` (BSD-3-Clause), pub cache `~/.pub-cache/hosted/pub.dev/reactive_ble_mobile-5.4.1/darwin/Classes`:

| Fact | Where |
|---|---|
| The `CBCentralManager` is created with `queue: nil` and **no options**: no `CBCentralManagerOptionRestoreIdentifierKey`. | `ReactiveBle/Central.swift:124-127` |
| `willRestoreState` / `RestoreIdentifier` appear **nowhere** in the plugin. The delegate implements only `centralManagerDidUpdateState`, `didDiscover`, `didConnect`, `didFailToConnect`, `didDisconnectPeripheral`. | `ReactiveBle/CentralManagerDelegate.swift:29-47`, grep over `darwin/` |
| `connect` is `centralManager.connect(peripheral)` with no options. | `ReactiveBle/Tasks/Connect/ConnectTaskController.swift:20` |
| A known radio can be found again after a start by its identifier (`retrievePeripherals(withIdentifiers:)`), so a Dart-side reconnect to the remembered id works without scanning. | `ReactiveBle/Central.swift:350` |
| Scanning passes `AllowDuplicates: true`; iOS ignores that in the background. We do not scan for a remembered radio, we connect by id. | `ReactiveBle/Central.swift:136` |
| Data reaches Dart through the plugin's Flutter event channel on the main thread. There is no headless/background isolate. So delivery while backgrounded works only while the process is alive and awake. | whole plugin; no isolate code |

MeshSonar's own state:

| Fact | Where |
|---|---|
| `UIBackgroundModes` already has `location` and `bluetooth-central`. Confirmed. | `ios/Runner/Info.plist:85-89` |
| `MessageSync` is persist-first: every frame is handed to the persister and awaited before `SYNC_NEXT_MESSAGE` goes out again (the radio's queue is destructive). | `lib/radio/message_sync.dart` (`_deliver`), `lib/chat/session_adapter.dart` (`bind`) |
| The radio's offline queue is 16 frames by default (256 on some builds), RAM only, not readable. A full queue evicts the oldest channel message or drops a new DM. | `docs/PROTOCOL.md` 6.3; firmware `MyMesh.cpp` 224-244 |

Other BLE plugins checked (pub cache and pub.dev archives, Nov 1 2026):

| Plugin | Licence | Restoration |
|---|---|---|
| `flutter_blue_plus_darwin 9.0.5` | FlutterBluePlus License: free for nonprofit/personal, **a paid licence for for-profit use** | Yes (`FlutterBluePlusPlugin.m:141, 1301`). **Excluded: licence.** |
| `universal_ble 3.1.0` (Navideck; 3.2.0 does not resolve with `battery_plus 7.1.2` because of `upower`) | **BSD-3-Clause** | **Yes, built in.** Central created at launch with restore id `com.universalble.central.restoration` when `bluetooth-central` is declared and permission is granted; `willRestoreState` re-adopts peripherals and emits `onConnectionChanged` (`darwin/.../UniversalBlePlugin.swift:78, 609`, read in 3.1.0, same in 3.2.0; README "iOS background state restoration"). |
| `bluetooth_low_energy_darwin 6.2.1` | MIT | No `willRestoreState` anywhere in the package. |
| `flutter_reactive_ble` (current) | BSD-3-Clause | No (above). |

## 2. What iOS does (Apple docs, per design doc 4.1; also TN3115)

With `bluetooth-central` the app can connect and interact in the background and is woken when a connection is made or lost
or a connected peripheral sends a characteristic update; after a wake it has roughly 10 seconds. A suspended app is not
woken for a peripheral it holds **unless** CoreBluetooth state preservation is on; after the system ends the app (jetsam),
only a central created with a restore identifier is restored and the app relaunched, and a **user swipe-kill is not
relaunched at all**. Bluetooth off or a reboot also end it. We cannot change any of this; we can only design for it and say so.

## 3. Options and what was built

| | Option | Verdict |
|---|---|---|
| (a) | Keep `flutter_reactive_ble`, rely on `bluetooth-central` only | Works only while iOS keeps the process alive and awake. After a system kill nothing restarts the app. Built-in baseline. Document its limits, do not promise. |
| (b) | Thin native Swift bridge: persist frames natively in a headless wake | Heavy (a second SQLite writer, decrypting channel messages natively, duplicating `ChatService`). **Not built.** If the matrix shows restoration works, this is only needed if 10 s is not enough for the Dart drain, which it should be. |
| (b-lite) | **`BleWakeKeeper` (ios/Runner/BleWakeKeeper.swift)**: a second, passive central WITH a restore identifier that holds a connection to the same radio and subscribes to its TX characteristic, so iOS has something to relaunch the app for. It reads nothing; it counts notifications and writes timestamped native events. After the relaunch Dart's `LaunchReconnect` brings the real link back and drains. | **Built, off by default** (Diagnostics switch "Experiment: wake keeper"). Unknown: two centrals in one app both subscribed to one characteristic; relaunch for a keeper-only subscription; unsubscribe by the plugin silencing the keeper. |
| (c1) | Switch to `flutter_blue_plus` | **No: licence.** |
| (c2) | **Switch to `universal_ble`** (BSD-3, restoration built in) | **Built as an experimental second engine** (`lib/radio/ble_transport_universal.dart`), off by default, chosen at each connect (Diagnostics switch "Experiment: other Bluetooth engine"). Not the default: not run on a device. If the matrix shows it restores and the connection is as good as the current engine, it becomes decision D2 (replace the plugin, delete the keeper). |
| (c3) | Patch `reactive_ble_mobile` (vendored, ~15 lines: restore id option + `willRestoreState`) | Not built; (c2) gives the same capability without owning a fork. Fallback if (c2) misbehaves. |

Side effect to know about: with `universal_ble` in the app, its iOS plugin creates its own `CBCentralManager` at launch
(restore id set) when Bluetooth permission is already granted, **even when the experiment is off**. That central holds no
connection, so it should be inert, but it is a change to every iOS build. If the matrix says (c2) is not wanted, remove the
dependency (`pubspec.yaml`, `lib/radio/ble_transport_universal.dart`, the wiring line in `lib/app/wiring.dart`).

## 4. What shipped in this branch (all unit-tested except native code)

* `lib/platform/local_notifications.dart` interface (+ plugin `local_notifications_plugin.dart` on `flutter_local_notifications 22.3.3`, BSD-3, the same plugin the official app and MeshCore Open ship). Permission is never requested at init.
* `lib/alerts/` : `AlertCoordinator` (chat event to notification / banner / nothing), `AlertPrefs`, `RadioQueueWatch`, `LaunchReconnect`, `LastRadioStore`, `BleLifecycleLog`, `AlertsRuntime`.
* UI: Settings > Notifications, the pre-prompt, in-app banner, status strip ("Reconnecting to <radio>…", queue warning), Diagnostics > Background Bluetooth test.
* Native: `ios/Runner/BleWakeKeeper.swift` (experiment) and badge channel in `AppDelegate.swift`; Android manifest + `MainActivity.kt` + `background_link_service.dart` (foreground service, **not compiled here: the Android toolchain is not installed**).
* Compile evidence: `flutter build ios --release --no-codesign` succeeded with all of the above (Runner.app 34.6 MB with the notification plugin and keeper; size with `universal_ble` in HANDOFF).

## 5. The manual test: step by step (Andy)

### What you need
* iPhone with a **release** build installed by the lead (`xcrun devicectl`, never `flutter install`). The iPad later, same script.
* The radio, charged, in range, and **a way to send it a message while you do not touch it**: best is a second MeshCore node (a second radio on the iPad running the official app or MeshSonar, or a friend). Without one, use a busy channel (Public) in a busy hour and accept organic traffic; then you cannot know what was sent, only what arrived.
* A paper or notes app for times. Phone clock = truth; the log has seconds.

### Setup (once per run)
1. Open MeshSonar. More > Settings > Notifications. Turn on, allow when asked. Check it says "Allowed and your radio is connected" (connect first if not).
2. More > Settings > Diagnostics > Background Bluetooth test. Press **Clear**.
3. Note the three switches for this run: engine (default flutter_reactive_ble), wake keeper (off), and which test below.
4. Settings > Display & Brightness > Auto-Lock: Never while you set up; set to 30 seconds for lock tests. Low Power Mode off unless the test says so. Note iOS version and the radio's firmware.
5. Add a note before each test: type "A3: locked 1 min, send at 10:42:00" and press Add note.

### Test matrix A: current engine, keeper off (the baseline)
| # | Do | Wait | Look for | Record |
|---|---|---|---|---|
| A1 | App in front on the Chat tab. Sender sends 1 message. | 10 s | An in-app banner, no OS notification | banner yes/no |
| A2 | Press Home (app visible in the switcher, screen on). Sender sends 1. | 20 s | OS notification within 15 s | seen at hh:mm:ss, or never |
| A3a | Lock the phone (side button). Sender sends 1 at +1 min. | 20 s | Notification on the lock screen; sound/haptic | seen at, latency |
| A3b | As A3a, sender sends at +5 min. | | | |
| A3c | +15 min | | | |
| A3d | +30 min | | | |
| A3e | +60 min | | | |
| A4 | Lock the phone. Sender sends 1 message every 10 min for 60 min (6 in all). Do not touch the phone. | at the end open the app | How many notifications you saw, vs 6. In the log: `drain N message frames` (those were waiting in the radio). The banner/strip may warn about the queue. | notifications seen (n/6); drain count; any `link disconnected` lines and when |
| A5a | Make iOS end MeshSonar for memory: lock the phone, then 5 minutes later open Camera, Maps, Safari with many tabs and a game for about 3 minutes, lock again. Sender sends 1. | 3 min | Did a notification arrive without you opening MeshSonar? Open MeshSonar: does the log have a `launch ... lifecycle=` line from a start you did not make (with `bg` lines right after)? | yes/no, the log |
| A5b | (Optional, from the Mac) `xcrun devicectl device process signal --signal SIGKILL --device <id> --pid <pid>`. Sender sends 1. | 3 min | Same as A5a. Note: iOS may not treat this as a system termination; either result is data. | yes/no, the log |
| A6 | Swipe MeshSonar away in the app switcher (user kill). Sender sends 1. | 3 min | Expected: **no** notification, **no** relaunch (iOS rule). Then open MeshSonar. | Within about 1 s of opening: strip "Reconnecting to <radio>…", then connected; the log shows `reconnect start`, `connected after N tries`, then `drain` with the waiting count |
| A7 | Background app, Control Center: Bluetooth off, wait 20 s, on. | 1 min | Does the link come back with the app still in the background? | log lines `link`, `reconnect` |
| A8 | Power-cycle the radio while the app is in front, then again while backgrounded. | 2 min | Reconnect in front: the engine's normal reconnect. Backgrounded: ? | log |
| A9 | Repeat A3b with Low Power Mode on. | | | |

### Test matrix B: wake keeper on
Diagnostics > Background Bluetooth test > switch **Experiment: wake keeper** on, then **disconnect and connect the radio once** (that arms the keeper). Repeat A3b, A5a, A6, A7. After each, press **Read native events** and look for `restore willRestoreState`, `notification while away`, `connected`, `notify-state isNotifying=true`. Also check the plugin's link still behaves in front (send and receive a message normally) and that **Disconnect** frees the radio for the official app (it must).

### Test matrix C: other engine
Switch **Experiment: other Bluetooth engine** on (keeper off), disconnect, connect, and repeat A1, A2, A3b, A3c, A4, A5a, A6, A7, A8. Also drive a short loop with pings and chat to confirm the connection is as solid as before: messages out, pings out, no extra drops.

### What to send back
For each row: the row id, the time you sent, what you saw and when, then in the app **Copy log** (it includes a header with versions, engine and keeper state) and paste it. Keep rows A3c, A4, A5a and A6 first if time is short: they decide the question. The log holds no message text, no keys, no positions.

### How to read the result (the decision rule)
* **Background delivery works (current engine)** only if A3c and A4 give a notification for every message in at least 2 of 3 runs. Anything less: the honest copy stays.
* **Restoration works** only if A5a (or A5b) shows a notification **or** a `launch` line you did not cause, plus a drain, without you opening the app, in at least 2 of 3 runs; for the keeper also a native `restore willRestoreState` event.
* Both pass for matrix C and not for A: replace the engine (decision D2). Matrix B passes and A5a fails for A: ship the keeper. None pass: keep the copy "open the app to catch up" and rely on the radio's queue plus the warning below.

## 6. The fallback that is always true (and is in the UI copy)

* Messages wait in the radio's RAM queue (16 by default). MeshSonar drains it on connect, on each `PUSH_MSG_WAITING`, and every 5 s while connected.
* After a drain of 12 or more frames (75% of 16) the Chat tab shows a warning; at 16 it says some may have been dropped. This is an after-the-fact estimate (the radio does not report its queue depth) and says "may".
* Settings > Notifications says: "You will not get messages while your radio is not connected" when it is not, and "iOS can pause MeshSonar when it is not in front, so alerts are not guaranteed. If one is missed, open the app".
* Reconnect-on-launch: the remembered radio (written when a Bluetooth radio connects, erased when you disconnect or hand it over on purpose) is retried 1, 3, 6, 10, 15, 20, 30, 30 s after a start or a return to the front, about two minutes in all, with "Reconnecting to <radio>…" shown, then a Reconnect button.

## 7. Android (not built or run here)

Foreground service of type `connectedDevice` through `flutter_local_notifications` (`background_link_service.dart`, manifest, core library desugaring, `MainActivity.kt` for the settings intent). `POST_NOTIFICATIONS` is requested through the same pre-prompt. Android has no 10 s limit but vendor battery killers exist. All of this is written to compile in principle; the Android toolchain is not installed and Android work is on hold, so none of it was compiled. Check it first when the SSD arrives.
