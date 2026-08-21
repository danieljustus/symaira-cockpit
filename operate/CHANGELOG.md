# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.1]

### Fixed
- Classify ScreenCaptureKit display-mismatch capture failures as unavailable and provide actionable doctor advice (#109).

### Tests
- Tolerate hosts with no ScreenCaptureKit-visible display in smoke and MCP tests (#107).

### Documentation
- Correct SECURITY.md links and remove the hand-counted README test total (#106).

## [0.6.0]

### Added
- MCP server migrated to symaira-appkit's `SymairaMCP` module (#97, #98).

### Fixed
- Machine-readable `error.data.code` restored on genuine `AutomationError` faults (#103).

### Dependencies
- Bump actions/download-artifact to v8 (#99).

## [0.5.0]

### Added
- Bounded `history.jsonl` growth with hardened file permissions (#87, #90).
- Tests for invalid, oversized and truncated MCP `Content-Length` frames.

### Changed
- MCP stdin reads are buffered instead of byte-by-byte (#93).
- CI coverage pipeline fails fast on test failures (#92).

### Fixed
- TCC screen-capture denial is classified as `permissionDenied` (#84, #89).
- `PermissionFlags.grantedPermissions` is enforced across all action paths (#91).

## [0.4.0]

### Changed
- Version constant aligned with the v0.4.0 tag (was still 0.2.4).

### Fixed
- CI coverage pipeline: robust profraw discovery and artifact handling.

### Dependencies
- Bump github.com/danieljustus/symaira-appkit to 0.6.1 (#74), actions/upload-artifact to v7 (#73), actions/download-artifact to v8 (#72).

## [0.2.4]

### Fixed
- Sign binary before DMG packaging so notarization succeeds (#54).

## [0.2.3]

### Added
- CI verifies the DMG asset and publishes the Homebrew cask on release (#52).

## [0.2.2]

### Changed
- Community/repo hygiene: README, security policy, labels, and project-field
  fixes from a `gh-audit` pass (#48).
- Canonical Apache-2.0 license text (#49).

## [0.2.1]

### Security
- Hardened safety guards around destructive controls and secure text fields,
  including refusal of raw-coordinate clicks/drags that bypass element-based
  checks (#29, #42).
- Refined `ActionPolicy` allow/deny-list handling for menu and element actions
  (#14, #29).

### Added
- Multi-display support: choose a display by ID or index for screenshots and
  UI queries (#14).
- Window-scoped screen capture and `focus_window` / `list_windows` enrichment
  (#14).
- OCR fallback via Vision framework for applications with weak Accessibility
  metadata, with configurable confidence threshold (#14).
- Configurable action policy (allow/deny lists) for richer UI targeting (#14).
- UI query predicates by role, title, label, and frame (#14).
- Async `wait_for` polling with `Task.sleep` to reduce AX IPC load (#30).
- `version` MCP tool and CLI command that report the current build and check
  GitHub releases for updates (#14).

### Fixed
- Prevent snapshot PNG accumulation in the temporary directory (#14).
- Eliminate force-casts in `AXHelpers` in favor of safe CF type checks (#29).
- Dependency bumps for GitHub Actions workflows (#1, #27, #28).

## [0.1.0]

Initial Symaira release: the author's `mac-operator` prototype rebranded and
aligned to Symaira conventions. Builds; 29 tests passing.

### Added
- SPM package: `SymOperateCore`, `SymOperateMCP`, `symoperate` (executable).
- CLI: `serve`, `doctor`, `permissions status|grant`.
- MCP stdio server with tools: `snapshot`, `query_ui`, `list_apps`,
  `list_windows`, `click`, `type_text`, `press_keys`, `scroll`, `drag`,
  `launch_app`, `focus_window`, `menu_action`, `wait_for`, `permissions_status`.
- Safety guards: destructive-control refusal, `AXSecureTextField` block,
  ephemeral `element_id` cache.

### Not yet (see docs/roadmap.md)
- Multi-display capture, OCR fallback, stronger action policy, corekit/release
  alignment, Swift 6 strict concurrency.
