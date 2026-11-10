#!/usr/bin/env bash
# Verify an app build end to end on iOS simulators before hand-off.
#
# DEFAULT (Andy, Nov 10 2026, for speed): iPhone 17 Pro only, dark theme only, normal text size. iPad, light and AX3 runs
# are opt-in (DEVICES=..., VARIANTS=...) for when a change is specifically about them; Andy reports device problems himself.
#
# Drive visual matrix (plan WP-H, drive-map-redesign-plan section 22): with FLOW_TEST=integration_test/drive_visual_test.dart the
# script runs that harness once per device x VARIANT and writes frames to <out>/<device>/<variant>/NN-name.png plus log.txt and a
# summary.txt. Env: VARIANTS="dark:large" default (e.g. "light:large dark:large light:accessibility-extra-large") (appearance:content-size; AX3 is
# accessibility-extra-large), LANDSCAPE=1 also runs the iPad in landscape (light, large). The device "iPhone SE" resolves to the
# simulator MS-SE3 (375x667), created on demand with simctl. Order per variant: uninstall, install, grant location, set the
# simulated location, run (the grant comes AFTER the install, the old order made every frame show Location denied, 22.2 a).
# A run FAILS on any STEPFAIL, MISSING or OVERFLOW line.
#   FLOW_TEST=integration_test/drive_visual_test.dart DEVICES="iPhone 17 Pro|iPhone SE|iPad Pro 11-inch" scripts/verify_sim.sh <worktree>
#   scripts/verify_sim.sh <path-to-checkout-or-worktree> [out-dir]
# Env: DEVICES="iPhone 17 Pro" default (| separated name prefixes, e.g. "iPhone 17 Pro|iPad Pro 11-inch"), MODE=debug|release (default debug),
#      HARNESS=1 runs any SCREEN/FRAMES/VERIFY_DONE harness (e.g. integration_test/m2_map_visual_test.dart) the drive-matrix
#      way: built once, one run per VARIANTS appearance.
#      FLOW_TEST=integration_test/contacts_visual_test.dart runs that flow instead of the all-screens tour (Contacts and DMs).
#      OFFLINE_MAPS=1 also runs integration_test/offline_maps_test.dart (in-app download of the real CMH pack, then
#      z10/z14 light/dark shots of the offline map).
# For each device: boot, `flutter build ios --simulator`, install + launch com.meshsonar.app, then run
# integration_test/verify_screens_test.dart (screens listed in integration_test/screens.dart) and screenshot every
# "SCREEN <name>" it prints. Prints screenshot paths and the app's installed version. Talks to production, no sign-in.
set -euo pipefail

# SIM_SET=<dir>: use a private simulator device set in <dir> (e.g. on the internal SSD) instead of the default one. The default
# set lives on the external disk image here, and a debug app's sqlite migrations (fsync per statement) then block its main
# thread for minutes whenever other builds keep that disk busy (seen Nov 2 2026: splash screen for 10+ minutes). Devices
# are created in the set on demand (runtime RUNTIME, default iOS-26-5).
SIMSET=()
[ -n "${SIM_SET:-}" ] && { mkdir -p "$SIM_SET"; SIMSET=(--set "$SIM_SET"); }
# Default: the newest installed iOS simulator runtime (a pinned iOS-26-5 silently skipped the SE on a Mac with only 27.x).
RUNTIME="${RUNTIME:-$(xcrun simctl list runtimes available 2>/dev/null | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -t- -k2,2n -k3,3n | tail -1)}"
[ -n "$RUNTIME" ] || { echo "!! no iOS simulator runtime installed"; exit 2; }
sim() { xcrun simctl ${SIMSET[@]+"${SIMSET[@]}"} "$@"; }  # the +-expansion keeps bash 3.2 (macOS) happy under set -u with no SIM_SET

SRC="${1:?usage: verify_sim.sh <checkout> [out-dir]}"
SRC="$(cd "$SRC" && pwd)"
OUT="${2:-$HOME/meshsonar-verify/$(basename "$SRC")-$(date +%Y%m%d-%H%M%S)}"
MODE="${MODE:-debug}"
DEVICES="${DEVICES:-iPhone 17 Pro}"
BUNDLE=com.meshsonar.app
mkdir -p "$OUT"
cd "$SRC"
[ -f pubspec.yaml ] || { echo "no pubspec.yaml in $SRC"; exit 2; }
[ -f integration_test/verify_screens_test.dart ] || { echo "$SRC lacks integration_test/verify_screens_test.dart; merge main first"; exit 2; }

echo "== checkout: $SRC ($(git rev-parse --short HEAD 2>/dev/null || echo nogit)); pubspec $(grep '^version:' pubspec.yaml)"
[ -d lib/ui/region ] && echo "== region screens present: $(ls lib/ui/region | tr '\n' ' ')" || echo "== no lib/ui/region on this checkout"
flutter pub get >/dev/null

ensure_in_set() { # <device name> <device type id>: creates the device in the private set when missing
  sim list devices | grep -q "    $1 (" || sim create "$1" "$2" "$RUNTIME" >/dev/null
}

ensure_se() { # creates MS-SE3 (iPhone SE 3rd gen, 375x667) when missing
  sim list devices available | grep -q "MS-SE3 (" || sim create MS-SE3 \
    com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation "$RUNTIME" >/dev/null
}

pick_udid() { # name prefix -> udid of newest available match
  if [ -n "${SIM_SET:-}" ]; then
    case "$1" in
      "iPhone SE") ensure_in_set MS-SE3 com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation; set -- MS-SE3 ;;
      iPad*) ensure_in_set "WPH iPad Pro 11" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB; set -- "WPH iPad Pro 11" ;;
      *) ensure_in_set "WPH $1" "com.apple.CoreSimulator.SimDeviceType.$(echo "$1" | tr ' ' '-')"; set -- "WPH $1" ;;
    esac
  elif [ "$1" = "iPhone SE" ]; then ensure_se; set -- "MS-SE3"; fi
  sim list devices available | grep -F "$1" | grep -v "Pro Max\|13-inch" | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

# run_flow <integration test> <log>: runs it on $UDID, screenshots every "SCREEN <name>" line into $D. Retries once
# when the Xcode build behind `flutter test -d` produced no test run ("No tests ran": seen when another build held
# the simulator or DerivedData), and prints the build error instead of failing silently.
run_flow() {
  local TEST="$1" LOG="$2" try RC
  for try in 1 2; do
    echo "-- flow test ($TEST -d $UDID, try $try)"
    : > "$LOG"
    set +e
    flutter test "$TEST" -d "$UDID" 2>&1 | while IFS= read -r line; do
      echo "$line" >> "$LOG"
      case "$line" in
        *"SCREEN "*)
          name="${line##*SCREEN }"; name="${name%%[[:space:]]*}"
          f="$D/$(date +%H%M%S)-$name.png"
          sim io "$UDID" screenshot "$f" >/dev/null 2>&1 && echo "$f" ;;
        *APP_VERSION*|*DOWNLOAD*|*PACK_FILE*|*SKIPPED*|*FAILED*|*VERIFY_DONE*|*"All tests passed"*|*"Some tests failed"*|*"No tests ran"*) echo "$line" ;;
      esac
    done
    RC=${PIPESTATUS[0]}
    set -e
    if [ "$RC" -eq 0 ] && grep -q VERIFY_DONE "$LOG"; then return 0; fi
    if grep -q "No tests ran" "$LOG" && [ "$try" = 1 ]; then
      echo "!! no test ran (build problem?); last build lines:"; grep -iE "error|failed" "$LOG" | tail -5
      continue
    fi
    break
  done
  echo "!! $NAME: $TEST FAILED (see $LOG)"; grep -iE "error|exception|failed" "$LOG" | tail -5
  return 1
}

# build_drive_harness: builds the harness app ONCE (debug, simulator) from integration_test/drive_visual_test.dart. Every
# variant then installs and launches it; no per-variant xcodebuild (a build is 15-40 min on the HDD image).
build_drive_harness() {
  HARNESS_APP="$SRC/build/ios/iphonesimulator/Runner.app"
  if [ "${NO_BUILD:-0}" = 1 ] && [ -d "$HARNESS_APP" ]; then echo "-- harness build skipped (NO_BUILD=1)"; return 0; fi
  echo "-- harness build (debug, simulator, target $FLOW_TEST)"
  flutter build ios --simulator --debug --no-pub --target "$FLOW_TEST" 2>&1 | tail -3 | tee "$OUT/harness-build.log"
  [ -d "$HARNESS_APP" ] || { echo "!! harness build produced no Runner.app"; exit 2; }
}

# run_drive_variant <label> <appearance> <content size> <landscape 0|1>: one harness run, frames named NN-name.png.
# The app is launched straight from simctl with the variant in its environment; it prints SCREEN lines, we screenshot each.
run_drive_variant() {
  local LABEL="$1" AP="$2" CS="$3" LS="$4" V="$D/$1" WD
  mkdir -p "$V"; : > "$V/log.txt"
  sim ui "$UDID" appearance "$AP"; sim ui "$UDID" content_size "$CS"
  sim terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sim uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
  sim install "$UDID" "$HARNESS_APP"
  sim privacy "$UDID" grant location-always "$BUNDLE"   # after the install (a grant on an uninstalled app is lost)
  sim location "$UDID" set 39.9612,-83.0007
  export SIMCTL_CHILD_VT_CS="$CS" SIMCTL_CHILD_VT_APPEARANCE="$AP" SIMCTL_CHILD_VT_LANDSCAPE="$LS"
  # Dart print() of a debug app lands in the unified log; stream it, screenshot on every SCREEN line.
  local RAW="$V/raw.log" LP TP
  : > "$RAW"
  sim spawn "$UDID" log stream --style compact --predicate 'process == "Runner"' > "$RAW" 2>&1 &
  LP=$!
  sleep 3
  sim launch --terminate-running-process "$UDID" "$BUNDLE" >/dev/null
  ( sleep "${RUN_TIMEOUT:-1800}"; echo "flutter: STEPFAIL timeout: run exceeded ${RUN_TIMEOUT:-1800}s" >> "$RAW"; echo "flutter: VERIFY_DONE" >> "$RAW" ) & WD=$!
  while IFS= read -r line; do
    line="${line#*flutter: }"
    echo "$line" >> "$V/log.txt"
    case "$line" in
      *"SCREEN "*) n="${line##*SCREEN }"; n="${n%%[[:space:]]*}"
        sim io "$UDID" screenshot "$V/$n.png" >/dev/null 2>&1; echo "shot $LABEL/$n" ;;
      *STEPFAIL*|*MISSING*|*OVERFLOW*|*RUN_INFO*|*FRAMES*|*DIAG*) echo "$line" ;;
      *VERIFY_DONE*) echo "$line"; break ;;
    esac
  done < <(tail -F -n +1 "$RAW" 2>/dev/null | grep --line-buffered -E "flutter: |VERIFY_DONE")
  kill $WD $LP 2>/dev/null || true
  pkill -f "tail -F -n +1 $RAW" 2>/dev/null || true
  sim terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  unset SIMCTL_CHILD_VT_CS SIMCTL_CHILD_VT_APPEARANCE SIMCTL_CHILD_VT_LANDSCAPE
  local BAD; BAD=$(grep -cE 'STEPFAIL|MISSING |OVERFLOW' "$V/log.txt" || true)
  local N; N=$(find "$V" -name '*.png' | wc -l | tr -d ' ')
  local LINE="$NAME $LABEL: frames=$N stepfail/missing/overflow=$BAD $(grep -o 'RUN_INFO.*' "$V/log.txt" | head -1)"
  echo "$LINE" | tee -a "$OUT/summary.txt"
  if [ "$BAD" != 0 ] || ! grep -q VERIFY_DONE "$V/log.txt"; then FAIL=1; fi
  # every frame of the capture list must exist, and an AX run must really have run at a large text scale
  local FR; FR=$(grep -o 'FRAMES [0-9]*/[0-9]*' "$V/log.txt" | tail -1)
  local FN="${FR#FRAMES }"
  if [ -z "$FR" ] || [ "${FN%/*}" != "${FN#*/}" ]; then echo "!! $LABEL: ${FR:-no FRAMES line} (not every frame captured)"; FAIL=1; fi
  if [[ "$CS" == accessibility* ]]; then
    local TS; TS=$(grep -o 'text_scale=[0-9.]*' "$V/log.txt" | head -1 | cut -d= -f2)
    awk -v t="${TS:-0}" 'BEGIN{exit !(t>=1.5)}' || { echo "!! $LABEL: text scale ${TS:-?} is not an accessibility size"; FAIL=1; }
  fi
}

FAIL=0
is_harness() { [[ "${FLOW_TEST:-}" == *drive_visual_test.dart || "${HARNESS:-0}" = 1 ]]; }
is_harness && build_drive_harness
IFS='|' read -ra LIST <<< "$DEVICES"
for NAME in "${LIST[@]}"; do
  UDID="$(pick_udid "$NAME" || true)" # no match must reach the message below, not kill the script under set -e/pipefail
  [ -n "$UDID" ] || { echo "!! no simulator matching '$NAME'"; FAIL=1; continue; }
  SLUG="$(echo "$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9-')"
  D="$OUT/$SLUG"; mkdir -p "$D"
  echo; echo "===== $NAME ($UDID) -> $D"
  sim boot "$UDID" 2>/dev/null || true
  sim bootstatus "$UDID" -b >/dev/null
  [ -z "${SIM_SET:-}" ] && { open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true; }

  if is_harness; then
    for V in ${VARIANTS:-dark:large}; do
      case "$V" in
        light:large) L=light;; dark:large) L=dark;; light:accessibility-extra-large) L=ax3;; *) L="${V//:/-}";;
      esac
      run_drive_variant "$L" "${V%%:*}" "${V#*:}" 0
    done
    if [ "${LANDSCAPE:-0}" = 1 ] && [[ "$NAME" == iPad* ]]; then run_drive_variant landscape light large 1; fi
    sim ui "$UDID" content_size large; sim ui "$UDID" appearance light
    continue
  fi
  sim ui "$UDID" appearance "${TOUR_APPEARANCE:-dark}"   # the screen tour runs in one theme (default dark, Andy Nov 10)
  echo "-- build ($MODE, simulator)"
  flutter build ios --simulator "--$MODE" 2>&1 | tail -3 | tee "$D/build.log"
  APP="$SRC/build/ios/iphonesimulator/Runner.app"
  [ -d "$APP" ] || { echo "!! build produced no Runner.app"; FAIL=1; continue; }
  sim terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sim install "$UDID" "$APP"
  sim launch "$UDID" "$BUNDLE" >/dev/null
  sleep 6
  sim io "$UDID" screenshot "$D/00-launch.png" >/dev/null 2>&1
  echo "$D/00-launch.png"
  # fresh state for the flow test (first-run onboarding path); wipes only the simulator's app data
  sim terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sim uninstall "$UDID" "$BUNDLE" 2>/dev/null || true

  N=0
  run_flow "${FLOW_TEST:-integration_test/verify_screens_test.dart}" "$D/test.log" || FAIL=1
  grep -o 'APP_VERSION [^ ]*' "$D/test.log" | tail -1 > "$D/version.txt" || true
  if [ "${OFFLINE_MAPS:-0}" = 1 ]; then
    # Downloads the real CMH pack in-app (53 MB from tiles.meshsonar.com) and shows it at z10/z14 light/dark.
    run_flow integration_test/offline_maps_test.dart "$D/offline-maps.log" || FAIL=1
  fi
  [ "$FAIL" = 0 ] && echo "== $NAME OK: $(cat "$D/version.txt")"
done

echo; echo "Screenshots in: $OUT"; find "$OUT" -name '*.png' | sort
exit $FAIL
