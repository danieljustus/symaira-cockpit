#!/bin/bash
# Make the Xcode Metal shims usable for `swift build` on hosted CI runners.
#
# Xcode 26+ ships the Metal compiler as a separate component. On GitHub's
# hosted macOS images it is installed and `xcrun metal` works, but the shims
# in XcodeDefault.xctoolchain that Swift Build invokes by absolute path fail
# with "missing Metal Toolchain". This script installs the component if
# needed and points each shim at the real tool. CI-only: it rewrites files
# inside the selected Xcode, which is disposable on a hosted runner.
set -euo pipefail

if ! xcodebuild -showComponent MetalToolchain | grep -q 'Status: installed'; then
  xcodebuild -downloadComponent MetalToolchain
fi

bin="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin"
for tool in metal metallib metal-ar metal-dsymutil metal-nm metal-objdump metal-strip; do
  shim="$bin/$tool"
  [[ -e "$shim" ]] || continue
  if "$shim" --version >/dev/null 2>&1; then continue; fi
  real="$(xcrun --find "$tool")"
  [[ "$real" != "$shim" && -x "$real" ]] || { echo "no usable $tool behind $shim" >&2; exit 1; }
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$shim"
  chmod 755 "$shim"
  echo "$tool -> $real"
done

"$bin/metal" --version
