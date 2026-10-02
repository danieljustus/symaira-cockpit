# Code continuation: symaira-cockpit

## Goal and immutable starting point

Continue the code and integration work from the published repository, without needing a local chat, private reports or installed agent skills. This handoff was refreshed on 2026-10-02; its historical checkpoint remains available in Git history.

- GitHub repository: `danieljustus/symaira-cockpit`.
- Canonical continuation branch: `main`. Historical checkpoint branch: `handoff/20260930-cloud`.
- Base code commit before this document/checkpoint: `a04f14134692951305f3495935e9882ac2f43220`.
- Working directory for every command below: the checked-out repository root.
- Publication does not authorize a merge, release, tag, destructive cleanup or paid service.
- Continuation PR: #299. Its current diff is documentation only; verify that diff and required checks independently from product acceptance.

Retain the existing product code without declaring native accessibility acceptance complete. The product owner explicitly approved integrating the label-only correction in #293 after required CI, with native keyboard/VoiceOver operation retained as the open, deferred follow-up #305. Compatibility-prefix removal remains future work for Cockpit v0.10 in #259.

## Requirements, decisions and next task

The embedded Tune `0.10.0` source correction is merged through #306 at `fda578a39fff96f99185e008ad6ea4ba6f093080`. The actual compiled CLI report and dated changelog agree; #278 remains open until the next Cockpit release artifact is published and verified. The published Cockpit v0.7.0 artifacts are unchanged. Schedule native keyboard/VoiceOver acceptance separately through #305; do not start VoiceOver, raise windows or inject foreground keys during the owner's active desktop use. The outstanding native checks are deferred, not passed. A cloud Linux build cannot substitute for native acceptance.

Keep products and their optional modules standalone. Preserve exact dependency pins, snake_case contracts, data integrity, authorization and MCP stdout discipline. Keep frozen fixture evidence and original Oracle ancestry unchanged until an explicit preservation design is accepted. Do not rewrite history, force-push, bypass branch protection, delete unique work, close unproven issues or reinterpret a passing subset as complete acceptance.

- PR #293 is merged as `818a2937992dbcd55bb932ab6d2a96cbafa52f1a`, closing the label-correction scope of #282. Its four required checks and local root/Tune/history builds/tests passed. AX names and native operation evidence are distinct; #305 preserves the missing operation checks.

## Setup and scoped verification

Clone the existing public repository, checkout `main`, verify its current remote HEAD, and read this file before making changes. Historical-checkpoint reproduction must use its recorded commit separately, not silently mix source variants.

```sh
git clone --branch main https://github.com/danieljustus/symaira-cockpit.git
cd symaira-cockpit
git rev-parse HEAD
git ls-remote --exit-code origin refs/heads/main
git status --porcelain=v1 -uall
```

Locally observed toolchains: Git 2.54.0, gh 2.102.0, Rust/Cargo 1.98.0, Go 1.27.1, Node 22.22.3, Ruby 2.6.10, Swift 6.4, regular Xcode. Rust repositories pin their toolchain in `rust-toolchain.toml`; honor the checked-in manifests. Go Oracle regeneration must use the exact Go version required by its own manifest/generator, not this observed machine version. Native Swift requires full Xcode. Package-manager caches are rebuildable, not required private inputs.

Scoped reproduction commands, not a claim of the complete product suite:

```sh
swift package resolve
swift test
```

Build command (not claimed executed unless listed in verification):

```sh
swift build
```

Start/help command (not executed for live services/devices):

```sh
swift run symcockpit --help
```

For Rust, optional resource limits are `CARGO_BUILD_JOBS=2`, `CARGO_PROFILE_TEST_DEBUG=0`, `CARGO_PROFILE_DEV_DEBUG=0`. `CARGO_TARGET_DIR` may name a fresh build-output directory on stable storage; it is never a source, fixture or configuration input. Do not reuse a build-target directory between code variants when validating changed tests. Each fresh verification uses its own build output. No provider/API secret is required for these scoped mock/unit checks. Do not use real credential, document, broker or router state. Do not enable paid model fallback.

## Dependencies and exclusions

Tracked lockfiles, manifests, generators and fixtures are the reproducible input. Build outputs (`target`, `.build`, `node_modules`, `dist`), dependency caches, coverage output and generated binaries are deliberately excluded and rebuilt. Older unrelated branches, private audit/planning reports, harness settings, personal records, real credential contents, local stores and original unrelated credential-store WIP are excluded, not hidden dependencies of the checks above. No raw chat or private memory is published.

Pinned Git dependency commits found in the selected top-level manifest: none in the inspected top-level manifests. Package managers must resolve these through public repositories; a fresh-checkout failure to fetch any is a concrete reproducibility blocker, not permission to alter a pin.

Native GUI/Keychain/Touch ID, signing, notarization, and real user-permission behavior need macOS/hardware and remain unverified by generic cloud execution. Network access to GitHub and applicable package registries is required for dependency setup. Production access, signing credentials and live-service secrets must be separately supplied through approved secret management, never this repository. No cloud job is launched by this document.



## Verification record

Prepublication secret-pattern/outgoing-history scans succeeded for the selected base. Exact WIP path/byte comparison is required for checkpoint variants. Product-acceptance and target-cloud runtime are **not checked** by these records.

The current diff against `main` changes only this handoff. The following fresh-clone record is historical evidence for its recorded checkpoint, not a claim about a later HEAD.

Fresh remote-clone verification was executed locally on macOS at published checkpoint `ca6607960411f5ddf95308328188e480d69bc0f6`. The repository was cloned directly from GitHub, without copied worktree files, stashes or source/configuration overrides. The following scoped command chain exited **0**:

```sh
swift package resolve
swift test
```

The commands recorded for this Swift repository are the scoped Swift commands above; generic Rust build limits do not describe a Cockpit test result. Package manager dependency caches were allowed; application state and credentials were not supplied. This verifies repository-contained inputs and these scoped checks, not every product test or native acceptance criterion. The published final HEAD must still be verified before continuation. Target cloud runtime, permissions, secrets and network gates: **not checked**.

## Copyable continuation request

Work in `danieljustus/symaira-cockpit` on `main`. Verify the current remote HEAD, read `docs/handoffs/end-work-cloud.md`, and run the setup and scoped checks before further edits. The Tune source correction is merged; #278 still requires publication and verification of the next Cockpit release artifact. Retain the compatibility warning through v0.9 and track its v0.10 removal in #259. Native keyboard/VoiceOver acceptance is the owner-approved deferred follow-up #305, not a passed result. Do not interrupt active desktop use. Respect all preservation and integration gates above.
