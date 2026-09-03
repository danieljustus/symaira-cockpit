# Contributing to Symaira Cockpit

Thanks for contributing to Symaira Cockpit. This repository ships one native
macOS command-line binary, `symcockpit`, with `tune`, `operate`, and `scope`
families, plus the `SymCockpitApp` menu-bar GUI.

## Prerequisites

- macOS 15 or newer
- Swift 6 and Xcode 26.4 or newer
- A checkout of this repository

Select the full Xcode toolchain when needed:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

The project is macOS-only because it uses AppKit, IOKit, Accessibility, and
ScreenCaptureKit APIs.

## Repository layout

```
Sources/symcockpit/       # unified dispatcher and version reporting
Sources/SymCockpitApp/    # SwiftUI/AppKit menu-bar and cockpit window
Tests/                    # dispatcher and GUI integration tests
tune/                     # thermals, power, display, and Tune UI package
  Sources/SymTuneCore/    # hardware and configuration logic
  Sources/SymTuneUI/      # shared menu-bar panel
  Sources/SymTuneCLI/     # Tune command library
operate/                  # macOS GUI automation package
  Sources/SymOperateCore/ # Accessibility, input, app, and permission logic
  Sources/SymOperateMCP/  # Operate MCP transport
  Sources/SymOperateCLI/  # Operate command library
scope/                    # ports, containers, and MCP inventory package
history/                  # shared library: canonical history, replay codec,
                          # secret redaction, bounded subprocess runner
```

The nested packages remain independently buildable for package-level
compatibility, but only `symcockpit` is the shipped CLI binary. `history/`
is the odd one out: no CLI, no MCP server, just a library that `tune/` and
`operate/` depend on by path. It is built and tested with the rest.

## Build and test

Run the complete workspace checks with the repository Makefile:

```bash
make build
make test
```

To work on one package:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path tune
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path tune
```

Use the equivalent `operate`, `scope` or `history` path for those packages.
For root changes, run both commands from the repository root:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

Build the GUI bundle with `make build-app`; `make smoke-app` performs its
structural smoke check.

## Code and security conventions

- Keep the dispatcher, GUI, and package library layers thin: business logic
  belongs in the relevant core service, not in CLI argument plumbing or views.
- Preserve Swift 6 strict concurrency and `Sendable` annotations.
- Keep JSON output stable and snake_case.
- Do not add credential reads during object construction. The Tune package's
  `KeychainCredentials` adapter delegates to the shared keychain module, and
  `SecretRedactor` must protect error/history output at the boundary.
- Never weaken Tune safety clamps, Operate action policy, permission checks, or
  MCP stdout purity.
- Keep update checks pointed at the released `danieljustus/symaira-cockpit`
  repository and compare against the unified cockpit version.

## Pull requests

1. Create a focused branch from `main`.
2. Make the smallest cohesive change and add regression tests.
3. Run the affected package's build and test commands, plus root checks when
   root sources or the GUI are affected.
4. Describe the behavior change and the commands that passed.

For security vulnerabilities, follow [SECURITY.md](SECURITY.md) rather than
opening a public issue.
