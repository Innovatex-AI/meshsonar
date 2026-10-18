# Developing MeshSonar

Set-up, building, installing on an iPhone with a free Apple ID, running every kind of test, releases and versions.
Development so far has used Flutter 3.47.7 stable (Dart ≥ 3.13.5); `pubspec.lock` requires Flutter ≥ 3.44.

## 1. Set-up on a Mac

1. **Xcode** from the App Store (it includes the iOS SDK and simulators). Open it once to accept the licence and
   install the extra components, then run:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```
2. **Flutter** via Homebrew:
   ```sh
   brew install --cask flutter
   flutter doctor            # follow anything it flags for iOS / macOS
   ```
   The iOS and macOS projects use **Swift Package Manager** for plugins (`FlutterGeneratedPluginSwiftPackage` in the
   Xcode projects, no `Podfile`), so CocoaPods isn't needed.
3. **Get the code and packages:**
   ```sh
   git clone https://github.com/Innovatex-AI/meshsonar && cd meshsonar
   flutter pub get
   flutter analyze           # must say "No issues found!"
   flutter test              # ~3–4 min; see TESTING.md
   ```
4. Optional, for the contract and end-to-end tests: [bun](https://bun.sh) and a checkout of
   [meshcore-insights](https://github.com/Innovatex-AI/meshcore-insights) (CMAT). See §4.

## 2. Running on an iPhone with a free Apple ID

A free Apple ID ("Personal Team") is enough to run MeshSonar on **your own** devices. Builds signed this way **stop
launching after 7 days** and must be rebuilt and reinstalled. Free teams are also limited to a few apps per device and
a few new app ids per week. A paid Apple Developer account ($99/yr) removes the 7-day limit and allows TestFlight /
App Store distribution.

### 2.1 Signing: keep the team id out of the repo

The Xcode projects in the repo have **no `DEVELOPMENT_TEAM`** and use automatic signing. Your 10-character team id is
personal, so it goes in an **untracked** file instead of the project:

1. Xcode → Settings → Accounts → add your Apple ID. A "Personal Team" appears. Note its team id (also shown on
   developer.apple.com → Membership, or in Keychain Access on your "Apple Development" certificate as *OU*).
2. Create your signing file from the template and put your id in it:
   ```sh
   cp ios/Flutter/Signing.xcconfig.example ios/Flutter/Signing.xcconfig
   # edit it: DEVELOPMENT_TEAM = ABCDE12345
   ```
   `ios/Flutter/Debug.xcconfig` and `Release.xcconfig` (Release also serves Profile) end with
   `#include? "Signing.xcconfig"`. The `?` makes it optional, so builds without the file (CI, other contributors) still
   work. `ios/.gitignore` ignores `Flutter/Signing.xcconfig`, so `git status` never shows it.
3. **Don't pick the team in Xcode's *Signing & Capabilities* tab.** That writes `DEVELOPMENT_TEAM = …` into
   `ios/Runner.xcodeproj/project.pbxproj`, and a value there overrides the xcconfig. If it happened, revert those lines
   (`git diff ios/Runner.xcodeproj/project.pbxproj`) and the tab will show the team from `Signing.xcconfig`.
   - If Xcode says the bundle id `com.meshsonar.app` is unavailable (an id belongs to one team), you still
     have to change it locally in the project (e.g. `com.meshsonar.app.<yourname>`) and not commit that; the
     bundle id is set per target in `project.pbxproj`, so the xcconfig can't override it. To keep that local edit out
     of `git status`:
     ```sh
     git update-index --skip-worktree ios/Runner.xcodeproj/project.pbxproj   # undo with --no-skip-worktree
     ```

### 2.2 Prepare the phone

1. Plug the iPhone in with a cable, unlock it, and tap **Trust This Computer**.
2. Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode → On → restart → confirm. The switch
   appears only after the phone has been connected to Xcode once (Window → Devices and Simulators).
3. Find its identifier:
   ```sh
   xcrun devicectl list devices            # note the Identifier (UUID) of your phone
   ```
   After the first cable pairing, Xcode can also reach the phone over Wi-Fi on the same network.

### 2.3 Build and install

```sh
flutter build ios --release
xcrun devicectl device install app --device <device-identifier> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <device-identifier> com.meshsonar.app   # optional
```

On the first install, iOS refuses to open an app from an untrusted developer. Go to Settings → General → **VPN & Device
Management** → your Apple ID → **Trust**. You can also skip the CLI and use `flutter run --release -d <device>`, or
Run in Xcode.

**7-day expiry:** when the app stops opening ("no longer available"), run the build and install steps again. Your
drives aren't lost: reinstalling over the existing app keeps its data container. Deleting the app deletes its drives,
so export or sync them first.

## 3. Other platforms

| Target | Build | Notes |
|---|---|---|
| macOS | `flutter build macos` / `flutter run -d macos` | Sandbox entitlements include Bluetooth and location. Signing as above in `macos/Runner.xcworkspace`. |
| Android | `flutter build apk` / `flutter run -d <android>` | Release builds are signed with the **debug key** (template TODO in `android/app/build.gradle.kts`). See [PORTING.md](PORTING.md#android). |
| Linux | see §5 | |
| Windows | `flutter build windows` | Configured, not tested. |

## 4. Running the tests

See [TESTING.md](TESTING.md) for what each file covers. The commands:

```sh
flutter test                                   # everything (unit, widget, contract, end-to-end; live smoke skips)
flutter test test/core                         # storage, sync, settings, GPS filter, directory, CMAT client
flutter test test/radio                        # protocol, packets, crypto, link, engine, cadence
flutter test test/ui test/app                  # widgets and AppState upload behaviour
flutter test test/radio/packet_test.dart --plain-name "matchEcho"   # one test by name
```

### Contract and end-to-end tests (bun + CMAT)

`test/core/cmat_contract_test.dart` and `test/integration/end_to_end_test.dart` start
`test/fixtures/cmat_server.ts` with bun. That fixture imports **CMAT's real endpoint code**
(`src/lib/drive/handlers.ts` + `validate.ts`, with an in-memory store) and listens on a free localhost port.
Requirements:

- A CMAT checkout at **`/home/claude/meshcore-insights`**. This path is hard-coded in both tests and in the fixture's
  `import`. On a Mac, either clone it there (or symlink it), or edit the three paths locally.
- bun: the contract test looks in `$BUN`, `/root/.bun/bin/bun`, `$HOME/.bun/bin/bun`, then `which bun`. The
  end-to-end test only looks at **`/root/.bun/bin/bun`**.
- Install bun with `curl -fsSL https://bun.sh/install | bash`. The handlers only import their own sibling files
  (`validate.ts`, `types.ts`), so the checkout doesn't need `bun install`.

When either is missing, these tests **skip** (they don't fail).

### Live smoke test (opt-in)

`test/integration/live_smoke_test.dart` drives the simulator through the real engine and store, then syncs to a
**deployed** server and re-syncs (expecting duplicates only). It's skipped unless both variables are set:

```sh
MESHSONAR_LIVE_URL=https://meshsonar.com \
MESHSONAR_LIVE_KEY=<an APPROVED driver key> \
flutter test test/integration/live_smoke_test.dart
```

Use a test driver. It uploads a real (simulated) drive, so reject or revoke the key afterwards to keep it off the
public map.

### On-device flow test (integration_test) and screenshots

`integration_test/app_flow_test.dart` runs the **real app** (real wiring, storage and engine) with the Simulator
radio: first run → simulator drive → full-screen map → ping log → stop → drives list → drive detail → settings. It
prints `SCREEN <name>` and then holds still for 4 s at each key screen (`onboarding`, `drive-empty`, `connect`,
`drive-active`, `fullscreen-map`, `log`, `drive-stopped`, `drives`, `detail`, `settings`), so a script can take
screenshots.

On the iOS Simulator:

```sh
open -a Simulator
xcrun simctl boot "iPhone 16" 2>/dev/null || true          # any installed device type
xcrun simctl erase booted                                    # optional: clean first run (shows onboarding)
mkdir -p shots
flutter test integration_test/app_flow_test.dart -d "$(xcrun simctl list devices booted | awk -F'[()]' '/Booted/{print $2; exit}')" \
  | while IFS= read -r line; do
      echo "$line"
      case "$line" in *"SCREEN "*)
        name="${line##*SCREEN }"; xcrun simctl io booted screenshot "shots/${name}.png" ;;
      esac
    done
```

The same test runs on an Android emulator or a real device (`-d <id>`; take screenshots with `adb exec-out screencap -p`).

## 5. Linux build and Xvfb screenshot checks

Prerequisites (Debian/Ubuntu): `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`. Then:

```sh
flutter build linux --release            # → build/linux/x64/release/bundle/meshsonar
```

Headless screenshot check (used during development; `Xvfb` and ImageMagick `import` are needed, and `xdotool` for
clicks):

```sh
export DISPLAY=:97
Xvfb :97 -screen 0 1280x900x24 &         # the app opens a 1280×720 window
export XDG_DATA_HOME="$(mktemp -d)"      # fresh data dir → first-run intro, no old drives
MESHSONAR_THEME=dark build/linux/x64/release/bundle/meshsonar > app.log 2>&1 &
sleep 10 && import -window root shots/01-start.png
# drive the UI with xdotool, e.g.:  xdotool mousemove 1186 674 click 1   (the intro's Next button)
```

- `MESHSONAR_THEME=dark|light` forces the theme on desktop builds (`lib/ui/theme.dart`).
- Data goes to `$XDG_DATA_HOME/com.meshsonar.app/meshsonar/`.
- Use the **Simulator** under Xvfb. There is no BlueZ/D-Bus in a bare container: a Bluetooth scan fails, and an
  earlier run logged an unhandled `SocketException` from the D-Bus client. There's no GeoClue either, so real-GPS
  drives can't start.
- Expect harmless `libEGL ... DRI3` and `atk_socket_embed` warnings.

## 6. Bumping the version

One place holds the version: `pubspec.yaml` `version: X.Y.Z+N`. `X.Y.Z` becomes `CFBundleShortVersionString` /
Android `versionName`, and `N` becomes `CFBundleVersion` / `versionCode`. **Increase `N` on every build you
distribute.**

Since 0.3.0 the app reads it at run time with `package_info_plus` (`lib/platform/app_version.dart`, called from
`buildRealServices()` in `lib/app/wiring.dart`). That value is shown in Settings/About and sent as `app.version` in
every upload and export. If the platform can't report it, the version is sent as `null` (unknown), never guessed. The
defaults in `AppServices.appInfo` and `DefaultSyncService.app` carry no version; only tests use them.
`test/app/app_version_test.dart` fails if a Dart file under `lib/` hard-codes a version again.

Then add a section to [CHANGELOG.md](CHANGELOG.md).

## 7. Release checklist

- [ ] `flutter pub get`, then `flutter analyze` → *No issues found!*
- [ ] `flutter test` → all pass. Contract and end-to-end tests ran, not skipped: bun + CMAT checkout present.
- [ ] If the wire format changed: CMAT's `docs/MESHSONAR_DRIVE_FORMAT.md` and `validate.ts` agree, and the contract
      test passes against the CMAT commit that's deployed.
- [ ] Optional: the live smoke test against the deployed server with a test key (then revoke the key).
- [ ] `integration_test/app_flow_test.dart` on the iOS Simulator; check the screenshots by eye.
- [ ] Field check on a real radio: connect, join `#wardriving`, auto-pings and Ping now, echoes from a known repeater,
      heard box hold, Stop → upload → drive report.
- [ ] Version bumped in **both** places (§6); CHANGELOG updated; README version line updated.
- [ ] `THIRD_PARTY_NOTICES.md` up to date for any newly ported code. flutter_blue_plus licence category confirmed
      ([PORTING.md §4](PORTING.md#4-flutter_blue_plus-licence)).
- [ ] No personal data committed: no `DEVELOPMENT_TEAM`, driver keys, or local bundle-id changes.
- [ ] iOS: `flutter build ios --release` and install (§2.3). Remember the 7-day expiry for free-team builds.
- [ ] Tag and push (the maintainer commits; agents working on this repo don't run git).
