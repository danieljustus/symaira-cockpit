# Symaira Cockpit command map

Symaira Cockpit is the macOS hardware/system-tuning product. The `symcockpit`
dispatcher retains the explicit `tune <command>` tree and safe direct aliases
for non-colliding tune commands.

| Surface | Status |
|---|---|
| `symcockpit tune <command>` | Supported tune CLI |
| `symcockpit <safe-tune-command>` | Supported direct tune alias |
| `symcockpit version` | Supported version report |
| `symcockpit operate` / `symcockpit scope` | Removed; use optional Symaira Brain modules |

The former operate and scope packages are no longer dependencies of Cockpit.
Tune MCP remains available as `symcockpit tune serve`, with stdout reserved for
JSON-RPC frames.
