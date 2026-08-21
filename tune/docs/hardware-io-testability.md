# Hardware-dependent I/O testability decision

Issue: #139 — Hardware-dependent I/O paths are hard to unit-test

## Background

`SymTuneCore` contains several services that wrap hardware I/O:
- `DisplayService` (61.84% line coverage)
- `SMCService` (74.27%)
- `BatterySource` (40.45%)
- `PowerAssertionSource` (4.17%)
- `EDROverlayService` (23.81%)

These services call `IOKit`, `NSScreen`, `CoreGraphics`, `IOPMAssertionCreateWithName`, and `CAMetalLayer`. The low coverage is structural: CI runs headless and without real SMC/display hardware, so the hardware-facing blocks cannot execute in unit tests.

## Current testability seams

Some services already expose protocol boundaries:

| Service | Protocol boundary | Test coverage status |
|---|---|---|
| `SMCService` | `SMCConnectionProtocol` | Good — mock connection tests exist |
| `BatterySource` | `BatterySource` protocol | Good — fake source tests exist |
| `DisplayEnumerationSource` | `DisplayEnumerationSource` protocol | Good — fake enumeration tests exist |
| `PowerAssertionSource` | `PowerAssertionSource` protocol | Good — fake assertion tests exist |
| `EDROverlayService` | `EDROverlayServiceProtocol` | Extracted — mock/fake overlay tests enabled |

The existing protocol boundaries prove the pattern works: business logic is testable via fakes, while the hardware-facing implementations remain thin wrappers.

## Options evaluated

### Option A — Integration tests for hardware backends

Run real hardware calls in CI or on a dedicated runner.

- **Pros**: Tests the exact code that ships; catches real IOKit/CoreGraphics mismatches.
- **Cons**: Requires physical Apple Silicon/Intel hardware, attached displays, and SMC access in CI. GitHub-hosted `macos-latest` runners are virtualized and do not expose real SMC or multi-display EDR hardware. Self-hosted runners would be needed, adding infrastructure cost and flakiness.
- **Verdict**: Not practical for CI. Manual verification on real hardware remains valuable but does not close the CI coverage gap.

### Option B — Protocol boundaries for every service

Abstract every hardware call behind a protocol so unit tests can mock it.

- **Pros**: Enables unit tests for business logic; consistent with the existing `SMCConnectionProtocol`/`BatterySource` pattern.
- **Cons**: `EDROverlayService` is deeply coupled to `NSWindow`/`CAMetalLayer`/`NSScreen`. Abstracting these AppKit/Metal types into a protocol adds indirection without testing the actual EDR behavior (which is the point of the service). The seam would test "does the service call the provider correctly" rather than "does the overlay actually brighten the display."
- **Verdict**: Appropriate for services whose value is logic (SMC key selection, battery property parsing), but low-value for `EDROverlayService` whose value is the hardware effect itself.

### Option C — Hybrid: keep existing seams, add a minimal seam for EDROverlayService, rely on manual verification for hardware effects

- Keep the existing protocol boundaries (`SMCConnectionProtocol`, `BatterySource`, `DisplayEnumerationSource`, `PowerAssertionSource`) and expand unit tests that exercise edge cases through them.
- Add a narrow `EDROverlayWindowProvider` seam that lets tests verify `EDROverlayService` state management (overlay creation, headroom updates, removal) without asserting real EDR hardware behavior.
- Accept that true EDR brightness and SMC fan control require manual verification on real hardware; document this in `docs/manual-app-verification.md`.

## Decision

Adopt **Option C** (hybrid).

Rationale:
1. The existing protocol-boundary pattern is already proven in this codebase and covers the services where logic matters most.
2. `EDROverlayService` benefits from a *minimal* seam for state-management tests, but a full AppKit/Metal abstraction would obscure more than it clarifies.
3. Integration tests on real hardware are impractical for CI and would introduce flakiness; manual verification remains the correct gate for hardware effects.

## Follow-up plan

1. **Expand unit tests using existing seams** (no new protocols needed):
   - `SMCServiceTests`: cover error paths and key-detection branches already exercised via `SMCConnectionProtocol`.
   - `BatteryServiceTests` / `PowerServiceTests` / `DisplayServiceTests`: add edge-case tests via the existing fakes.
2. **Add a minimal `EDROverlayWindowProvider` seam** in a follow-up issue:
   - Extract overlay creation/removal into a provider protocol.
   - Test `EDROverlayService` state management (apply/remove/headroom tracking) with a fake provider.
   - Keep the real `EDROverlayWindow` implementation unchanged for production.
3. **Manual verification checklist**:
   - Update `docs/manual-app-verification.md` with explicit EDR/extended-brightness and fan-control verification steps for real hardware.
   - Require a manual verification pass before releases that touch `EDROverlayService`, `SMCService` fan paths, or charge-limit paths.

## Acceptance criteria mapping

- [x] A decision is documented in the issue or a follow-up plan is created. → This document.
- [x] Any chosen testability seam preserves current runtime behavior. → No production code changes in this PR; the follow-up seam is additive.
- [x] Existing tests continue to pass. → Verified by CI (`swift build`, `swift test`, `swiftlint`, `build-app`).
