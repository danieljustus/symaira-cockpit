# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in SymTune, please report it promptly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

### Preferred channels

| Severity | Channel |
|---|---|
| **Critical** (credential/keychain/code execution) | Email `daniel@symaira.com` (PGP: see `.well-known/security.txt`) |
| **High** | Email `daniel@symaira.com` or GitHub Security Advisory |
| **Medium/Low** | GitHub Security Advisory (preferred) or issue |

### GitHub Security Advisories

The preferred way to report and track vulnerabilities is through
[GitHub Security Advisories](https://github.com/danieljustus/symaira-cockpit/security/advisories/new).
This keeps vulnerability reports private until a fix is ready.

### What to include

- A description of the vulnerability and its impact
- Steps to reproduce (proof of concept preferred)
- The version/commit where it was found
- Any suggested fix (optional but appreciated)

### Credential handling

SymTune reads credentials from:

1. **symvault op:// references** — resolved at runtime via `symvault get`
2. **Environment variables** (e.g. `OPENROUTER_API_KEY`)
3. **macOS Keychain** (service: `com.symaira.symtune`)

If you find a credential leak or mishandling:
- Check `Sources/SymTuneCore/SecretRedactor.swift` — this is responsible for
  redacting secrets in logs
- Verify that `DefaultCredentialResolver` is used for all new credential access
  — never read `KeychainCredentials` directly outside of
  `CredentialResolver.swift`
- Report to daniel@symaira.com immediately

### Response timeline

| Severity | Triage | Fix committed | Patch released |
|---|---|---|---|
| Critical | 2h | 24h | 48h |
| High | 24h | 7d | 14d |
| Medium | 72h | 30d | 30d |
| Low | 7d | 60d | 90d |

## Security measures in the codebase

- `SecretRedactor.swift` — redacts known secret patterns in debug output
- `DefaultCredentialResolver` — centralizes credential resolution (op:// → env → Keychain)
- `KeychainCredentials.swift` — low-level Keychain read/write
- No secrets are ever logged. `CredentialCache` avoids storing values longer than needed.

## Out of scope

- The macOS Keychain itself (this is OS-managed)
- `symvault` CLI internals (separate repository)
- Third-party provider APIs (OpenRouter, Anthropic, etc.)
