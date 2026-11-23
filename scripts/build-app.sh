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
#   (arm64 only: Intel is not a supported platform, architecture D16. The Swift
#   product is built for the host, which must be Apple Silicon, and every
#   Mach-O in the bundle is checked to be arm64.)
#   OUTPUT_DIR     where the .app lands (default: build/app)
#   SWIFT_SCRATCH_PATH optional isolated SwiftPM build directory
#   EXPECTED_TEAM_ID  Apple team identifier (10 upper-case alphanumerics) baked
#                  into the app and the fan helper as the only team they will
#                  pair with (issue #405). Release builds derive it from the
#                  Developer ID certificate. Without it the helper is inert.
#   REQUIRE_EMBEDDED_TEAM_ID  true to fail when EXPECTED_TEAM_ID is unset
#   CODE_SIGN_IDENTITY  signing identity, "-" (ad hoc) by default
#   CODE_SIGN_TIMESTAMP "--timestamp" for a release build (Apple's secure timestamp,
#                  which notarization requires); "--timestamp=none" by default
#   STRIP_APP      1 to strip the Swift executable before signing (release)
#   CARGO          cargo command (default: dev-external cargo when installed, else cargo)
#   RUST_TARGET    cargo --target for the Rust binaries (default: the host; the
#                  bundle's agent and helper must come out arm64 either way)
#
# Besides the Swift app, the bundle carries two Rust binaries:
#   Contents/MacOS/symcockpit   the app agent (`symcockpit agent --stdio`) and the
#                               CLI the cask links later; built with
#                               SYMCOCKPIT_TEAM_ID = EXPECTED_TEAM_ID, the team the
#                               agent accepts as the signer of its parent
#   Contents/Library/LaunchServices/com.symaira.symtune-helper
#                               the privileged helper (`symcockpit-helper`),
#                               built with SYMCOCKPIT_EMBEDDED_TEAM_ID = EXPECTED_TEAM_ID

CONFIGURATION="${CONFIGURATION:-release}"
TIMESTAMP="${CODE_SIGN_TIMESTAMP:---timestamp=none}"
STRIP_APP="${STRIP_APP:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-build/app}"
REQUIRE_COMPILED_ICON="${REQUIRE_COMPILED_ICON:-false}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
REQUIRE_EMBEDDED_TEAM_ID="${REQUIRE_EMBEDDED_TEAM_ID:-false}"
APP_NAME="Symaira Cockpit"
BUNDLE_ID="com.symaira.cockpit"
PRODUCT="SymCockpitApp"
# Optional privileged fan helper (issue #405): registered by the app through
# SMAppService.daemon. The identifier is the grandfathered helper identity; the
# launchd plist still lives next to the retired Swift helper until it is removed.
HELPER_ID="com.symaira.symtune-helper"
HELPER_PLIST_SOURCE="Sources/SymCockpitFanHelper/$HELPER_ID.plist"
AGENT_ID="com.symaira.cockpit.symcockpit"

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
  # Restore the tracked file on every exit. A failed restore must fail the
  # build (not leave a rewritten source file behind unnoticed).
  restore_embed_file() {
    local status=$?
    trap - EXIT
    if cp "$EMBED_BACKUP" "$EMBED_FILE" && cmp -s "$EMBED_BACKUP" "$EMBED_FILE"; then
      rm -f "$EMBED_BACKUP"
    else
      printf 'Could not restore %s from %s; revert it with git checkout.\n' \
        "$EMBED_FILE" "$EMBED_BACKUP" >&2
      [[ $status -ne 0 ]] || status=1
    fi
    exit "$status"
  }
  trap restore_embed_file EXIT
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
[[ "$(uname -m)" == "arm64" ]] || {
  printf 'Symaira Cockpit is arm64 only; build on Apple Silicon (host is %s).\n' "$(uname -m)" >&2
  exit 1
}

swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$PRODUCT"

[[ -x "$BIN_PATH" ]] || {
  printf 'Expected product was not produced: %s\n' "$BIN_PATH" >&2
  exit 1
}
[[ "$(lipo -archs "$BIN_PATH")" == "arm64" ]] || {
  printf 'The app executable must be arm64: %s (%s)\n' "$BIN_PATH" "$(lipo -archs "$BIN_PATH")" >&2
  exit 1
}

# The Rust binaries. A team id is baked in only when one is given; without it
# the agent refuses to serve (exit 3) and the helper stays inert, as before.
if [[ -z "${CARGO:-}" ]]; then
  if [[ -x "$HOME/.local/bin/dev-external" ]]; then CARGO="$HOME/.local/bin/dev-external cargo"; else CARGO=cargo; fi
fi
RUST_ARGS=(build --release --locked -p symcockpit -p symcockpit-helper)
RUST_RELEASE_DIR=release
if [[ -n "${RUST_TARGET:-}" ]]; then
  RUST_ARGS+=(--target "$RUST_TARGET")
  RUST_RELEASE_DIR="$RUST_TARGET/release"
fi
RUST_ENV=()
if [[ -n "$EXPECTED_TEAM_ID" ]]; then
  RUST_ENV=(SYMCOCKPIT_TEAM_ID="$EXPECTED_TEAM_ID" SYMCOCKPIT_EMBEDDED_TEAM_ID="$EXPECTED_TEAM_ID")
fi
# shellcheck disable=SC2086 # $CARGO is a command line ("dev-external cargo")
env ${RUST_ENV[@]+"${RUST_ENV[@]}"} $CARGO "${RUST_ARGS[@]}"
# shellcheck disable=SC2086
RUST_TARGET_DIR="$($CARGO metadata --format-version 1 --no-deps | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
AGENT_BIN_PATH="$RUST_TARGET_DIR/$RUST_RELEASE_DIR/symcockpit"
HELPER_BIN_PATH="$RUST_TARGET_DIR/$RUST_RELEASE_DIR/symcockpit-helper"
for rust_binary in "$AGENT_BIN_PATH" "$HELPER_BIN_PATH"; do
  [[ -x "$rust_binary" ]] || {
    printf 'Expected Rust binary was not produced: %s\n' "$rust_binary" >&2
    exit 1
  }
  [[ "$(lipo -archs "$rust_binary")" == "arm64" ]] || {
    printf 'Rust binary must be arm64: %s (%s)\n' "$rust_binary" "$(lipo -archs "$rust_binary")" >&2
    exit 1
  }
done

APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$PRODUCT"
# The symbol table is more than half the bytes; the signature below makes them final.
if [[ "$STRIP_APP" == "1" ]]; then
  strip "$APP_PATH/Contents/MacOS/$PRODUCT"
fi
# The agent the app starts as its child (path from the app's own executable
# directory), and the CLI binary the cask links.
cp "$AGENT_BIN_PATH" "$APP_PATH/Contents/MacOS/symcockpit"

# The helper and its launchd plist, in the places SMAppService.daemon expects:
# the plist under Contents/Library/LaunchDaemons, the executable (named like
# the Mach service) under Contents/Library/LaunchServices.
mkdir -p "$APP_PATH/Contents/Library/LaunchServices" "$APP_PATH/Contents/Library/LaunchDaemons"
cp "$HELPER_BIN_PATH" "$APP_PATH/Contents/Library/LaunchServices/$HELPER_ID"
cp "$REPO_ROOT/$HELPER_PLIST_SOURCE" "$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
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

# The app group of the Finder jobs: named in Info.plist exactly when the app gets the
# entitlement below (a team id, and extensions to talk to), as the FinderSync extension reads it.
APP_GROUP=""
if [[ -n "$EXPECTED_TEAM_ID" && "${SKIP_EXTENSIONS:-0}" != "1" ]]; then
  APP_GROUP="$EXPECTED_TEAM_ID.group.com.symaira.cockpit"
fi
# The Info.plist template carries Xcode's build-setting placeholders so it can
# also be consumed by an Xcode target later; substitute them here.
DEPLOYMENT_TARGET="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift | head -1)"
sed \
  -e "s|\$(EXECUTABLE_NAME)|$PRODUCT|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
  -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|${DEPLOYMENT_TARGET:-26.0}|g" \
  -e "s|\$(COCKPIT_VERSION)|$COCKPIT_VERSION|g" \
  -e "s|__GROUP__|$APP_GROUP|g" \
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

# Quick Look and Finder extensions (R70-R72): built without an Xcode project and signed
# here with the same identity. They must exist before the app seal below. SKIP_EXTENSIONS=1
# leaves them out (e.g. for a GUI-only iteration).
if [[ "${SKIP_EXTENSIONS:-0}" != "1" ]]; then
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_TIMESTAMP="$TIMESTAMP" EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" COCKPIT_VERSION="$COCKPIT_VERSION" \
    "$REPO_ROOT/scripts/build-extensions.sh" "$APP_PATH"
fi

# Nested code first, all with the app's identity: the helper is signed under
# its own identifier (the one the app's XPC requirement pins), the agent under
# its own, before the bundle seals them. The app only ever registers the helper
# when it is itself Developer-ID signed, so an ad-hoc or self-signed helper
# here is inert; likewise the agent serves only a Developer-ID signed parent.
# Hardened Runtime on both for a real identity, as the notarization needs.
NESTED_SIGN_ARGS=(--force --sign "$IDENTITY" "$TIMESTAMP")
if [[ "$IDENTITY" != "-" ]]; then
  NESTED_SIGN_ARGS+=(--options runtime)
fi
codesign "${NESTED_SIGN_ARGS[@]}" --identifier "$HELPER_ID" "$APP_PATH/Contents/Library/LaunchServices/$HELPER_ID"
codesign "${NESTED_SIGN_ARGS[@]}" --identifier "$AGENT_ID" "$APP_PATH/Contents/MacOS/symcockpit"
# The app joins the extensions' app group (Finder jobs) only when a team id is known.
APP_SIGN_ARGS=()
if [[ -n "$EXPECTED_TEAM_ID" && "${SKIP_EXTENSIONS:-0}" != "1" ]]; then
  APP_ENTITLEMENTS="$(mktemp)"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' >"$APP_ENTITLEMENTS"
  # Dots in the key are escaped: plutil reads an unescaped one as a key path.
  plutil -insert 'com\.apple\.security\.application-groups' -json "[\"$APP_GROUP\"]" "$APP_ENTITLEMENTS"
  APP_SIGN_ARGS=(--entitlements "$APP_ENTITLEMENTS")
fi
# The bundle itself is sealed last, over everything nested above, with Hardened Runtime for a
# real identity (a notarization requirement) and its own entitlements: the app group only.
BUNDLE_SIGN_ARGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$TIMESTAMP")
[[ "$IDENTITY" == "-" ]] || BUNDLE_SIGN_ARGS+=(--options runtime)
codesign "${BUNDLE_SIGN_ARGS[@]}" ${APP_SIGN_ARGS[@]+"${APP_SIGN_ARGS[@]}"} "$APP_PATH"
[[ -z "${APP_ENTITLEMENTS:-}" ]] || rm -f "$APP_ENTITLEMENTS"

if [[ "$IDENTITY" == "-" ]]; then
  printf '%s\n' \
    'Note: ad-hoc signed. macOS will re-ask for permissions and Keychain access' \
    'after every rebuild. Set CODE_SIGN_IDENTITY to a code-signing certificate' \
    'to make those grants stick.' >&2
fi

printf 'Built %s\n' "$APP_PATH"
