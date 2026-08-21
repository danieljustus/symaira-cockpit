#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-build/app/SymairaTune.app}"

if [[ ! -d "$APP_PATH" ]]; then
  printf 'App bundle not found: %s\n' "$APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  printf 'Missing app Info.plist: %s\n' "$INFO_PLIST" >&2
  exit 1
fi

EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
LS_UI_ELEMENT=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO_PLIST")
EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

[[ -x "$EXECUTABLE" ]] || {
  printf 'App executable is missing or not executable: %s\n' "$EXECUTABLE" >&2
  exit 1
}
[[ "$BUNDLE_ID" == "com.symaira.tune" ]] || {
  printf 'Unexpected bundle identifier: %s\n' "$BUNDLE_ID" >&2
  exit 1
}
[[ "$LS_UI_ELEMENT" == "true" ]] || {
  printf 'Menu-bar app must set LSUIElement=true (got %s)\n' "$LS_UI_ELEMENT" >&2
  exit 1
}

# Xcode's unsigned build still contains an ad-hoc linker signature with no
# sealed resources. Treat that as unsigned; verify every real distribution
# signature strictly.
SIGNATURE_INFO=$(codesign --display --verbose=2 "$APP_PATH" 2>&1 || true)
if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_INFO"; then
  printf '%s\n' 'Bundle smoke check: ad-hoc unsigned build (expected for CI pull requests).'
else
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

printf 'Bundle smoke check passed: %s (%s)\n' "$BUNDLE_ID" "$EXECUTABLE_NAME"

if [[ "${LAUNCH_SMOKE:-0}" == "1" ]]; then
  open "$APP_PATH"
  for _ in {1..20}; do
    if pgrep -f "$EXECUTABLE" >/dev/null 2>&1; then
      printf 'Launch smoke check passed: %s\n' "$EXECUTABLE_NAME"
      pkill -f "$EXECUTABLE" >/dev/null 2>&1 || true
      exit 0
    fi
    sleep 1
done
  printf 'App did not stay alive during launch smoke check: %s\n' "$EXECUTABLE" >&2
  exit 1
fi
