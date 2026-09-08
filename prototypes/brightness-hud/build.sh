#!/bin/bash
# Builds the probe and wraps it in a .app bundle. TCC hands Accessibility to a
# bundle identity, not to a loose executable, so the wrapper is mandatory.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/BrightnessHUDProbe.app"

swift build -c release --disable-sandbox
BINARY="$(swift build -c release --show-bin-path)/BrightnessHUDProbe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/BrightnessHUDProbe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BrightnessHUDProbe</string>
    <key>CFBundleIdentifier</key><string>de.symaira.cockpit.brightness-hud-probe</string>
    <key>CFBundleName</key><string>BrightnessHUDProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- Agent, not app: no Dock icon, no menu bar takeover. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# TCC pins an ad-hoc signature to its cdhash, so every rebuild reads as a
# different app and the Accessibility grant is lost. A Developer ID signature is
# identified by team + bundle id instead, and the grant survives rebuilds.
IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"

if [ -n "$IDENTITY" ]; then
    echo "signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "no Developer ID found — falling back to ad-hoc (re-approve after every build)"
    codesign --force --sign - --timestamp=none "$APP"
fi

echo "built: $APP"
