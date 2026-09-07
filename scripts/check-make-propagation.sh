#!/usr/bin/env bash
#
# Regression gate for the `build` and `test` recipes in the repository Makefile.
#
# The release workflow gates on `make test` (.github/workflows/release.yml). A
# recipe that swallows a package failure lets a tag build, sign, notarize and
# publish while a package's suite is red. This check proves the recipes both
# attempt every package and report a failing status, without needing a real
# Swift toolchain: it copies the Makefile into a scratch tree of stub packages
# and puts a stub `swift` on PATH that fails only inside a chosen package.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES=(tune operate scope history)
FAILING_PACKAGE="${FAILING_PACKAGE:-tune}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$REPO_ROOT/Makefile" "$work/Makefile"
for p in "${PACKAGES[@]}"; do
  mkdir -p "$work/$p"
done

# Stub toolchain: succeeds everywhere except inside $FAILING_PACKAGE, so a
# failure is injected without touching any real package.
mkdir -p "$work/bin"
cat > "$work/bin/swift" <<STUB
#!/usr/bin/env bash
pkg="\$(basename "\$PWD")"
if [ "\$pkg" = "\$STUB_FAILING_PACKAGE" ]; then
  echo "  \$pkg: 1 TEST FAILED" >&2
  exit 1
fi
echo "  \$pkg: ok"
exit 0
STUB
chmod +x "$work/bin/swift"

run_make() {
  # $1 = target, $2 = failing package ("" for a clean tree)
  local target="$1" failing="$2" out rc
  set +e
  out="$(cd "$work" && PATH="$work/bin:$PATH" STUB_FAILING_PACKAGE="$failing" make "$target" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return $rc
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. A failing package must produce a non-zero status ...
echo "== make test with '$FAILING_PACKAGE' failing"
if output="$(run_make test "$FAILING_PACKAGE")"; then
  printf '%s\n' "$output"
  fail "make test exited 0 while '$FAILING_PACKAGE' failed"
fi
printf '%s\n' "$output"

# ... and must still have attempted every package.
for p in "${PACKAGES[@]}"; do
  printf '%s\n' "$output" | grep -q "==> test $p" \
    || fail "make test skipped package '$p' after '$FAILING_PACKAGE' failed"
done

# 2. `build` must propagate a failure the same way.
echo "== make build with '$FAILING_PACKAGE' failing"
if output="$(run_make build "$FAILING_PACKAGE")"; then
  printf '%s\n' "$output"
  fail "make build exited 0 while '$FAILING_PACKAGE' failed"
fi
for p in "${PACKAGES[@]}"; do
  printf '%s\n' "$output" | grep -q "==> build $p" \
    || fail "make build skipped package '$p' after '$FAILING_PACKAGE' failed"
done

# 3. A clean tree must still succeed and still cover every package.
echo "== make test on a clean tree"
output="$(run_make test "")" || fail "make test exited non-zero with no failure injected"
for p in "${PACKAGES[@]}"; do
  printf '%s\n' "$output" | grep -q "==> test $p" \
    || fail "make test did not attempt package '$p' on a clean tree"
done

echo "OK: make build/test attempt every package and propagate failure"
