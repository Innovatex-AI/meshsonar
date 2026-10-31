#!/usr/bin/env bash
# Proves a release iOS build has no Simulator: builds with no define and looks for the simulator's strings in the
# compiled app. Run from the repo root: scripts/verify_release_no_sim.sh
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build ios --release --no-codesign >/dev/null
BIN=build/ios/iphoneos/Runner.app/Frameworks/App.framework/App
[ -f "$BIN" ] || { echo "no App.framework binary at $BIN"; exit 2; }
for needle in "MeshSonar Simulator" "Simulator (no radio)" "Try the Simulator" "SIMULATED GPS"; do
  if strings "$BIN" | grep -q -F "$needle"; then echo "FAIL: release build contains: $needle"; exit 1; fi
done
echo "OK: release build has no Simulator strings"
