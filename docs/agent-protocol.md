# Cockpit app-agent protocol

`symcockpit agent --stdio` is the child process of `Symaira Cockpit.app`
(Cockpit 2, architecture §5.1/§8). The app owns no logic: it asks the agent,
and the agent answers from the same command register and handlers as the CLI
(`symcockpit …`) and the MCP server (`symcockpit serve`). Nothing the window
shows can contradict the CLI (R06).

- Wire format: **JSON-RPC 2.0, one message per line (NDJSON)** on stdin/stdout,
  UTF-8, `\n` terminated. Batches (arrays) are not supported.
- **stdout carries protocol frames only.** Logs and diagnostics go to stderr.
- Protocol version: **1** (`PROTOCOL_VERSION` in `symcockpit-contract`).
- Rust: `crates/symcockpit/src/agent.rs` (session, loop), wire types in
  `crates/symcockpit-contract/src/agent_proto.rs`, parent check in
  `crates/symcockpit-macos/src/parent_check.rs`.
- Swift client: `tuning/Sources/SymCockpitCore/AgentClient.swift` (in
  `SymCockpitCore` because the GUI embeds logic from there, never its own).

## Starting the agent

```
symcockpit agent --stdio [--data-dir <path>]
```

The command is internal to the app bundle and not part of `--help`.

| Exit | Meaning |
|---|---|
| 0 | stdin reached EOF, SIGTERM/SIGINT arrived, or the reader of stdout went away |
| 1 | stdin line over 4 MiB (the stream cannot be trusted any more) |
| 2 | usage error (missing `--stdio`, unknown argument) |
| 3 | **parent check failed** — see below; a reason is printed on stderr |

### Parent check

The agent serves only a parent process that is the signed Cockpit app. It asks
Security.framework whether the running code of its parent satisfies

```
anchor apple generic and identifier "com.symaira.cockpit"
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists   (Developer ID Application)
and certificate 1[field.1.2.840.113635.100.6.2.6] exists       (Developer ID CA)
and certificate leaf[subject.OU] = "<TEAM>"
and !entitlement["…"] exists   (the four hardened-runtime escape entitlements)
```

— the same shape as the fan helper's `CodeSigningRequirements` (a unit test
pins both to each other). `<TEAM>` is baked into the build through the
environment variable `SYMCOCKPIT_TEAM_ID` at `cargo build` time (the value
`EXPECTED_TEAM_ID` of `scripts/build-app.sh`). It is never read from the
agent's own signature or the environment at run time. A build without it
exits 3 ("no team identifier"). The parent is identified by PID, re-read after
the check.

A development build signed with a self-signed certificate does not satisfy the
requirement, by design (same stance as the helper). For tests there is one
escape hatch:

> **Test switch (debug builds only).** `SYMCOCKPIT_AGENT_SKIP_PARENT_CHECK=1`
> skips the check and prints a notice on stderr. It exists under
> `cfg(debug_assertions)`; the release build does not contain it.
> `tests/agent_release.rs` (`make rust-test-agent-release`, CI job `rust`)
> proves that the release binary exits 3 with the switch set and that the
> switch name is not in the binary.

## Messages

Requests are `{"jsonrpc":"2.0","id":<int|string>,"method":…,"params":{…}}`.
The response echoes `id` and has `result` or `error`. A request without an `id`
is a notification: handled, never answered. The agent sends one kind of
notification, `event`.

The agent handles requests one at a time, in order. A slow command delays the
requests and samples behind it. Responses to one request are written before the
events it caused.

| Method | Before `hello` | Params | Result |
|---|---|---|---|
| `ping` | yes | — | `{}` |
| `hello` | yes | `protocol_version`, `client?` | see below |
| `call` | no | `command`, `params?` | `{status, command, risk, …}` |
| `confirm` | no | `plan_id` | plan report |
| `subscribe` | no | `command`, `params?`, `interval_visible_ms?`, `interval_hidden_ms?` | `{subscription_id, command, interval_ms}` |
| `unsubscribe` | no | `subscription_id` | `{subscription_id, active}` |
| `set_visibility` | no | `visible` | `{visible, active}` |

Unknown request fields are ignored; clients must ignore unknown response fields.

### `hello`

Request: `{"protocol_version":1,"client":"symcockpit-app"}`. Result:

```json
{
  "protocol_version": 1,
  "server_version": "0.12.2",
  "capabilities": {
    "methods": ["hello","call","confirm","subscribe","unsubscribe","set_visibility","ping"],
    "topics": ["sensors","battery","displays","metrics","processes","top","status","brightness.get","awake.status","fan.status"],
    "max_subscriptions": 32,
    "min_interval_ms": 100, "max_interval_ms": 3600000,
    "default_interval_visible_ms": 1000, "default_interval_hidden_ms": 10000
  },
  "commands": [
    {"name":"metrics","risk":"read","input_schema":{…}},
    {"name":"dim.set","risk":"reversible","input_schema":{…}},
    {"name":"fan.set","risk":"risky","input_schema":{…}}
  ]
}
```

`commands` is the command register (`symcockpit-contract`) minus the commands
that are not data (`serve`, `help`, `version`, `ai-usage serve`, `fan governor`).
`input_schema` is the JSON Schema of the MCP tool arguments. A client that
sends another protocol version gets error `-32010` and may retry with one of
`data.supported`; until a `hello` succeeds, every method except `ping` and
`hello` fails with `-32002`.

### `call` and the risk classes (architecture §5.3)

`command` is a register name (`metrics`, `brightness.set`, `fan.set`, …),
`params` the arguments exactly as the MCP tool takes them (`input_schema`).
The agent runs the command through the dispatch path of MCP `tools/call`
(`mcp::Server::run_spec`): same argument parsing, same native handlers, same
Swift fallback. There is no second implementation.

| Risk | Behaviour |
|---|---|
| `read` | runs; result `{"status":"ok","command","risk","output":<JSON>}` |
| `reversible` | runs directly, same result shape |
| `human_only` | runs directly (the app shows it to the human; MCP never does) |
| `risky` | **does not run.** A plan is recorded and returned: `{"status":"confirmation_required","command","risk","plan":{id, state, expires_at, expires_in_s, digest, items:[{action,target,command,params}]}}` |

The app shows the plan and, only on the user's approval, sends
`confirm {"plan_id":…}`. Plans come from `symcockpit-core::plan` (two-step
engine): valid 300 s, confirmable once, bound to command and parameters by a
digest, re-checked before the action. They live in the agent's memory; a
restarted agent knows no old plan. The confirm result is the plan report
(`plan_id`, `status` = `confirmed`/`failed`/`unsupported`, `counts`,
`results[]`) plus the command's `output` or, when it failed, `error`
(`{code, message, data}` like a `call` error). `status` reflects whether the
command succeeded; a post-condition (readback) belongs to the command's own
output.

One exception: `plan.confirm` (the second step of the storage-cleanup plans,
which have their own plan engine entry) is risky but already is a
confirmation, and runs directly.

### `subscribe`, events, `unsubscribe`, `set_visibility`

`subscribe` samples a command repeatedly. Only commands in
`capabilities.topics` (cheap, side-effect-free reads) are accepted.
**Nothing is measured while there is no subscription** (Q04): with no
subscriber the agent sleeps until the next request. The first sample is taken
at once, after the response that names the `subscription_id`; later ones follow
`interval_visible_ms` (default 1000) after the previous sample finished, or
`interval_hidden_ms` (default 10000) while the app reports itself hidden.
Intervals are 100 ms to 1 h; at most 32 subscriptions.

`set_visibility {"visible":false}` is sent when no view that needs
measurements is on screen; every subscription then runs at its hidden interval.
`{"visible":true}` samples what became due immediately. The initial state is
visible.

Each sample is an `event` notification:

```json
{"jsonrpc":"2.0","method":"event","params":{
  "subscription_id":1,"command":"awake.status","seq":2,"monotonic_ms":118,
  "result":{"active":false,"prevent_display_sleep":false,"reason":"","started_at":816941470.298}}}
```

- `seq` counts from 1 per subscription; `monotonic_ms` is the agent's monotonic
  clock (since it started) at the end of the sample.
- A failed sample carries `error` (same object as a command error) instead of
  `result`; sampling continues. A capability this Mac does not have
  (`class":"unsupported"`) ends the subscription: that event has `"ended":true`
  and nothing follows. There are no made-up values: a gap is an `error` event
  or no event.
- After the `unsubscribe` response no further event of that subscription is
  written.

Sampling and `call` share one thread, because the handler table is not `Send`
and display enumeration needs the main thread. (Shortcut: a slow command delays
samples. Upgrade: move samplers to threads once handlers are `Send`.)

## Errors

```json
{"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"permission error: Bluetooth access was not granted","data":{"exit_code":3,"class":"permission"}}}
```

| Code | Meaning |
|---|---|
| -32700 | Parse error (line is not JSON); `id` is `null` |
| -32600 | Invalid Request (not an object, no `jsonrpc:"2.0"`, no `method`) |
| -32601 | Method not found |
| -32602 | Invalid params (also: unknown or not callable `command`, a command that cannot be subscribed to, interval out of range, unknown `subscription_id`) |
| -32603 | Internal error |
| **-32000** | A command ran and failed. `message` is what the CLI prints after `symcockpit: `; `data.class` is `usage` (exit 2), `permission` (3), `unsupported` (4) or `error` (1) and `data.exit_code` the CLI exit code |
| -32002 | Not ready: `hello` first |
| -32010 | Protocol version not supported; `data = {supported:[…], requested}` |
| -32011 | Too many subscriptions |

### macOS permissions (TCC) in the child process

Functions that need Bluetooth, Accessibility or audio-capture permission report a
missing permission as `class: "permission"` and a missing capability as
`class: "unsupported"`; they must not hang or crash the agent. Which
process a permission is attributed to when the agent is a child of the app, and
whether the app's `Info.plist` usage strings cover it, is **spike S1** and has
not been run: no TCC dialog was triggered while building this protocol.

## Versioning

`PROTOCOL_VERSION` is one integer. App and agent ship in the same bundle, so a
mismatch means a broken or half-updated install, and the app must show that as a
diagnosis (the Swift client does: `AgentFailure.versionMismatch`).

- Not a version bump: new commands, new fields in results, new topics, new
  notifications, new methods (`capabilities.methods` lists them).
- A bump: changing the meaning or shape of an existing method, result field,
  error code or the framing. A bumped agent speaks exactly its own version; the
  `hello` error tells the client which.

## Example session

`>` is the app, `<` the agent. Captured from the debug binary up to the second
event (abridged: `commands`, `capabilities`, some fields); the `unsubscribe`
lines show the shape `tests/agent_stdio.rs` asserts:

```
> {"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocol_version":2}}
< {"error":{"code":-32010,"data":{"requested":2,"supported":[1]},"message":"protocol version 2 is not supported (this agent speaks 1)"},"id":1,"jsonrpc":"2.0"}
> {"jsonrpc":"2.0","id":2,"method":"hello","params":{"protocol_version":1,"client":"symcockpit-app"}}
< {"id":2,"jsonrpc":"2.0","result":{"capabilities":{…},"commands":[…],"protocol_version":1,"server_version":"0.12.2"}}
> {"jsonrpc":"2.0","id":3,"method":"call","params":{"command":"profile.list"}}
< {"id":3,"jsonrpc":"2.0","result":{"command":"profile.list","output":{"profiles":[]},"risk":"read","status":"ok"}}
> {"jsonrpc":"2.0","id":4,"method":"call","params":{"command":"fan.set","params":{"fraction":0.7}}}
< {"id":4,"jsonrpc":"2.0","result":{"command":"fan.set","plan":{"digest":"f36f…","expires_in_s":300,"id":"pl_762901aab4845a8b","items":[{"action":"command","command":"fan.set","params":{"fraction":0.7},"target":"fan.set"}],"kind":"agent_command","state":"pending"},"risk":"risky","status":"confirmation_required"}}
> {"jsonrpc":"2.0","id":5,"method":"subscribe","params":{"command":"awake.status","interval_visible_ms":100}}
< {"id":5,"jsonrpc":"2.0","result":{"command":"awake.status","interval_ms":100,"subscription_id":1}}
< {"jsonrpc":"2.0","method":"event","params":{"command":"awake.status","monotonic_ms":0,"result":{"active":false,…},"seq":1,"subscription_id":1}}
< {"jsonrpc":"2.0","method":"event","params":{"command":"awake.status","monotonic_ms":118,"result":{"active":false,…},"seq":2,"subscription_id":1}}
> {"jsonrpc":"2.0","id":6,"method":"unsubscribe","params":{"subscription_id":1}}
< {"id":6,"jsonrpc":"2.0","result":{"active":0,"subscription_id":1}}
  (stdin closed → the agent exits 0)
```

## Swift client

`AgentClient` (SymCockpitCore): `start()` launches the agent and completes
`hello`; `call`, `confirm`, `subscribe`, `unsubscribe` and `setVisibility` map
to the methods; events and state changes arrive through callbacks. States:
`stopped`, `starting`, `ready(AgentHello)`, `failed(AgentFailure)`. A missing
executable, exit status (3 = parent check, with the stderr tail), protocol
mismatch, non-protocol output and timeouts each have their own
`AgentFailure`; every pending request fails with it and no value is invented.
There is no automatic restart; the app calls `restart()` and subscribes again.
`AgentClientTests` run it against a Perl fake agent (no Rust binary, no
hardware).

`AgentSession` (SymCockpitCore) is the app-wide layer on top: one session per
app run (`AgentSession.bundled()` takes `symcockpit` from the directory of the
app's executable), started at launch and stopped (stdin closed) at quit. It keeps
the subscriptions of the views and sets them up again after a restart, derives
`set_visibility` from the views that report themselves visible, and turns calls
into `ActionOutcome` (`done`, `needsConfirmation(plan)`, `failed`). The app shows a
failed state as a diagnosis (`AgentDiagnosis`) with a restart button. Its tests
(`AgentSessionTests`, and the view-model tests in `AgentViewModelTests`) use the
same fake agent (`tuning/Tests/SymCockpitCoreTests/Fixtures/fake-agent.pl`).
Runtime acceptance of the app on the agent: `docs/app-acceptance.md`.

## Not part of this version

- Setting a fan profile or a Cool target: the register describes `fan.profile`
  and `fan.target` without an argument (wave 2D-1). The app takes the argument
  name from `hello` (`input_schema`) and says so when there is none.
- Finder jobs, clipboard history and the privileged helper's XPC are not
  protocol methods; they arrive with their areas through new commands and
  topics.
- If spike S1 shows that the child process cannot hold the required TCC
  permissions, decision D14 (a Rust library inside the app) is the fallback; it
  is not built here.
