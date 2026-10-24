#!/usr/bin/env bash
# Verify an app build end to end on iOS simulators before hand-off.
#   scripts/verify_sim.sh <path-to-checkout-or-worktree> [out-dir]
# Env: DEVICES="iPad Pro 11-inch|iPhone 17 Pro" (| separated name prefixes), MODE=debug|release (default debug)
# For each device: boot, `flutter build ios --simulator`, install + launch com.meshsonar.app, then run
# integration_test/verify_screens_test.dart (screens listed in integration_test/screens.dart) and screenshot every
# "SCREEN <name>" it prints. Prints screenshot paths and the app's installed version. Talks to production, no sign-in.
set -euo pipefail

SRC="${1:?usage: verify_sim.sh <checkout> [out-dir]}"
SRC="$(cd "$SRC" && pwd)"
OUT="${2:-$HOME/meshsonar-verify/$(basename "$SRC")-$(date +%Y%m%d-%H%M%S)}"
MODE="${MODE:-debug}"
DEVICES="${DEVICES:-iPad Pro 11-inch|iPhone 17 Pro}"
BUNDLE=com.meshsonar.app
mkdir -p "$OUT"
cd "$SRC"
[ -f pubspec.yaml ] || { echo "no pubspec.yaml in $SRC"; exit 2; }
[ -f integration_test/verify_screens_test.dart ] || { echo "$SRC lacks integration_test/verify_screens_test.dart; merge main first"; exit 2; }

echo "== checkout: $SRC ($(git rev-parse --short HEAD 2>/dev/null || echo nogit)); pubspec $(grep '^version:' pubspec.yaml)"
[ -d lib/ui/region ] && echo "== region screens present: $(ls lib/ui/region | tr '\n' ' ')" || echo "== no lib/ui/region on this checkout"
flutter pub get >/dev/null

pick_udid() { # name prefix -> udid of newest available match
  xcrun simctl list devices available | grep -F "$1" | grep -v "Pro Max\|13-inch" | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

FAIL=0
IFS='|' read -ra LIST <<< "$DEVICES"
for NAME in "${LIST[@]}"; do
  UDID="$(pick_udid "$NAME")"
  [ -n "$UDID" ] || { echo "!! no simulator matching '$NAME'"; FAIL=1; continue; }
  SLUG="$(echo "$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9-')"
  D="$OUT/$SLUG"; mkdir -p "$D"
  echo; echo "===== $NAME ($UDID) -> $D"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true

  echo "-- build ($MODE, simulator)"
  flutter build ios --simulator "--$MODE" 2>&1 | tail -3 | tee "$D/build.log"
  APP="$SRC/build/ios/iphonesimulator/Runner.app"
  [ -d "$APP" ] || { echo "!! build produced no Runner.app"; FAIL=1; continue; }
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  sleep 6
  xcrun simctl io "$UDID" screenshot "$D/00-launch.png" >/dev/null 2>&1
  echo "$D/00-launch.png"
  # fresh state for the flow test (first-run onboarding path); wipes only the simulator's app data
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true

  echo "-- flow test (flutter test integration_test/verify_screens_test.dart -d $UDID)"
  LOG="$D/test.log"; : > "$LOG"
  N=0
  set +e
  flutter test integration_test/verify_screens_test.dart -d "$UDID" 2>&1 | while IFS= read -r line; do
    echo "$line" >> "$LOG"
    case "$line" in
      *"SCREEN "*)
        name="${line##*SCREEN }"; name="${name%%[[:space:]]*}"; N=$((N+1))
        f="$D/$(printf '%02d' $N)-$name.png"
        xcrun simctl io "$UDID" screenshot "$f" >/dev/null 2>&1 && echo "$f" ;;
      *APP_VERSION*|*SKIPPED*|*FAILED*|*VERIFY_DONE*|*"All tests passed"*|*"Some tests failed"*) echo "$line" ;;
    esac
  done
  RC=${PIPESTATUS[0]}
  set -e
  grep -o 'APP_VERSION [^ ]*' "$LOG" | tail -1 > "$D/version.txt" || true
  if [ "$RC" -ne 0 ] || ! grep -q VERIFY_DONE "$LOG"; then echo "!! $NAME: flow test FAILED (see $LOG)"; FAIL=1; else echo "== $NAME OK: $(cat "$D/version.txt")"; fi
done

echo; echo "Screenshots in: $OUT"; find "$OUT" -name '*.png' | sort
exit $FAIL
