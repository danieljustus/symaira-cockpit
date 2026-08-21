<!-- review: timestamp=2026-07-28T21:16:41Z  repo=danieljustus/symaira-operate  head=70e28fb -->
<!-- adopt: source=kvcache-ai/AgentENV  source_ref=6296bc4be7ad79eb3a278eb5264ef011c341adf5  source_url=https://github.com/kvcache-ai/AgentENV  depth=clone  license=MIT -->

# Adoption Report — symaira-operate ← kvcache-ai/AgentENV — 2026-07-28

## Sources

| Field | Value |
|---|---|
| SOURCE | `kvcache-ai/AgentENV` (https://github.com/kvcache-ai/AgentENV) |
| Ref analyzed | `6296bc4` (`main`) |
| Language / License | Rust (4.7 MB) + Go (350 KB) + Shell / MIT |
| Health | 1408 stars, 126 forks, last push 2026-07-28, **created 2026-07-23 — five days old**, one release `v0.1.0` (2026-07-25), 1.5 GB disk |
| Scope | all facets, full clone |
| TARGET | `danieljustus/symaira-operate` @ `70e28fb` |

## Verdict

This is the weakest of the four pairings. AgentENV is a Linux/KVM microVM platform for
running agent sandboxes at scale; symoperate is a native macOS Swift binary that drives
the local GUI over MCP. Different language, different OS, opposite trust model (they run
agent code in disposable VMs, we deliberately act on the user's real desktop under
supervision), and none of their sandbox, storage or scheduling work transfers. Only one
finding survives the gates: their coverage pipeline is built on the same LLVM tooling
Swift uses, and symoperate has 127 tests with **no coverage measurement at all** — a gap
our own repo makes visible and their pipeline shows a clean shape for.

Health caveat: the repo is five days old with no maintenance history, so upstream
practice is not evidence by itself. Confidence capped at `medium`.

## What we already do as well or better

- Supervised, local-only trust model → `SAFETY_AUDIT.md` and `Sources/SymOperateCore/ActionPolicy.swift`; upstream ships a README warning that it has **no authorization at all** and must not be exposed to a network.
- Curated release notes and prerelease gating → `.github/prerelease/*.md` + our `06/07` release flow beats their `cliff.toml` commit dump.
- Signed, packaged distribution → Homebrew tap + DMG via `.github/workflows/release.yml` is better than their `curl … | sudo bash` install script.
- Community and contribution surface → `.github/CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue templates and a PR template; upstream has composite actions but none of these.
- Lint gate enforced in CI → `swiftlint --strict` at `.github/workflows/ci.yml:37-44`, matching their `clippy -D warnings` discipline.

## Findings

- [ ] **[UX/DX] Measure test coverage in CI and publish it as a badge on an orphan branch**
  - **Status quo:** `.github/workflows/ci.yml:26-35` runs `swift build` and `swift test` only, and `Makefile` has no coverage target — so with 127 tests across 11 test files we cannot say which of `Sources/SymOperateCore/` is exercised. That matters most for the safety surface: `Sources/SymOperateCore/ActionPolicy.swift` is the code that refuses destructive controls and secure text fields, and `SAFETY_AUDIT.md` asserts that behavior without a coverage number backing it. Upstream `.github/workflows/coverage.yml:29-44` runs `cargo-llvm-cov` as a non-blocking informational job and, in a second job (lines 60-135), force-publishes `badge.json`, `badge.svg` and `coverage.json` to an orphan `coverage-data` branch that their README badge reads from — keeping `main`'s history clean.
  - **Proposed solution:** Pattern adoption, no code copy. Add a `coverage` job to `.github/workflows/ci.yml` running `swift test --enable-code-coverage` and reducing the profile with `xcrun llvm-cov export` — the same LLVM toolchain their `cargo-llvm-cov` wraps — emitting `coverage.json` plus a shields-compatible `badge.json`/`badge.svg`; start non-blocking (`continue-on-error`), then add a `publish-coverage-data` job gated on pushes to `main`. Add the badge to `README.md` next to CI/Release/License/Swift. Introduce a threshold only once a baseline number exists.
  - **Effort/Impact:** Medium effort / medium impact. Gives `SAFETY_AUDIT.md`'s claims a measurable backing and a baseline for future test work; non-blocking from day one, so it cannot break the pipeline. Fully reversible — delete the job and the branch.

## Considered and rejected

- **Firecracker microVM sandboxing, overlaybd, ublk, uffd snapshots, memory ballooning, P2P transport, K8s deployment** (`src/sandbox/`, `storage/`, `src/p2p/`, `deploy/k8s/`) — gate 1 (Transferable): requires Linux 6.8+ and `/dev/kvm`; symoperate is macOS-only Swift with no VM layer. The overwhelming majority of the repo dies here.
- **Running agent actions inside a disposable sandbox** — gate 1 (Transferable): the opposite of symoperate's purpose. Our value is operating the user's real GUI under supervision; isolating that would remove the product.
- **Dispatch-only mutation-testing workflow** (`.github/workflows/mutation-tests.yml`) — gate 4 (Worth it): the workflow shape is sound, but Swift's mutation tooling (`muter`) is far behind `cargo-mutants` and would be a new, poorly-maintained dependency on a macOS runner. Revisit after coverage exists — there is nothing to mutate-test meaningfully without a baseline.
- **TTY-aware output-format resolution** (`crates/aenv/src/output.rs:19-27`) — gate 3 (Better): our CLI surface is a doctor/permissions/history helper around an MCP stdio server, not a resource-listing CLI; a table/JSON renderer would abstract over roughly one call site (`Sources/symoperate/main.swift:168`). Machine-readable output for symoperate is an MCP concern, already tracked as #60.
- **Composite actions to dedupe CI setup** (`.github/actions/rust-ci-setup/`) — gate 4 (Worth it): they dedupe across 12 workflows; we have 2, and our setup is `actions/checkout` plus a `brew install`.
- **mdbook docs site on GitHub Pages** (`.github/workflows/docs.yml`) — gate 4 (Worth it): `README.md` plus `docs/architecture.md`, `docs/macos-agent-guide.md` and `docs/roadmap.md` render fine on GitHub; a Pages deployment is a surface a solo repo must keep green for no reader gain. Rule 9 (scale fit).
- **`git-cliff` changelog generation** (`cliff.toml`) — gate 3 (Better): `CHANGELOG.md` is curated through our release flow; cliff would downgrade it to a grouped commit dump.
- **`alibaba/open-code-review` on `pull_request_target`** (`.github/workflows/open-code-review.yml`) — gate 4 (Worth it): grants fork-PR-triggered runs access to repo secrets and pins the action to `@main`. We already run the `01-code-review` skill.
- **`config/deps_manifest.toml` pinned tool downloads** — gate 3 (Better): version-pinned URLs with no checksums; weaker than our Homebrew/release-asset path.
- **Benchmark workflows and `benches/`** (`.github/workflows/benchmark.yml`) — gate 4 (Worth it): they defend sub-100 ms snapshot claims as a product promise; symoperate's latency is dominated by macOS Accessibility APIs we do not control.

## Open questions

- Does `swift test --enable-code-coverage` produce a usable profile for both `SymOperateCoreTests` and `SymOperateSmokeTests` on a `macos-15` runner, and do the smoke tests distort the number? Run it once locally before writing the workflow — if the smoke suite dominates, scope coverage to `SymOperateCore`.
- What coverage does `ActionPolicy.swift` actually have today? The answer determines whether finding 1 is a formality or exposes a real gap in the safety surface — and it is unanswerable from outside.
- Upstream is five days old; none of these practices has survived a maintenance cycle there. No evidence available either way.

**First step:** run `swift test --enable-code-coverage` locally once to get a baseline number for `SymOperateCore`, then wire the non-blocking `coverage` job.
