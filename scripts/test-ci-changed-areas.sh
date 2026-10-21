#!/usr/bin/env bash
#
# Regression check for scripts/ci-changed-areas.sh, run by the `changes` job
# in .github/workflows/ci.yml before it selects jobs.
set -euo pipefail

MAP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-changed-areas.sh"
failures=0

# expect "<expected jobs, space separated>" <changed path>...
expect() {
  local want="$1"; shift
  local got
  got="$(printf '%s\n' "$@" | "$MAP" | sed -n 's/=true$//p' | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" != "$want" ]; then
    printf 'FAIL %s: want [%s], got [%s]\n' "$*" "$want" "$got" >&2
    failures=$((failures + 1))
  fi
}

all="tuning history root icon make"
expect "" .github/dependabot.yml
expect "" README.md docs/product-boundaries.md .github/pull_request_template.md
expect "tuning root" tuning/Sources/SymCockpitCore/Version.swift
expect "tuning history root" history/Sources/SymCockpitHistory/X.swift
expect "root" Tests/SymCockpitE2ETests/X.swift
expect "root" .github/workflows/release.yml
expect "root icon" assets/branding/AppIcon.sha256
expect "make" scripts/check-make-propagation.sh
expect "$all" .github/workflows/ci.yml
expect "$all" Makefile
expect "$all" Package.resolved
expect "$all" tuning/Package.swift
expect "$all" an/unknown/path
expect "$all" .github/actions/new/action.yml
expect "$all" README.md scripts/ci-changed-areas.sh

if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "ci-changed-areas: all cases passed"
