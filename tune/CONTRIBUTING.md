# Contributing to symtune

Thanks for your interest in contributing to symaira-tune! This guide covers the
supported build, test, and lint workflow, and what we expect from pull requests.

## Code of Conduct

By participating in this project you agree to abide by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started

1. **Clone the repo**:

   ```bash
   git clone https://github.com/danieljustus/symaira-tune.git
   cd symaira-tune
   ```

2. **Build**:

   ```bash
   swift build
   ```

   > **Local toolchain note:** if the Command Line Tools `swift` is broken
   > (dyld errors), build with the Xcode(-beta) toolchain instead:
   >
   > ```bash
   > DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
   > ```

3. **Run the tests**:

   ```bash
   swift test
   ```

4. **Lint**:

   ```bash
   swiftlint
   ```

   (or `make lint`; it skips gracefully when swiftlint is not installed).

5. **Try the CLI**:

   ```bash
   swift run -q symtune doctor
   swift run -q symtune sensors
   ```

The Makefile exposes the same workflow: `make build`, `make test`,
`make lint`, `make run`, `make doctor`, `make serve`.

## Code Style

- Swift 6 toolchain, strict concurrency
- `swiftlint` must pass with no new findings
- JSON output uses snake_case (`.convertToSnakeCase`); Swift properties stay
  camelCase
- No third-party SPM dependencies — system frameworks only

## Branch & PR Expectations

1. Create a feature branch from `main` (or fork the repo and branch there).
2. Keep changes focused on a single issue or feature.
3. Verify locally before pushing: `swift build`, `swift test`, and `swiftlint`
   all pass.
4. Open a PR against `main` with a clear description of what changed and why.
5. **CI must pass** before merge: CI runs lint + build-test on every PR.
6. Include a safety acknowledgment in the PR description if your changes touch
   privileged code paths (SMC writes, fan control, charge limits).

### Commit messages

- One logical change per commit, imperative mood ("Add X", "Fix Y").
- Reference the issue where relevant, e.g. `Closes #123`.

## Safety

symtune interacts with hardware (Apple SMC, display brightness, power
management). All write paths are bounded by `SafetyPolicy`. If your PR touches
any privileged code path:

- Verify restore-on-exit behavior
- Test on real hardware if possible
- Document any safety implications in the PR description

## Building the App

```bash
brew install xcodegen
make build-app
open build/app/SymairaTune.app
make smoke-app
```

## Questions?

Open a [Discussion](https://github.com/danieljustus/symaira-tune/discussions)
if you have questions before starting work. For security vulnerabilities,
follow the [Security Policy](.github/SECURITY.md) — do not open a public issue.
