#!/usr/bin/env bash
#
# Maps changed paths (one per line on stdin) to the CI jobs they can affect
# and prints `<job>=true|false` lines for $GITHUB_OUTPUT (.github/workflows/ci.yml).
#
# Fail-safe by design: a path this table does not know runs every job. Only
# paths listed as "no job" may skip anything, so a new directory can never
# silently lose its tests. Add new source areas here when you add them.
set -euo pipefail

tuning=false
history=false
root=false
icon=false
make=false

all() { tuning=true; history=true; root=true; icon=true; make=true; }

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  case "$path" in
    # The workflow, every manifest/lockfile, the Makefile and this table
    # change what all jobs do.
    .github/workflows/ci.yml | scripts/ci-changed-areas.sh | scripts/test-ci-changed-areas.sh | Makefile | \
    Package.swift | Package.resolved | */Package.swift | */Package.resolved)
      all ;;
    # Path dependencies: root -> tuning -> ../history.
    history/*) history=true; tuning=true; root=true ;;
    tuning/*) tuning=true; root=true ;;
    Sources/* | Tests/*) root=true ;;
    scripts/check-make-propagation.sh) make=true ;;
    # The root job runs the icon/DMG smoke and its tests read scripts/assets.
    scripts/* | assets/*) root=true; icon=true ;;
    # Read by the root GUIVersionConsistencyTests.
    .github/workflows/release.yml) root=true ;;
    # No job builds or reads these.
    docs/* | prototypes/* | *.md | LICENSE | .gitignore | \
    .github/dependabot.yml | .github/CODEOWNERS | \
    .github/ISSUE_TEMPLATE/* | .github/audit/* | .github/workflows/codeql.yml)
      ;;
    *) all ;;
  esac
done

printf 'tuning=%s\nhistory=%s\nroot=%s\nicon=%s\nmake=%s\n' \
  "$tuning" "$history" "$root" "$icon" "$make"
