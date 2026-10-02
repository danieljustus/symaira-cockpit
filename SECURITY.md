# Security Policy

Symaira Cockpit is a native macOS hardware/system-tuning tool for thermals,
power, display and system metrics, with optional usage reports from Symaira
Brain. Please report vulnerabilities responsibly.

## Reporting a vulnerability

**Do not open a public GitHub issue for a security vulnerability.**

| Severity | Channel |
|---|---|
| **Critical** (credential, keychain, or code execution) | Email `daniel@symaira.com` |
| **High** | Email `daniel@symaira.com` or [GitHub Security Advisory](https://github.com/danieljustus/symaira-cockpit/security/advisories/new) |
| **Medium/Low** | [GitHub Security Advisory](https://github.com/danieljustus/symaira-cockpit/security/advisories/new) preferred, or a public issue for non-sensitive details |

Include:

- A description and impact
- Minimal reproduction steps or proof of concept
- The affected version or commit
- A suggested fix, if available

Please do not include live credentials or other private data in a report.

## Credential handling

Provider usage is fetched through `symbrain usage`. `SymBrainUsageProvider`
construction is metadata-only and must not read credentials. For Cockpit-managed
credentials, `SymVaultCredentialStore.reference(for:)` supplies opaque
`symvault://` URIs; `symbrain` resolves them, not Cockpit.

Explicit credential saves send values to `symvault` through standard input,
never command arguments. One-shot legacy migration reads through
`KeychainCredentials` and deletes the old Keychain item only after the SymVault
write succeeds. Normal usage launches do not perform that migration.

`SecretRedactor`, in the `history` package, is the final output boundary for
error and history text; credential-shaped material must not be written verbatim
to logs or persisted history.

When reviewing credential-related changes:

- Keep provider construction free of credential I/O and usage references opaque.
- Keep legacy Keychain migration behind `KeychainCredentials`.
- Route error/history output through `SecretRedactor`.
- Add regression tests without committing provider-format secrets.
- Report suspected exposure immediately through the private channels above.

## Response timeline

| Severity | Triage | Fix committed | Patch released |
|---|---:|---:|---:|
| Critical | 2h | 24h | 48h |
| High | 24h | 7d | 14d |
| Medium | 72h | 30d | 30d |
| Low | 7d | 60d | 90d |

## Security boundaries

- Operate and Scope are optional Symaira Brain modules, not Cockpit security
  boundaries or capabilities.
- MCP `serve` modes keep stdout reserved for JSON-RPC frames.
- Tune writes are clamped through its safety policy and restored on teardown.
- Update checking is optional network access; the product otherwise operates
  locally.

The macOS Keychain and the internals of the separate `symvault` tool are outside
this repository's control.
