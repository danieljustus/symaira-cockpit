#!/usr/bin/env bash
set -euo pipefail

# Structural check on the assembled GUI bundle: the pieces macOS needs before
# it will treat the directory as an app at all. Set LAUNCH_SMOKE=1 to also
# launch it and confirm it stays alive (needs a window server, so it is off in
# headless CI).

APP_PATH="${1:-build/app/Symaira Cockpit.app}"

[[ -d "$APP_PATH" ]] || {
  printf 'App bundle not found: %s\n' "$APP_PATH" >&2
  exit 1
}

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || {
  printf 'Missing app Info.plist: %s\n' "$INFO_PLIST" >&2
  exit 1
}

EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
LS_UI_ELEMENT=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO_PLIST")
EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
# The Finder jobs' app group (the app hands <container>/jobs to its agent): never the
# template placeholder, and the team's group when a team id is given and extensions are built.
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :SymCockpitAppGroup' "$INFO_PLIST" 2>/dev/null || true)
WANT_GROUP=""
if [[ -n "${EXPECTED_TEAM_ID:-}" && -d "$APP_PATH/Contents/PlugIns" ]]; then
  WANT_GROUP="$EXPECTED_TEAM_ID.group.com.symaira.cockpit"
fi
[[ "$APP_GROUP" == "$WANT_GROUP" ]] || {
  printf 'SymCockpitAppGroup is "%s", expected "%s"\n' "$APP_GROUP" "$WANT_GROUP" >&2
  exit 1
}

[[ -x "$EXECUTABLE" ]] || {
  printf 'App executable is missing or not executable: %s\n' "$EXECUTABLE" >&2
  exit 1
}
[[ "$BUNDLE_ID" == "com.symaira.cockpit" ]] || {
  printf 'Unexpected bundle identifier: %s\n' "$BUNDLE_ID" >&2
  exit 1
}
# The cockpit window raises the activation policy at runtime; the app must
# still start as a menu-bar accessory, or it gets a Dock icon with no window.
[[ "$LS_UI_ELEMENT" == "true" ]] || {
  printf 'Menu-bar app must set LSUIElement=true (got %s)\n' "$LS_UI_ELEMENT" >&2
  exit 1
}

"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-app-icon.sh" "$APP_PATH"

# Optional privileged fan helper (issue #405): executable and launchd plist
# must be embedded where SMAppService.daemon looks for them, and the plist
# must agree with the grandfathered helper identity.
HELPER_ID="com.symaira.symtune-helper"
HELPER_EXECUTABLE="$APP_PATH/Contents/Library/LaunchServices/$HELPER_ID"
HELPER_PLIST="$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
[[ -x "$HELPER_EXECUTABLE" ]] || {
  printf 'Fan helper executable is missing or not executable: %s\n' "$HELPER_EXECUTABLE" >&2
  exit 1
}
[[ -f "$HELPER_PLIST" ]] || {
  printf 'Fan helper launchd plist is missing: %s\n' "$HELPER_PLIST" >&2
  exit 1
}
plutil -lint "$HELPER_PLIST" >/dev/null || {
  printf 'Fan helper launchd plist is malformed: %s\n' "$HELPER_PLIST" >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$HELPER_PLIST")" == "$HELPER_ID" ]] || {
  printf 'Fan helper plist Label must be %s\n' "$HELPER_ID" >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$HELPER_PLIST")" == "Contents/Library/LaunchServices/$HELPER_ID" ]] || {
  printf 'Fan helper plist BundleProgram does not point at the embedded executable.\n' >&2
  exit 1
}
/usr/libexec/PlistBuddy -c "Print :MachServices:$HELPER_ID" "$HELPER_PLIST" >/dev/null 2>&1 || {
  printf 'Fan helper plist must declare the Mach service %s\n' "$HELPER_ID" >&2
  exit 1
}
HELPER_SIGNATURE=$(codesign --display --verbose=2 "$HELPER_EXECUTABLE" 2>&1 || true)
grep -q "^Identifier=$HELPER_ID$" <<<"$HELPER_SIGNATURE" || {
  printf 'Fan helper must be signed with identifier %s\n' "$HELPER_ID" >&2
  exit 1
}

# The Rust binaries (Cockpit 2): the agent the app starts (and the CLI the cask
# links) next to the app executable, and the helper above. Both must be arm64
# and validly signed. The agent is run once for `version`, which reads nothing
# from the Mac; the helper is never run (it would serve XPC).
AGENT_ID="com.symaira.cockpit.symcockpit"
AGENT_EXECUTABLE="$APP_PATH/Contents/MacOS/symcockpit"
[[ -x "$AGENT_EXECUTABLE" ]] || {
  printf 'Agent executable is missing or not executable: %s\n' "$AGENT_EXECUTABLE" >&2
  exit 1
}
for rust_binary in "$AGENT_EXECUTABLE" "$HELPER_EXECUTABLE"; do
  [[ "$(lipo -archs "$rust_binary")" == "arm64" ]] || {
    printf 'Rust binary must be arm64: %s (%s)\n' "$rust_binary" "$(lipo -archs "$rust_binary" 2>&1)" >&2
    exit 1
  }
  codesign --verify --strict "$rust_binary" || {
    printf 'Rust binary signature is invalid: %s\n' "$rust_binary" >&2
    exit 1
  }
done
grep -q "^Identifier=$AGENT_ID$" <<<"$(codesign --display --verbose=2 "$AGENT_EXECUTABLE" 2>&1 || true)" || {
  printf 'Agent must be signed with identifier %s\n' "$AGENT_ID" >&2
  exit 1
}
AGENT_VERSION=$("$AGENT_EXECUTABLE" version --no-update-check) || {
  printf '`symcockpit version` failed in the bundle: %s\n' "$AGENT_EXECUTABLE" >&2
  exit 1
}
grep -q '^symcockpit ' <<<"$AGENT_VERSION" || {
  printf 'Unexpected `symcockpit version` output: %s\n' "$AGENT_VERSION" >&2
  exit 1
}
# With a team id given (release builds), it must be baked into both binaries.
if [[ -n "${EXPECTED_TEAM_ID:-}" ]]; then
  for rust_binary in "$AGENT_EXECUTABLE" "$HELPER_EXECUTABLE"; do
    grep -aq "$EXPECTED_TEAM_ID" "$rust_binary" || {
      printf 'Team identifier %s is not baked into %s\n' "$EXPECTED_TEAM_ID" "$rust_binary" >&2
      exit 1
    }
  done
fi

THEME_RESOURCES="$APP_PATH/Contents/Resources/symaira-corekit_SymairaTheme.bundle/Contents/Resources"
for resource in GoogleSansFlex.ttf GoogleSansFlex-OFL.txt GoogleSansFlex-TRADEMARKS.md default.metallib; do
  [[ -s "$THEME_RESOURCES/$resource" ]] || {
    printf 'Missing required AppKit resource: %s\n' "$resource" >&2
    exit 1
  }
done
PROVIDER_RESOURCES="$APP_PATH/Contents/Resources/symaira-corekit_SymairaProviderKit.bundle/Contents/Resources"
for resource in llm_providers.json llm_errors.json; do
  [[ -s "$PROVIDER_RESOURCES/$resource" ]] || {
    printf 'Missing required provider resource: %s\n' "$resource" >&2
    exit 1
  }
done

# Quick Look and FinderSync extensions (R70-R72). Structure and signature only: nothing is
# registered or launched here. SKIP_EXTENSIONS=1 builds have none and skip this block.
if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
  for entry in "SymCockpitQuickLook:com.apple.quicklook.preview:com.symaira.cockpit.quicklook" \
    "SymCockpitFinderSync:com.apple.FinderSync:com.symaira.cockpit.findersync"; do
    IFS=: read -r EXT_NAME EXT_POINT EXT_ID <<<"$entry"
    APPEX="$APP_PATH/Contents/PlugIns/$EXT_NAME.appex"
    [[ -x "$APPEX/Contents/MacOS/$EXT_NAME" ]] || {
      printf 'Extension executable is missing: %s\n' "$APPEX" >&2
      exit 1
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX/Contents/Info.plist")" == "$EXT_ID" ]] || {
      printf 'Extension %s must have the bundle identifier %s\n' "$EXT_NAME" "$EXT_ID" >&2
      exit 1
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$APPEX/Contents/Info.plist")" == "$EXT_POINT" ]] || {
      printf 'Extension %s must extend %s\n' "$EXT_NAME" "$EXT_POINT" >&2
      exit 1
    }
    codesign --verify --strict "$APPEX" || {
      printf 'Extension signature is invalid: %s\n' "$APPEX" >&2
      exit 1
    }
    # App extensions must be sandboxed; macOS refuses to load them otherwise.
    codesign --display --entitlements - "$APPEX" 2>&1 | grep -q 'com.apple.security.app-sandbox' || {
      printf 'Extension %s lacks the app-sandbox entitlement\n' "$EXT_NAME" >&2
      exit 1
    }
  done
fi

# Release gate (REQUIRE_RELEASE_SIGNATURE=true, needs EXPECTED_TEAM_ID): every Mach-O in the bundle
# must come out of build-app.sh with the Developer ID of the expected team, Hardened Runtime and a
# secure timestamp, which is what notarization checks. Nothing may be re-signed afterwards: that
# would drop the per-part entitlements (the extensions' sandbox, the app group).
if [[ "${REQUIRE_RELEASE_SIGNATURE:-false}" == "true" ]]; then
  [[ -n "${EXPECTED_TEAM_ID:-}" ]] || {
    printf 'REQUIRE_RELEASE_SIGNATURE needs EXPECTED_TEAM_ID.\n' >&2
    exit 1
  }
  while IFS= read -r -d '' item; do
    file "$item" | grep -q 'Mach-O' || continue
    [[ "$(lipo -archs "$item")" == "arm64" ]] || {
      printf 'Mach-O must be arm64: %s (%s)\n' "$item" "$(lipo -archs "$item")" >&2
      exit 1
    }
    info=$(codesign --display --verbose=4 "$item" 2>&1 || true)
    grep -q '^Authority=Developer ID Application' <<<"$info" \
      && grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$info" \
      && grep -Eq 'flags=0x[0-9a-f]+\(.*runtime.*\)' <<<"$info" \
      && grep -q '^Timestamp=' <<<"$info" || {
      printf 'Not a release signature (Developer ID of %s, runtime, timestamp): %s\n' "$EXPECTED_TEAM_ID" "$item" >&2
      exit 1
    }
  done < <(find "$APP_PATH/Contents" -type f -print0)
  bundle_info=$(codesign --display --verbose=4 "$APP_PATH" 2>&1 || true)
  grep -q '^Authority=Developer ID Application' <<<"$bundle_info" \
    && grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$bundle_info" \
    && grep -Eq 'flags=0x[0-9a-f]+\(.*runtime.*\)' <<<"$bundle_info" \
    && grep -q '^Timestamp=' <<<"$bundle_info" || {
    printf 'The app bundle itself is not release-signed.\n' >&2
    exit 1
  }
  if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
    GROUP="$EXPECTED_TEAM_ID.group.com.symaira.cockpit"
    codesign --display --entitlements - "$APP_PATH" 2>&1 | grep -q "$GROUP" || {
      printf 'The app lacks the app group entitlement %s\n' "$GROUP" >&2
      exit 1
    }
    codesign --display --entitlements - "$APP_PATH/Contents/PlugIns/SymCockpitFinderSync.appex" 2>&1 | grep -q "$GROUP" || {
      printf 'The FinderSync extension lacks the app group entitlement %s\n' "$GROUP" >&2
      exit 1
    }
  fi
  printf 'Release signature check passed: all Mach-O parts are Developer ID, runtime, timestamped (team %s).\n' "$EXPECTED_TEAM_ID"
fi

SIGNATURE_INFO=$(codesign --display --verbose=2 "$APP_PATH" 2>&1 || true)
if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_INFO"; then
  printf '%s\n' 'Bundle smoke check: ad-hoc unsigned build (expected outside release).'
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
