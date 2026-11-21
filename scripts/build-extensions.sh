#!/usr/bin/env bash
set -euo pipefail

# Build the Quick Look and FinderSync extensions and embed them in an assembled app:
#
#   scripts/build-extensions.sh "build/app/Symaira Cockpit.app"
#
# Like build-app.sh there is no Xcode project: swiftc builds each .appex with
# `-application-extension` and the entry point _NSExtensionMain, and links the Rust staticlib
# (crates/symcockpit-ffi) that does the listing. scripts/build-app.sh calls this before it
# signs the app. It registers and starts nothing (no pluginkit, no app launch).
#
# Env:
#   CODE_SIGN_IDENTITY  signing identity, "-" (ad hoc) by default, same as build-app.sh
#   CODE_SIGN_TIMESTAMP "--timestamp" for a release build, "--timestamp=none" by default
#   EXPECTED_TEAM_ID    ten-character team id: adds the app group "<TEAM>.group.com.symaira.cockpit"
#                       (jobs/ for Finder actions). Without it the FinderSync extension has no
#                       container to write to and logs an error instead of sending a job.
#   COCKPIT_VERSION     bundle version (default: read from CockpitVersion.swift)
#   MIN_MACOS           deployment target (default: read from Package.swift, else 26.0)
#   CARGO               cargo command (default: dev-external cargo when installed, else cargo)
#
# The extensions are arm64 only: Intel is not a supported platform (D16), so the Rust library
# is built for the host architecture and no x86_64 slice is produced.

APP_PATH="${1:?usage: build-extensions.sh <path to Symaira Cockpit.app>}"
[[ -d "$APP_PATH/Contents" ]] || { printf 'Not an app bundle: %s\n' "$APP_PATH" >&2; exit 1; }

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
TIMESTAMP="${CODE_SIGN_TIMESTAMP:---timestamp=none}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
COCKPIT_VERSION="${COCKPIT_VERSION:-$(sed -n 's/^[[:space:]]*public static let current = "\([^"]*\)".*/\1/p' Sources/SymCockpitVersion/CockpitVersion.swift)}"
[[ -n "$COCKPIT_VERSION" ]] || { printf 'Could not read the cockpit version\n' >&2; exit 1; }
MIN_MACOS="${MIN_MACOS:-$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift | head -1)}"
MIN_MACOS="${MIN_MACOS:-26.0}"
[[ -z "$EXPECTED_TEAM_ID" || "$EXPECTED_TEAM_ID" =~ ^[0-9A-Z]{10}$ ]] || {
  printf 'EXPECTED_TEAM_ID must be ten upper-case alphanumerics.\n' >&2
  exit 1
}
APP_GROUP=""
[[ -z "$EXPECTED_TEAM_ID" ]] || APP_GROUP="$EXPECTED_TEAM_ID.group.com.symaira.cockpit"

if [[ -z "${CARGO:-}" ]]; then
  if [[ -x "$HOME/.local/bin/dev-external" ]]; then CARGO="$HOME/.local/bin/dev-external cargo"; else CARGO=cargo; fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The Rust library. Cargo reports the staticlib path in its JSON messages.
# shellcheck disable=SC2086
$CARGO build --release --locked -p symcockpit-ffi --message-format=json >"$WORK/cargo.json"
LIB="$(python3 -I - "$WORK/cargo.json" <<'PY'
import json, sys
lib = None
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m["target"]["name"] == "symcockpit_ffi":
        for f in m.get("filenames", []):
            if f.endswith(".a"):
                lib = f
print(lib or "")
PY
)"
[[ -f "$LIB" ]] || { printf 'symcockpit-ffi staticlib not found in cargo output\n' >&2; exit 1; }

# 2. One .appex per extension.
SWIFT_COMMON=(-target "arm64-apple-macos$MIN_MACOS" -O -swift-version 6 -parse-as-library
  -import-objc-header "$REPO_ROOT/crates/symcockpit-ffi/include/symcockpit_ffi.h")
EXT_LINK=(-application-extension -Xlinker -e -Xlinker _NSExtensionMain)
PLUGINS="$APP_PATH/Contents/PlugIns"
rm -rf "$PLUGINS"
mkdir -p "$PLUGINS"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

# build_extension <dir> <executable> <framework...>
build_extension() {
  local dir="$1" exe="$2"; shift 2
  local appex="$PLUGINS/$exe.appex"
  mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
  local frameworks=()
  for f in "$@"; do frameworks+=(-framework "$f"); done
  swiftc "${SWIFT_COMMON[@]}" "${EXT_LINK[@]}" -module-name "$exe" \
    "$REPO_ROOT/extensions/$dir"/*.swift "$LIB" "${frameworks[@]}" -o "$appex/Contents/MacOS/$exe"
  sed -e "s|__VERSION__|$COCKPIT_VERSION|g" -e "s|__MINOS__|$MIN_MACOS|g" -e "s|__GROUP__|$APP_GROUP|g" \
    "$REPO_ROOT/extensions/$dir/Info.plist" >"$appex/Contents/Info.plist"
  plutil -lint "$appex/Contents/Info.plist" >/dev/null
  for lproj in "$REPO_ROOT/extensions/$dir"/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$appex/Contents/Resources/"
  done
  # Entitlements: the sandbox only; the app group is added when a team id is known.
  local ent="$WORK/$exe.entitlements"
  cp "$REPO_ROOT/extensions/entitlements/$dir.entitlements" "$ent"
  if [[ -n "$APP_GROUP" && "$dir" == findersync ]]; then
    plutil -insert com.apple.security.application-groups -json "[\"$APP_GROUP\"]" "$ent"
  fi
  local sign=(codesign --force --sign "$IDENTITY" "$TIMESTAMP" --entitlements "$ent")
  [[ "$IDENTITY" == "-" ]] || sign+=(--options runtime)
  "${sign[@]}" "$appex"
  codesign --verify --strict "$appex"
}

build_extension quicklook SymCockpitQuickLook QuickLookUI UniformTypeIdentifiers
build_extension findersync SymCockpitFinderSync FinderSync AppKit

printf 'Embedded extensions in %s\n' "$PLUGINS"
