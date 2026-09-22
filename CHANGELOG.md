# Changelog

## Unreleased

### Changed
- Release artifacts are stripped before packaging: the CLI tarball and the
  app executable no longer ship the full Swift symbol table (112k symbols,
  more than half the binary size). The CLI keeps an ad-hoc signature so it
  still execs on arm64; the app is stripped before its Developer ID
  signature.

## [0.7.0] — 2026-09-22

Tune-only product cutover (PB-2026-09-09): Symaira Cockpit is now only the
macOS hardware/system-tuning product. Operate and Scope are optional Symaira
Brain modules.

### Added
- Most tune commands now also work without the `tune` prefix (for example
  `symcockpit sensors` == `symcockpit tune sensors`). `symcockpit tune
  <command>` keeps working unchanged; the four colliding names (doctor,
  permissions, serve, history) stay reachable only via `tune` (#260).

### Changed
- **Breaking: `symcockpit operate` and `symcockpit scope` are removed.** The
  Operate and Scope packages, dispatcher commands, GUI sections and related
  tests were retired from Symaira Cockpit; the capabilities live in Symaira
  Brain as optional modules. Legacy callers get a migration hint — install
  from a Brain checkout with `symbrain setup --from-source <brain-checkout>
  --modules operate,scope` — and exit 4 (#267, #277).
