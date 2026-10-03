# Historical prepublication evidence

This record predates publication. Current release status is in `release-verification.json`; do not follow its obsolete publish/closure instructions.

<!-- prerelease: timestamp=2026-10-03T07:05:03Z repo=danieljustus/symaira-cockpit head=1cfac18e5612b620d3fe15cb1965072bdba620e1 target=v0.8.0 bump=minor gate=pass -->

# Final release gate

Clean aligned main 1cfac18e5612b620d3fe15cb1965072bdba620e1; release-owned version/docs changes merged through PR #318. Computed target v0.8.0 from last stable v0.7.0 and unreleased direct-CLI/workspace features. No override. #313/#314 closed by PR #317; no open PR/active claim. No tag/publication yet.

| Check | Result | Evidence |
|---|---|---|
| Exact HEAD CI/tests | PASS | https://github.com/danieljustus/symaira-cockpit/actions/runs/37104615077, completed success. Full remote suites. Local safety-scoped 969 executions, 1 skipped, 0 failures. |
| Build/lint | PASS | Root version tests, Release app build and compiled CLI/GUI version probes. 18 changed Swift files with repository config: no errors, 7 existing warnings. |
| Version/docs | PASS | CockpitVersion/README/datestamped changelog 0.8.0; embedded Tune 0.10.0 documented in Cockpit 0.8.0. Historical v0.7.0 remains immutable. No-Pro boundary and actual CLI graph corrected. |
| Coverage | WARN | Fresh actual-HEAD 51.384026%; full GUI/CLI denominator. Default 80% expectation only; no repo hard floor. [Report](release-coverage-report.md). |
| Baseline/patch | INFO | Immutable v0.7.0 measured with same toolchain/environment/commands: 50.896772%; delta +0.487254pp; patch n/a. |
| Assets/publishers | PASS | Tag workflow builds universal CLI tarball/checksums and signed/notarized/stapled GUI ZIP/DMG. Separate Formula and Cask writers use exact asset hashes. All seven release secret names present. Actual bytes/version/signature checks remain required after publication. |
| Security | PASS | Fresh paginated code-scanning/Dependabot reads: zero open. |
| Milestone | WARN | Rename to v0.8.0 verified; #278 waits for downloaded artifact proof, #305 explicitly owner-deferred. Never force-close acceptance. |

Advisories: #315 diagnostics, #316 legacy hardware-write tests excluded locally but covered by remote CI; no production lines excluded. #305 keyboard/VoiceOver unverified by explicit owner deferral. Old unique branch/worktree content is preserved and may block final main-only cleanup.

Gate pass permits only the existing release workflow. No tag/release claimed yet.
