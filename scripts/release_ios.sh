#!/usr/bin/env bash
# Build a signed App Store IPA and (optionally) upload it to App Store Connect / TestFlight.
#   TEAM_ID=ABCDE12345 scripts/release_ios.sh [--upload]
# Needs: the paid team signed in to Xcode (Settings > Accounts) so automatic signing can create the distribution
# cert + App Store profile, and the app record for com.meshsonar.app created in App Store Connect.
# Build number comes from pubspec.yaml (+N), which App Store Connect requires to increase on every upload.
# Never runs `flutter install`; this does not touch any connected device.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?set TEAM_ID to the paid Apple team id (developer.apple.com > Membership)}"
UPLOAD=0; [ "${1:-}" = "--upload" ] && UPLOAD=1

OUT="build/ios/appstore"; rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>$([ $UPLOAD = 1 ] && echo upload || echo export)</string>
</dict></plist>
PLIST

# The team id lives only in the untracked Signing.xcconfig (docs/DEVELOPMENT.md 2.1), never in project.pbxproj.
printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM_ID" > ios/Flutter/Signing.xcconfig

flutter build ipa --release --export-options-plist="$OUT/ExportOptions.plist" 2>&1 | tee "$OUT/build.log"
echo "== $(grep '^version:' pubspec.yaml); IPA: $(ls build/ios/ipa/*.ipa 2>/dev/null || echo 'none (upload mode sends it straight to App Store Connect)')"
