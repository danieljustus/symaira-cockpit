# Contributing to SymTune

Thanks for your interest in contributing to SymTune! This document covers
Swift package development, testing, and the credential-resolution conventions.

## Prerequisites

- **macOS 14+** or **Linux** with Swift 6.1+ toolchain
- **Xcode 26.4+** (macOS) — select via:
  ```bash
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  ```

## Quick start

```bash
# Build
swift build --package-path tune

# Test (all platforms)
swift test --package-path tune

# Test with verbose output
swift test --package-path tune --verbose
```

## Project structure

```
tune/
  Sources/
    SymTuneCore/    # Core logic: providers, models, credential resolution
    SymTuneUI/      # Swift Package plugins (e.g. APIKeyField for Xcode build phases)
    SymTuneCLI/     # CLI entry point (swift-cli-plugin for `xcodebuild` integration)
  Tests/
    SymTuneCoreTests/  # Unit tests (757 tests)
    SymTuneCoreIntegrationTests/  # Integration tests against live APIs
```

## Credential resolution (issue #18)

All providers use `DefaultCredentialResolver` for credential resolution with this
precedence chain:

1. **symvault op:// reference** — resolved via `symvault get <ref> --print`
2. **Environment variable** — e.g. `OPENROUTER_API_KEY`
3. **Keychain** — service `com.symaira.symtune`, account varies by provider

New providers should conform to `AIUsageProvider` and implement:
- `credentialSource: String` — returns provider ID (e.g. `"openrouter"`)
- `credentialDescriptor: AIUsageCredentialDescriptor?` — describes what credentials are needed
- `credentialResolver.resolve(opReference:envKey:keychainService:keychainAccount:)` — delegates to the standard resolver

## Testing conventions

- Every new public API needs unit tests in `SymTuneCoreTests/`
- Use `@testable import SymTuneCore` with `NewRootCmd` pattern for CLI tests
- Tests run on Linux CI — `XCTMain` is not used; Swift Testing discovers automatically
- `CredentialResolverTests` covers all resolution paths (op://, env, keychain, fallback)
- 8 tests, all passing ✅

## CI / CD

- GitHub Actions CI runs on every PR: build + test (757 tests)
- CodeQL runs on push to main and PRs
- Releases are triggered by tags (`vx.y.z`) — see `.github/workflows/release.yml`
- Release workflow signs + notarizes the macOS app bundle

## Style guide

- Swift 6 strict concurrency mode enabled
- All public types are `Sendable` unless documented as non-Sendable
- Prefer `private var` for mutable state, `let` for immutable
- Use `// MARK:` section separators

## Submitting changes

1. Fork + branch from `main`
2. Make changes + write/update tests
3. Run `swift test` — all tests must pass
4. Push + open PR
5. CI must be green before merge
6. If your change affects credentials, update `credentialSource`/`credentialDescriptor` in all affected providers
