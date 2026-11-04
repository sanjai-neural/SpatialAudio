#!/bin/zsh
# Minimal dev bundler: wraps the SwiftPM executable in SpatialAudio.app with an Info.plist so
# macOS shows the camera permission prompt (a bare executable has no NSCameraUsageDescription).
#
# NOT the release pipeline. Hardened runtime, Developer ID signing, notarization and the camera
# entitlement for hardened builds are Step 9.
#
# Usage: scripts/make-app.sh [debug|release]      (default: debug)
#        CODESIGN_IDENTITY="Apple Development: ..." scripts/make-app.sh   (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP_NAME="SpatialAudio"
BUNDLE_ID="dev.spatialaudio.SpatialAudio"   # placeholder identifier; decide the real one before Step 9
OUT="build/${APP_NAME}.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SpatialAudioApp"
[[ -x "$BIN" ]] || { echo "error: executable not found at $BIN" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key>
    <string>SpatialAudio uses the camera to estimate your head orientation for spatial audio. Video frames are processed in memory only; they are never saved or sent anywhere.</string>
</dict>
</plist>
PLIST

plutil -lint "$OUT/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$OUT"
codesign --verify --verbose=2 "$OUT"
echo "Built $OUT (config=$CONFIG, signing identity=$IDENTITY)"
