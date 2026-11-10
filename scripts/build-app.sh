#!/usr/bin/env bash
set -euo pipefail

# Assemble Symaira Cockpit.app from the SwiftPM product.
#
# The GUI has no Xcode project on purpose: its dependency graph (tune plus symaira-corekit) is already declared once in Package.swift, and a
# parallel XcodeGen definition would be a second place to keep in sync. SwiftPM
# builds the executable; this script wraps it in a bundle, which is all the
# extra structure an LSUIElement app needs.
#
# Env:
#   CONFIGURATION  debug | release (default: release)
#   UNIVERSAL      1 to build arm64 + x86_64 (default: 1)
#   OUTPUT_DIR     where the .app lands (default: build/app)
#   SWIFT_SCRATCH_PATH optional isolated SwiftPM build directory
#   EXPECTED_TEAM_ID  Apple team identifier (10 upper-case alphanumerics) baked
#                  into the app and the fan helper as the only team they will
#                  pair with (issue #405). Release builds derive it from the
#                  Developer ID certificate. Without it the helper is inert.
#   REQUIRE_EMBEDDED_TEAM_ID  true to fail when EXPECTED_TEAM_ID is unset

CONFIGURATION="${CONFIGURATION:-release}"
UNIVERSAL="${UNIVERSAL:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-build/app}"
REQUIRE_COMPILED_ICON="${REQUIRE_COMPILED_ICON:-false}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
REQUIRE_EMBEDDED_TEAM_ID="${REQUIRE_EMBEDDED_TEAM_ID:-false}"
APP_NAME="Symaira Cockpit"
BUNDLE_ID="com.symaira.cockpit"
PRODUCT="SymCockpitApp"
# Optional privileged fan helper (issue #405): registered by the app through
# SMAppService.daemon. The identifier is the grandfathered helper identity.
HELPER_PRODUCT="SymCockpitFanHelper"
HELPER_ID="com.symaira.symtune-helper"

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

# Bake the expected team identifier into the build (fan helper trust root).
# The committed constant is nil; the literal is rewritten for this build only
# and the file is restored on exit, so the working tree stays clean.
EMBED_FILE="$REPO_ROOT/tuning/Sources/SymCockpitHelperKit/EmbeddedTeamIdentifier.swift"
if [[ -z "$EXPECTED_TEAM_ID" && "$REQUIRE_EMBEDDED_TEAM_ID" == "true" ]]; then
  printf 'EXPECTED_TEAM_ID is required (REQUIRE_EMBEDDED_TEAM_ID=true).\n' >&2
  exit 1
fi
if [[ -n "$EXPECTED_TEAM_ID" ]]; then
  [[ "$EXPECTED_TEAM_ID" =~ ^[0-9A-Z]{10}$ ]] || {
    printf 'EXPECTED_TEAM_ID must be ten upper-case alphanumerics.\n' >&2
    exit 1
  }
  EMBED_BACKUP="$(mktemp)"
  cp "$EMBED_FILE" "$EMBED_BACKUP"
  trap 'cp "$EMBED_BACKUP" "$EMBED_FILE"; rm -f "$EMBED_BACKUP"' EXIT
  EMBED_TMP="$(mktemp)"
  sed "s|^\(    public static let value: String? = \).*// EMBEDDED-TEAM-ID\$|\1\"$EXPECTED_TEAM_ID\" // EMBEDDED-TEAM-ID|" \
    "$EMBED_FILE" > "$EMBED_TMP"
  cat "$EMBED_TMP" > "$EMBED_FILE"
  rm -f "$EMBED_TMP"
  grep -Fq "value: String? = \"$EXPECTED_TEAM_ID\" // EMBEDDED-TEAM-ID" "$EMBED_FILE" || {
    printf 'Could not embed the team identifier into %s\n' "$EMBED_FILE" >&2
    exit 1
  }
fi

# Use the toolchain's default build system (Swift Build on Xcode 27). The
# resource gate below rejects an uncompiled .metal source-only bundle.
BUILD_ARGS=(--product "$PRODUCT" -c "$CONFIGURATION" --jobs "${SWIFT_BUILD_JOBS:-2}")
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$SWIFT_SCRATCH_PATH")
fi
if [[ "$UNIVERSAL" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$PRODUCT"

[[ -x "$BIN_PATH" ]] || {
  printf 'Expected product was not produced: %s\n' "$BIN_PATH" >&2
  exit 1
}

# Same flags, other product (BUILD_ARGS[1] is the product name).
HELPER_BUILD_ARGS=("${BUILD_ARGS[@]}")
HELPER_BUILD_ARGS[1]="$HELPER_PRODUCT"
swift build "${HELPER_BUILD_ARGS[@]}"
HELPER_BIN_PATH="$(swift build "${HELPER_BUILD_ARGS[@]}" --show-bin-path)/$HELPER_PRODUCT"
[[ -x "$HELPER_BIN_PATH" ]] || {
  printf 'Expected helper was not produced: %s\n' "$HELPER_BIN_PATH" >&2
  exit 1
}

APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$PRODUCT"

# The helper and its launchd plist, in the places SMAppService.daemon expects:
# the plist under Contents/Library/LaunchDaemons, the executable (named like
# the Mach service) under Contents/Library/LaunchServices.
mkdir -p "$APP_PATH/Contents/Library/LaunchServices" "$APP_PATH/Contents/Library/LaunchDaemons"
cp "$HELPER_BIN_PATH" "$APP_PATH/Contents/Library/LaunchServices/$HELPER_ID"
cp "$REPO_ROOT/Sources/$HELPER_PRODUCT/$HELPER_ID.plist" "$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
plutil -lint "$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_ID.plist" >/dev/null
# Bundle.module searches Contents/Resources in an assembled app. Copy every
# package resource bundle, not just the executable: fonts, shaders and provider
# descriptors must work after moving the app away from its build directory.
shopt -s nullglob
RESOURCE_BUNDLES=("$(dirname "$BIN_PATH")"/*.bundle)
for resource_bundle in "${RESOURCE_BUNDLES[@]}"; do
  cp -R "$resource_bundle" "$APP_PATH/Contents/Resources/"
done
THEME_RESOURCES="$APP_PATH/Contents/Resources/symaira-corekit_SymairaTheme.bundle/Contents/Resources"
for resource in GoogleSansFlex.ttf GoogleSansFlex-OFL.txt GoogleSansFlex-TRADEMARKS.md default.metallib; do
  [[ -s "$THEME_RESOURCES/$resource" ]] || {
    printf 'Missing required AppKit resource: %s\n' "$resource" >&2
    exit 1
  }
done
cp -R "$ICON_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icon"
cp "$ICNS_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icns"

# The Info.plist template carries Xcode's build-setting placeholders so it can
# also be consumed by an Xcode target later; substitute them here.
DEPLOYMENT_TARGET="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift | head -1)"
sed \
  -e "s|\$(EXECUTABLE_NAME)|$PRODUCT|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
  -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|${DEPLOYMENT_TARGET:-26.0}|g" \
  -e "s|\$(COCKPIT_VERSION)|$COCKPIT_VERSION|g" \
  Sources/SymCockpitApp/Info.plist > "$APP_PATH/Contents/Info.plist"

if ACTOOL="$(xcrun --find actool 2>/dev/null || true)" && [[ -n "$ACTOOL" ]]; then
  ICON_BUILD_DIR="$APP_PATH/Contents/Resources/.AppIcon-compiled"
  mkdir -p "$ICON_BUILD_DIR"
  "$ACTOOL" \
    --compile "$ICON_BUILD_DIR" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --include-all-app-icons \
    --enable-on-demand-resources NO \
    --development-region en \
    --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
    "$ICON_SOURCE" < /dev/null
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

# Nested code first: the helper is signed under its own identifier (the one
# the app's XPC requirement pins) before the bundle seals it. The app only
# ever registers the helper when it is itself Developer-ID signed, so an
# ad-hoc or self-signed helper here is inert.
HELPER_SIGN_ARGS=(--force --sign "$IDENTITY" --identifier "$HELPER_ID" --timestamp=none)
if [[ "$IDENTITY" != "-" ]]; then
  HELPER_SIGN_ARGS+=(--options runtime)
fi
codesign "${HELPER_SIGN_ARGS[@]}" "$APP_PATH/Contents/Library/LaunchServices/$HELPER_ID"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP_PATH"

if [[ "$IDENTITY" == "-" ]]; then
  printf '%s\n' \
    'Note: ad-hoc signed. macOS will re-ask for permissions and Keychain access' \
    'after every rebuild. Set CODE_SIGN_IDENTITY to a code-signing certificate' \
    'to make those grants stick.' >&2
fi

printf 'Built %s\n' "$APP_PATH"
