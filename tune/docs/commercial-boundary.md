# Commercial Boundary

`symaira-tune` is a single, open **Apache-2.0** project. There is no separate
"Pro" repository or feature gate for hardware-tuning capabilities.

## What is in this repository

Everything ships from this repo:

- Read state: thermal pressure, battery health, display/EDR info, fan RPM.
- Keep-awake (power assertions).
- Display tuning: built-in brightness, extended/EDR brightness, software dim
  overlay, color warmth.
- **Fan speed control** via SMC writes.
- **Battery charge limiting** via SMC writes.
- The full CLI surface and the MCP server.

No billing, tenant, account, or cloud code lives here.

## Privilege model for SMC writes

Fan and battery-charge-limit commands write to the Apple SMC. These operations
require root privileges. The simplest supported mode is to run the CLI with
`sudo`:

```bash
sudo symtune fan set 0.5
sudo symtune battery-limit set 80
```

The same process performs the write, clamps the value through `SafetyPolicy`, and
restores the original SMC values on normal exit or `SIGINT`/`SIGTERM`.

A future optional `symtune-helper` daemon (installed via `SMAppService`) may be
added so that users do not have to run the entire `symtune` binary as root. That
helper will also live in this repository under Apache-2.0; it is not a
commercial gate. `SMCHelperProtocol` already defines the XPC contract.

## Implementation rule

Keep all capability code in this repo. Any privileged helper must be a
convenience wrapper around the same core logic, not a separate product tier.

## Public/pro boundary

There is no private commercial feature set for `symaira-tune`. Proprietary
Symaira products (e.g. cloud or enterprise tiers) consume this open core as a
library but do not add hardware-tuning features that are withheld from it.
