# Symaira Cockpit command map

Symaira Cockpit is the macOS hardware/system-tuning product. The `symcockpit`
dispatcher exposes every tune command directly at the root.

| Surface | Status |
|---|---|
| `symcockpit <command>` | Supported CLI (thermals, power, display, fans, diagnostics) |
| `symcockpit version` | Supported version report |
| `symcockpit tune <command>` | Removed in v0.12 after the v0.8/v0.9 deprecation window; prints the direct command, exit 2 |
| `symcockpit operate` / `symcockpit scope` | Removed; dedicated migration hint to Symaira Brain, exit 4 |

The former operate and scope packages are no longer dependencies of Cockpit.
The Tune MCP server is `symcockpit serve`, with stdout reserved for JSON-RPC
frames.
