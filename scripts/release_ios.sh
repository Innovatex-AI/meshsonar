#!/usr/bin/env bash
# Build a signed App Store IPA and (optionally) upload it to App Store Connect / TestFlight.
#   scripts/release_ios.sh [--upload]            (TEAM_ID is read from ios/Flutter/Signing.xcconfig when not set)
#   TEAM_ID=ABCDE12345 scripts/release_ios.sh [--upload]
# Signing/upload auth (Nov 8 2026): an App Store Connect API key, so uploads no longer depend on Xcode keeping the Apple ID signed in
# (it dropped it twice). The key (Admin role, needed for cloud-managed distribution signing) lives OUTSIDE the repo:
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8   (mode 600; Apple lets you download it once)
#   ~/.appstoreconnect/meshsonar.env                           ASC_KEY_ID=... and ASC_ISSUER_ID=... (ids, not secrets)
# Without them the export falls back to the Apple ID signed in to Xcode (Settings > Accounts).
# Also needs the app record for com.meshsonar.app in App Store Connect.
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
# shellcheck disable=SC1090
[ -f "$HOME/.appstoreconnect/meshsonar.env" ] && . "$HOME/.appstoreconnect/meshsonar.env"
AUTH=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [ -f "$KEY" ] || { echo "ASC_KEY_ID is set but $KEY is missing" >&2; exit 1; }
  AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "== export/upload with App Store Connect API key $ASC_KEY_ID"
else
  echo "== no API key (~/.appstoreconnect/meshsonar.env): export/upload with the Apple ID signed in to Xcode"
fi

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
  -exportPath "$OUT/out" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} 2>&1 | tee -a "$OUT/build.log"
if grep -q 'Redundant Binary Upload' "$OUT/build.log"; then echo "== build number already uploaded (ITMS-90189): bump +N in pubspec.yaml" >&2; exit 1; fi
if ! grep -q 'EXPORT SUCCEEDED' "$OUT/build.log"; then echo "== export/upload FAILED; the archive is kept at $ARCHIVE (re-run only the xcodebuild -exportArchive line)" >&2; exit 1; fi
echo "== $(grep '^version:' pubspec.yaml); $([ $UPLOAD = 1 ] && echo 'uploaded to App Store Connect' || ls "$OUT"/out/*.ipa 2>/dev/null || echo 'export done')"
# disk rule (HANDOFF): once uploaded, the archive and IPA are not needed on this Mac
if [ $UPLOAD = 1 ]; then rm -rf build/ios; echo "== removed build/ios (uploaded)"; fi
