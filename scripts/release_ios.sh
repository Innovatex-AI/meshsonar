#!/usr/bin/env bash
# Build a signed App Store IPA and (optionally) upload it to App Store Connect / TestFlight.
#   scripts/release_ios.sh [--upload]            (TEAM_ID is read from ios/Flutter/Signing.xcconfig when not set)
#   TEAM_ID=ABCDE12345 scripts/release_ios.sh [--upload]
# Needs: the paid team signed in to Xcode (Settings > Accounts) so automatic signing can create the distribution
# cert + App Store profile, and the app record for com.meshsonar.app created in App Store Connect.
# Build number comes from pubspec.yaml (+N), which App Store Connect requires to increase on every upload.
# Archives with flutter, then exports/uploads with xcodebuild (flutter's own ipa step fails listing build/ios/ipa after an
# upload-mode export, and a second upload of the same build number is rejected as ITMS-90189: upload exactly once).
# Never runs `flutter install`; this does not touch any connected device.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${TEAM_ID:-}" ] && [ -f ios/Flutter/Signing.xcconfig ]; then
  TEAM_ID=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' ios/Flutter/Signing.xcconfig | head -1)
fi
: "${TEAM_ID:?set TEAM_ID to the paid Apple team id (developer.apple.com > Membership) or create ios/Flutter/Signing.xcconfig}"
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

flutter build xcarchive --release 2>&1 | tee "$OUT/build.log"
ARCHIVE="build/ios/archive/Runner.xcarchive"
[ -d "$ARCHIVE" ] || { echo "archive missing: $ARCHIVE" >&2; exit 1; }
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/out" -allowProvisioningUpdates 2>&1 | tee -a "$OUT/build.log"
if grep -q 'Redundant Binary Upload' "$OUT/build.log"; then echo "== build number already uploaded (ITMS-90189): bump +N in pubspec.yaml" >&2; exit 1; fi
echo "== $(grep '^version:' pubspec.yaml); $([ $UPLOAD = 1 ] && echo 'uploaded to App Store Connect' || ls "$OUT"/out/*.ipa 2>/dev/null || echo 'export done')"
