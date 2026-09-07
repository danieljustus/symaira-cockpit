#!/usr/bin/env bash
set -euo pipefail

# Assemble Symaira Cockpit.app from the SwiftPM product.
#
# The GUI has no Xcode project on purpose: its dependency graph (tune, operate,
# scope plus symaira-appkit) is already declared once in Package.swift, and a
# parallel XcodeGen definition would be a second place to keep in sync. SwiftPM
# builds the executable; this script wraps it in a bundle, which is all the
# extra structure an LSUIElement app needs.
#
# Env:
#   CONFIGURATION  debug | release (default: release)
#   UNIVERSAL      1 to build arm64 + x86_64 (default: 1)
#   OUTPUT_DIR     where the .app lands (default: build/app)

CONFIGURATION="${CONFIGURATION:-release}"
UNIVERSAL="${UNIVERSAL:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-build/app}"
REQUIRE_COMPILED_ICON="${REQUIRE_COMPILED_ICON:-false}"
APP_NAME="Symaira Cockpit"
BUNDLE_ID="com.symaira.cockpit"
PRODUCT="SymCockpitApp"

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
fi
ICON_SOURCE="$REPO_ROOT/assets/branding/AppIcon.icon"
ICNS_SOURCE="$REPO_ROOT/assets/branding/AppIcon.icns"

COCKPIT_VERSION="$(sed -n 's/^[[:space:]]*public static let current = "\([^"]*\)".*/\1/p' Sources/SymCockpitVersion/CockpitVersion.swift)"
[[ -n "$COCKPIT_VERSION" ]] || {
  printf 'Could not read cockpit version from Sources/SymCockpitVersion/CockpitVersion.swift\n' >&2
  exit 1
}

BUILD_ARGS=(--product "$PRODUCT" -c "$CONFIGURATION" --jobs "${SWIFT_BUILD_JOBS:-2}")
if [[ "$UNIVERSAL" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$PRODUCT"

[[ -x "$BIN_PATH" ]] || {
  printf 'Expected product was not produced: %s\n' "$BIN_PATH" >&2
  exit 1
}

APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$PRODUCT"
cp -R "$ICON_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icon"
cp "$ICNS_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icns"

# The Info.plist template carries Xcode's build-setting placeholders so it can
# also be consumed by an Xcode target later; substitute them here.
DEPLOYMENT_TARGET="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift | head -1)"
sed \
  -e "s|\$(EXECUTABLE_NAME)|$PRODUCT|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
  -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|${DEPLOYMENT_TARGET:-15.0}|g" \
  -e "s|\$(COCKPIT_VERSION)|$COCKPIT_VERSION|g" \
  Sources/SymCockpitApp/Info.plist > "$APP_PATH/Contents/Info.plist"

if ACTOOL="$(xcrun --find actool 2>/dev/null || true)" && [[ -n "$ACTOOL" ]]; then
  ICON_BUILD_DIR="$APP_PATH/Contents/Resources/.AppIcon-compiled"
  mkdir -p "$ICON_BUILD_DIR"
  "$ACTOOL" \
    --compile "$ICON_BUILD_DIR" \
    --platform macosx \
    --minimum-deployment-target "${DEPLOYMENT_TARGET:-15.0}" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
    "$ICON_SOURCE"
  cp "$ICON_BUILD_DIR/Assets.car" "$APP_PATH/Contents/Resources/Assets.car"
  rm -rf "$ICON_BUILD_DIR"
elif [[ "$REQUIRE_COMPILED_ICON" == "true" ]]; then
  printf 'Release requires an Xcode 26+ actool that supports .icon; actool is unavailable.\n' >&2
  exit 1
else
  printf 'Warning: actool unavailable; keeping the approved ICNS fallback only.\n' >&2
fi

printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-app-icon.sh" "$APP_PATH"

# macOS keys both TCC grants (Accessibility, Screen Recording) and Keychain
# ACL decisions ("Always Allow") to the bundle's code signature. An ad-hoc
# signature carries no stable identity, so every rebuild looks like a brand-new
# app and every one of those decisions has to be made again. Sign with a real
# identity — a self-signed one is enough — and they survive rebuilds.
#
#   CODE_SIGN_IDENTITY="Symaira Dev" make build-app
#
# Create such an identity once in Keychain Access:
#   Certificate Assistant → Create a Certificate…
#   name: Symaira Dev · type: Code Signing · self-signed
IDENTITY="${CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP_PATH"

if [[ "$IDENTITY" == "-" ]]; then
  printf '%s\n' \
    'Note: ad-hoc signed. macOS will re-ask for permissions and Keychain access' \
    'after every rebuild. Set CODE_SIGN_IDENTITY to a code-signing certificate' \
    'to make those grants stick.' >&2
fi

printf 'Built %s\n' "$APP_PATH"
