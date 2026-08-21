#!/usr/bin/env bash
set -euo pipefail

# Build the standalone menu-bar application from the checked-in XcodeGen
# definition. The default is an unsigned reproducible CI build; release.yml
# signs the resulting bundle after importing the Developer ID certificate.
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT="${PROJECT:-SymairaTune.xcodeproj}"
SCHEME="${SCHEME:-SymairaTune}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build/xcode}"
OUTPUT_DIR="${OUTPUT_DIR:-build/app}"

command -v xcodegen >/dev/null 2>&1 || {
  printf '%s\n' 'xcodegen is required (brew install xcodegen)' >&2
  exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
  printf '%s\n' 'xcodebuild is required; select a full Xcode installation' >&2
  exit 1
}

xcodegen generate
rm -rf "$OUTPUT_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/SymairaTune.app"
if [[ ! -d "$APP_PATH" ]]; then
  printf 'Expected app bundle was not produced: %s\n' "$APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_DIR")"
ditto "$APP_PATH" "$OUTPUT_DIR/SymairaTune.app"
printf 'Built %s\n' "$OUTPUT_DIR/SymairaTune.app"
