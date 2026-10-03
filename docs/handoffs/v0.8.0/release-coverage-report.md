# Historical prepublication evidence

This record predates publication. Current release status is in `release-verification.json`; do not follow its obsolete publish/closure instructions.

<!-- coverage: timestamp=2026-10-03T07:05:03Z repo=danieljustus/symaira-cockpit head=1cfac18e5612b620d3fe15cb1965072bdba620e1 overall=51.384026 patch=n/a baseline=50.896772 delta=+0.487254 mutation=n/a assertdensity=2.572289 slowtests=9 suite=43.849179 -->

# Release-baseline coverage

- Result: WARN. No repository hard floor; the default 80% expectation is advisory.
- HEAD: 7778/15137 executable production lines, 51.384026%.
- Baseline v0.7.0 (f6910fb19660b59d23cbb3413d67159983854cf0): 7662/15054 lines, 50.896772%. Diagnostic delta +0.487254 percentage points; patch n/a on clean aligned main.
- Measurement: SwiftPM coverage in root/Tune/history; LCOV DA union by tracked production file/line using maximum hits. Test/dependency/generated code excluded; all GUI/CLI zero-hit code retained.
- Local command: swift test --enable-code-coverage --jobs 2; Tune additionally --skip WriteSurfaceTests. 15 unsafe legacy unit methods excluded locally (#316), not falsely claimed as passed. The production denominator is unchanged by this safety exclusion.
- HEAD local: 969 executions, 1 skipped, 0 failures. Baseline: 941, 1 skipped, 0 failures.
- Exact HEAD CI: 984 executions, 1 skipped, 0 failures in root/Tune/history. Separate advisory coverage jobs repeat 927 executions; they are not double-counted in the primary suite total. CI run 37104615077.
- Environment: same Xcode 27 / Swift 6.4, shared isolated HOME/CFFIXED_USER_HOME, inherited XDG/LLVM overrides removed. Full-history baseline clone verified against peeled v0.7.0. Test/export processes all exit 0, no coverage warnings.
- Older 51.79% measurements included local hardware-write tests and are not directly comparable. This delta uses newly measured identical commands on HEAD/baseline.
- Quality: lexical XCTest scan 2562 assertion tokens/996 declared methods (2.572289/method); heuristic, not AST proof. Mutation unconfigured/not requested. 9 executions over 0.5 seconds, advisory integration/CLI timing. No additional systemic AAA issue inferred.

## Findings
- [ ] **[Tests/Design] Isolate legacy display-write unit tests**
  - **Status quo:** tune/Tests/SymTuneCoreTests/SymTuneCoreTests.swift WriteSurfaceTests use the default hardware adapter; tracked in #316.
  - **Likely cause:** older controller tests predate existing mocks.
  - **Proposed solution:** reuse the mock injection seam; real-device acceptance stays opt-in.
  - **Uncovered:** n/a.
  - **Effort/Impact:** Low effort / medium impact.

Evidence: `release-coverage.json`, `baseline-v0.7.0-coverage.json` and the linked public Actions run. Host-specific raw logs are deliberately excluded.
