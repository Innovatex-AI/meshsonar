# App Store submission: MeshSonar (com.meshsonar.app)

Everything App Store Connect asks for, matched to what the app really does (audited against the App Review Guidelines on
2026-10-30). The privacy answers below mirror `ios/Runner/PrivacyInfo.xcprivacy` exactly; `test/ui/app_store_readiness_test.dart`
pins the plist, manifest and icon facts this document relies on.

## 1. Audit result (what was checked, what was fixed)

| Area | State |
|---|---|
| Privacy policy URL | `https://meshsonar.com/privacy` is live (HTTP 200). Linked in the app from Settings > Privacy & data sharing > Privacy policy, About, and the driver-key request form. **Content gap: see section 9, item 1.** |
| Account / data deletion (5.1.1(v)) | Settings > Privacy & data sharing > **Delete my data and account**: delete context and packet headers on the server, delete saved context on the phone, **Delete my account** (opens the website page that deletes account, drives, pings and revokes keys), delete all drives on this phone, remove the driver key from this phone. The account itself is a website account (emailed sign-in link); the deletion page is `/me/privacy` > "Delete my account". The server has no driver-key-authenticated account delete, so the in-app button hands off to that page. |
| Background location | Reality: "While Using" first, then the one-time "Always" upgrade after an in-app explainer (`always_location_screen.dart`). During a drive: `allowBackgroundLocationUpdates`, blue indicator, no auto-pause. Between drives: nothing in the background. The old low-power background region stream (idle watcher with "Always") was **removed** in this audit so background location is for recording a drive only, matching the permission string. |
| `bluetooth-central` | Real: the BLE link to the companion radio must survive a locked screen during a drive. App never advertises (peripheral string removed). |
| Info.plist | Added `ITSAppUsesNonExemptEncryption=false`, `UIRequiredDeviceCapabilities` (arm64, bluetooth-le, location-services). Removed unused `NSBluetoothPeripheralUsageDescription`. Location strings rewritten to match behaviour. No `LSApplicationQueriesSchemes` needed (only `launchUrl`, never `canLaunchUrl` on a custom scheme). No camera, mic, contacts, photos, tracking, local network keys: none are used. |
| PrivacyInfo.xcprivacy | Tracking false, no tracking domains, 8 collected types (section 5), required-reason API: file timestamps `C617.1` (own cache files: region cache, repeater reach, drive env cache). No other required-reason API in app code (no UserDefaults, disk space, boot time, active keyboard). Verified in the release build: 9 plugin bundles (share_plus, sensors_plus, device_info_plus, connectivity_plus, url_launcher_ios, wakelock_plus, geolocator_apple, battery_plus, package_info_plus) and Flutter.framework ship their own manifests (all tracking false, no tracking domains); flutter_blue_plus, path_provider and h3 ship none and use no required-reason API. Re-check in the Xcode Privacy Report on the archive (section 9). |
| Icons / launch | All sizes in `AppIcon.appiconset` present, every file opaque RGB (no alpha, 1024 marketing icon included). Launch storyboard is a branded dark teal with the logo, no placeholder. |
| Licences | Bluetooth is `flutter_reactive_ble` (BSD-3-Clause, free for commercial use); it replaced the paid-for-profit `flutter_blue_plus`. The in-app About list and THIRD_PARTY_NOTICES.md say so. "All package licences" opens Flutter's full licence page. |
| Simulator | Kept, clearly labelled everywhere ("SIMULATED GPS & RADIO" chip/map tag). Fixed: simulated drives are **never uploaded** and the simulator's packets are never shared (previously a keyed phone would have sent made-up Westerville drives to the community map). It is the reviewer path (section 7). |
| Permission denial | Location denied or off: the drive does not start and says how to fix it; Bluetooth denied/off: scan says so with a Settings pointer and offers the Simulator; Motion denied: reported, never nagged. Nothing crashes (existing tests `drive_flow_test`, `connect` flows). |
| iPad / Dynamic Type / dark mode / VoiceOver | All screens use `SafeArea`/lists, portrait and landscape on iPad (all four orientations enabled), dark theme (system), IconButtons all carry tooltips, map repeater and observer markers now carry VoiceOver labels (they had none). New test lays out the delete screen at 2x text on 1024x1366, 1366x1024, 507x1024 and 375x667 windows. Real-device VoiceOver/multitasking pass is still to do on the iPad (section 9). |
| Placeholder / debug UI | None found: no debug banners, no lorem text, no TODO screens reachable. |

## 2. Listing text

- **Name:** MeshSonar
- **Subtitle (max 30):** Map your MeshCore coverage
- **Category:** Primary **Navigation**, secondary **Utilities**
- **Price:** Free
- **Promotional text (max 170):** Drive, ping, and see which MeshCore repeaters hear you. Your drives stay on your phone and only join the public coverage map if you ask them to.
- **Description:**

  MeshSonar maps real-world MeshCore radio coverage by driving it.

  Connect your MeshCore companion radio over Bluetooth, press Start drive, and MeshSonar sends a ping on your channel at a steady cadence, listens for the repeaters that echo it, and records every ping with GPS. You see the result live on the map and afterwards in a drive report with signal strength, repeaters heard, and range.

  - Every ping is saved on your phone first. Nothing needs a connection.
  - Optional driver key: upload your drives to the community coverage map at meshsonar.com. Public views hide the start and end of every drive and anything inside your privacy zones.
  - Pings on the air carry only a random 10-character tag. Your position, name or radio identity are never put on the air.
  - Region awareness: the app tells you which MeshSonar region you are in and when you cross into another, including the region's radio settings.
  - Offline map packs for rural drives.
  - Export any drive as a file or a PDF report. Delete your data any time from Settings.
  - Works with iPhone and iPad. Dark mode, large text and VoiceOver supported.

  MeshSonar needs a MeshCore companion radio to record a drive. No radio? Try the built-in Simulator.

  Open source (MIT). Not affiliated with MeshCore.
- **Keywords (max 100, comma separated, no spaces):** `meshcore,wardriving,mesh,lora,repeater,coverage,radio,ham,gps,drive test,off-grid,signal` (98)
- **Support URL:** `https://meshsonar.com` (must carry a support contact: see section 9, item 1)
- **Marketing URL:** `https://meshsonar.com`
- **Privacy Policy URL:** `https://meshsonar.com/privacy`
- **Copyright:** 2026 MeshSonar contributors
- **Version / What's New (first release):** Welcome to MeshSonar. Drive, ping, map.

## 3. Age rating questionnaire

All "None" / "No": cartoon or fantasy violence, realistic violence, sexual content or nudity, profanity, horror, alcohol/tobacco/drugs, medical/treatment info, gambling, contests, unrestricted web access (the app only opens meshsonar.com pages and a map-pack download from our own host), user-generated content shared with others (public views are numeric coverage squares and callsigns; there is no chat, comments, photos or free text shown to other users), loot boxes. Result: **4+**.

## 4. Export compliance

Answer: **the app uses encryption, but only exempt encryption.** HTTPS (`NSURLSession` via `dart:io`/`http`) and the Bluetooth LE link's own OS-level pairing; no proprietary or non-standard cryptography. `ITSAppUsesNonExemptEncryption = false` is set in Info.plist, so App Store Connect will not ask on each build. (SHA-256 is used for ids and hashes only, not for protecting data.)

## 5. App Privacy questionnaire ("Data collection")

"Do you or your third-party partners collect data from this app?" **Yes.** Tracking: **No** (no data is used to track; no ATT prompt; `NSPrivacyTracking` false). All of it is **Linked to the user's identity** (it travels with the driver key) and **not used for tracking**. These match `PrivacyInfo.xcprivacy` one for one:

| Apple category > type | Linked | Tracking | Purposes | What it is |
|---|---|---|---|---|
| Location > **Precise Location** | Yes | No | App Functionality, Analytics | Where each ping of a drive you start was sent; altitude and direction of travel (stored on the phone; uploaded only when the server accepts it) |
| Identifiers > **User ID** | Yes | No | App Functionality | The driver key |
| Contact Info > **Name** | Yes | No | App Functionality | Typed when requesting a driver key; only the server admin sees it |
| Contact Info > **Email Address** | Yes | No | App Functionality | Optional, same request |
| Other Data > **Other Data Types** | Yes | No | App Functionality, Analytics | Headers of radio packets the radio hears (type, relay path, signal, time, region; no message content, no location); phone air-pressure readings |
| Diagnostics > **Performance Data** | Yes | No | App Functionality, Analytics | Phone battery level and charging state during a drive |
| Diagnostics > **Other Diagnostic Data** | Yes | No | App Functionality, Analytics | System version, phone model code, app build; the companion radio's battery, uptime, counters and settings; problem reports |
| User Content > **Other User Content** | Yes | No | App Functionality | The text of a problem report the person chooses to send |

Notes for the form: nothing is collected for advertising, third-party advertising, product personalization or marketing. Health & Fitness is not declared (barometer is not HealthKit). No data from a Simulator drive is collected. Some types (altitude/direction, barometer, battery, device, radio health) are recorded on the phone and uploaded only to a server that says it accepts them; they are declared anyway so the label never has to change. Users can turn each category off in Settings > Privacy & data sharing and erase it from the server in Settings > Delete my data and account.

## 6. Permission strings as shipped

- Bluetooth: "MeshSonar connects to your MeshCore companion radio over Bluetooth to send wardriving pings and hear repeater echoes."
- Location (When In Use): "MeshSonar records where each ping was sent so your drive can be mapped, and shows which MeshSonar region you are in."
- Location (Always and When In Use): "While you record a drive, MeshSonar keeps placing each ping on the map when the screen is off or another app (like navigation) is in front. iOS shows a blue indicator while it does. Your position is not used in the background when you are not recording a drive, and is never put in the on-air ping."
- Motion & Fitness: "MeshSonar reads air pressure from your phone's barometer during a drive, to explain changes in radio range. It is saved with your drive. You can turn it off in Settings > Privacy & data sharing."

The app works fully on "While Using" (drives need the screen on or the app visible) and degrades honestly: it explains the Always request first and never asks twice.

## 7. App Review notes (paste into "Notes")

> MeshSonar is a companion app for MeshCore LoRa mesh radios (a small battery-powered radio the user pairs over Bluetooth). It records radio coverage while driving. A physical MeshCore radio is not required to review the app: it has a built-in **Simulator** that plays a pretend radio and GPS, labelled "SIMULATED GPS & RADIO" everywhere. Simulator drives are stored on the device only and are never uploaded.
>
> To see it work without hardware:
> 1. Launch the app and swipe through the intro. On the third page ("Connect your radio") tap **Try the Simulator**. (Later: Radio tab > Connect > Simulator (no radio).)
> 2. If a privacy disclosure sheet appears, tap **Continue**.
> 3. A "How is this radio's antenna set up?" sheet appears. Type any gain (for example 3) and height (for example 1.5), tap **Save antenna**.
> 4. On the Drive tab tap **Start drive**. Allow location "While Using". An explanation screen about "Always" location appears once; **Continue** (asks iOS for Always) or **Not now** both work. The simulated car drives a loop around Westerville, Ohio; pings, repeater echoes and the live map update every second. Tap **Stop drive**; open the Drives tab for the report.
> 5. Settings > Privacy & data sharing shows every data switch, the privacy policy link, and **Delete my data and account** (account deletion and data erasure).
>
> Accounts: none are required. A "driver key" (optional) is requested in Settings > Account & driver key to upload real drives to meshsonar.com; reviewers do not need one. Account deletion is in Settings > Privacy & data sharing > Delete my data and account; "Delete my account" opens meshsonar.com/me/privacy where the signed-in user deletes the account.
>
> Background modes: **location** is used only while a drive is recording, so pings keep their position when the screen is off or navigation is in front (the blue location indicator is shown). **bluetooth-central** keeps the link to the paired radio alive during that drive. Nothing runs in the background when no drive is recording.
>
> Nothing is sent on the air that identifies the user: the ping text is "MS:" plus 10 random characters.

Demo account: none needed. Contact: Andy (KE4BFI), alamb@innovatexit.com, phone number in App Store Connect.

## 8. Screenshots (required: 6.9-inch iPhone 1320x2868 or 6.5-inch 1284x2778, and 13-inch iPad 2064x2752; capture from the Simulator/iPad Pro with the app's Simulator mode, dark and light)

1. Drive tab mid-drive, map with ping dots and repeaters (Simulator, "SIMULATED" tag visible).
2. Heard-box / repeater detail sheet.
3. Drive report (SNR chart, repeaters heard).
4. Region tab with a region's coverage and radio settings.
5. Drives list with uploaded/not-uploaded states.
6. Settings > Privacy & data sharing (switches, policy link, delete my data and account).
7. Offline map packs.
8. iPad: Drive tab in landscape.

Capture with `xcrun simctl io booted screenshot` in the matching simulator; no device frames needed.

## 9. Pre-submission checklist

Do in this order. Items 1 and 2 block review or legality and are recorded in `meshsonar-infra/docs/HANDOFF.md`.

1. **Website privacy policy content.** `https://meshsonar.com/privacy` explains what is public but does not yet list what the *app* collects, retention, or a contact address. Guideline 5.1.1(i) requires that. Add to meshcore-insights `src/routes` privacy page: the table in section 5 (what, why, linked to driver key), "Bluetooth, location and motion permissions: what for", retention, how to delete (in app and `/me/privacy`), contact `alamb@innovatexit.com`, and that the Simulator shares nothing. Make `https://meshsonar.com` also show a Support contact (support URL).
2. ~~FlutterBluePlus commercial licence~~ Resolved: the BLE package was replaced by flutter_reactive_ble (BSD-3-Clause). A real-radio test of connect, notify and write on iPhone and iPad is required before the first TestFlight upload.
3. App Store Connect: create the app record with bundle id `com.meshsonar.app`, fill sections 2 to 5.
4. Signing: in Xcode set the Team, let it manage signing; `flutter build ipa --release` then upload with Transporter (or Xcode Organizer). Do **not** use `flutter install` on the phone.
5. Open the archive's **Privacy Report** (Xcode Organizer > Generate Privacy Report) and confirm the aggregated manifest shows only the types in section 5 and no plugin declares an extra tracking domain.
6. TestFlight internal group (iPhone 16 Pro Max, iPad Pro): test on device: Bluetooth permission prompt, Location "While Using" then "Always" upgrade, locked-screen drive with navigation in front (ROADMAP P1), blue indicator, Motion prompt, VoiceOver on Drive/Connect/Settings, iPad portrait + landscape + Split View/Slide Over, largest Dynamic Type (Accessibility sizes), dark mode, deny each permission in turn and confirm the app explains and does not crash.
7. Bump `pubspec.yaml` version/build and `test/app/app_version_test.dart` together (lead does this once).
8. Run the gate: `flutter analyze`, `flutter test`, `flutter build ios --release --no-codesign`.
9. Fill App Review notes (section 7), screenshots (section 8), age rating (section 3), export compliance (section 4).
10. Submit for review.
