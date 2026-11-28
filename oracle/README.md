# Oracle: Cockpit v0.12 (Swift)

The Rust rebuild of Symaira Cockpit that replaces the Swift core step by step (ADR 0003,
`docs/adr/0003-strangler-migration-mit-orakel.md`). The released Swift binary is
the **oracle**: this directory holds what it printed, recorded reproducibly, so
the Rust port can be compared against it without needing the Swift build.

Only the **structure** of device-dependent output is recorded (keys and types),
plus the exact bytes of output that holds no device data (help, usage text,
`tools/list`) and exit codes. No measurement, name, UUID or path is committed.

## Layout

```
oracle/
  README.md
  tools/shape.py          JSON -> shape; `python3 -I shape.py --self-test`
  tools/capture.py        case table, runner, fixture writer (called by the script)
  tools/mcp_session.py    one MCP stdio session (initialize, tools/list, tools/call)
  v0.12/
    manifest.json         the contract read by the harness
    mcp-initialize.json   exact `initialize` params used for the MCP session
    cases/                one fixture per case
scripts/oracle-capture.sh builds nothing; records the oracle from a given binary
```

## Manifest (`schema` 1)

```json
{"schema":1,
 "source":{"swift_commit":"<full sha>","version":"0.12.2","captured_on":{"arch":"arm64","macos":"27.2.1"}},
 "env":{"isolate_xdg":true,"set":{"KEY":"VALUE"}},
 "cases":[ ... ]}
```

`swift_commit` is the last commit that touched the Swift sources
(`Sources tuning history Package.swift Package.resolved`); the script refuses to
run when those paths are modified.

| `kind` | Fields | Check |
| --- | --- | --- |
| `json_shape` | `argv`, `expect_exit`, `fixture` | stdout is JSON; its shape equals the fixture |
| `exact` | `argv`, `expect_exit`, `fixture`, `normalize` | stdout, after the regex replacements in `normalize` (`{"pattern","replacement"}`), equals the fixture byte for byte |
| `exit_code` | `argv`, `expect_exit` | exit code only |
| `mcp_tools_list` | `fixture` | the 26 v0.12 tools in `result` of `tools/list` equal the fixture (value equality; object keys are sorted in the file because the Swift server emits them in random order). Further tools are allowed only if the command register declares them (`mcp_name`) **and** `snapshots/mcp/tools_list.json` holds exactly the tool the server lists; an undeclared tool, a tool without snapshot, a snapshot that differs and a snapshot tool the server no longer lists each fail the case |
| `mcp_call_shape` | `tool`, `arguments`, `fixture` | shape of `result.content[0].text` parsed as JSON (`result` itself if it is not JSON) |

### Shape form (`*.shape.json`)

```
{"type":"object","properties":{key: Shape}}   keys sorted
{"type":"array","items": Shape | null}        null: no element seen (empty array)
{"type":"string"|"number"|"boolean"|"null"}   integer and float are both "number"
```

Array elements are merged into one `items` shape: objects take the union of
keys, `null` merges into the other type (an optional value seen as `null` and
as `T` becomes `T`), an empty inner array adopts its sibling. Any other type
clash is a conflict; `shape.py` reports it and the capture fails (there were
none in v0.12). Swift's synthesized `Codable` **omits** nil optionals, so a key
can be absent on one machine state and present on another; see Limits.

### Environment

`env.set` is applied on top of a cleared environment (`PATH=/usr/bin:/bin`);
`isolate_xdg` means a fresh temporary `HOME` (also `CFFIXED_USER_HOME`),
`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME` per case. The capture
and the `symcockpit-oracle` harness apply the same rules; the harness still passes
`SYMCOCKPIT_LEGACY_BIN` on (native mode points it at a tripwire), but since wave 2D the Rust
binary ignores it, so a forwarded case can no longer occur:

| Variable | Why |
| --- | --- |
| `SYMTUNE_CHECK_UPDATES=0` | `UpdateChecker.isUpdateCheckEnabled` (tuning/.../UpdateChecker.swift) |
| `SYMCOCKPIT_CHECK_UPDATES=0` | `CockpitUpdatePolicy` (Sources/symcockpit/CockpitUpdateChecker.swift); no request is ever made |
| `LC_ALL=C`, `TZ=UTC` | locale- and zone-independent text |

`HOME` is isolated because the fan profile lives in
`~/.symtune/fan-profile.json` (`FanProfileStore.defaultURL`), which XDG
variables do not move.

## Recording

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer dev-external swift build -c release
SWIFT_BIN="$(... swift build -c release --show-bin-path)/symcockpit" scripts/oracle-capture.sh
```

* Each case runs with a fresh isolated environment, stdin from `/dev/null`, and
  its exit code is checked against `expect_exit`; the first mismatch fails the run.
* The run happens inside `sandbox-exec` with a profile that kills any process
  touching `~/.config/symtune`, `~/.local/share/symtune`, `~/.cache/symtune` or
  `~/.symtune`. The script also stats those paths before and after and fails
  if anything changed.
* Raw stdout, stderr and exit codes go to `ORACLE_RAW_DIR/<run>/`
  (default `/Volumes/1TB_NVMe_SN850X/Dev/evidence/symaira-cockpit/cockpit2-oracle/raw`), never into
  the repo; the script refuses a raw directory inside the repo or an existing run.
* Run it twice and `diff -r` the fixture directories: they must be identical.

## Cases

Read-only by construction. Each case lists the source lines showing that it
reads state or fails in argument parsing before any hardware or file access
(`why` in `capture.py`). Commands that write are not run, not even with invalid
arguments: `fan set|auto|governor`, `battery-limit set|clear`, `brightness set`,
`extbright`, `dim set|reset`, `warmth set|reset`, `restore`, `profile save|load|delete`,
`awake` (blocking forms and `off`), `status --watch` (endless). `ai-usage` is not
run (it calls `symbrain`); only its static `--help` is recorded. `serve` is
covered by the MCP cases.

MCP (`<bin> serve`, NDJSON JSON-RPC 2.0, protocol `2025-06-18`): the default
configuration of an isolated home is `mcp.mode = "full"` (`TuneConfig`,
`SYMTUNE_MCP_MODE`), so `tools/list` holds 26 tools. In `read-only` mode it holds
only the 12 tools with `isReadOnly == true` (verified once, not fixtured):
`get_capabilities`, `get_sensors`, `get_battery`, `list_displays`,
`get_system_metrics`, `get_top_processes`, `get_ai_usage`, `keep_awake_status`,
`get_brightness`, `list_profiles`, `get_status`, `get_history`
(`tuning/Sources/SymCockpitMCP/TuneTools.swift`). `get_ai_usage` is listed but
never called. The server reports `serverInfo.version` from `TuneVersion`
(`0.10.0`), not the dispatcher's `0.12.2`; `initialize` is not fixtured.

## Privacy

Committed files contain keys, types, static help text and tool schemas only.
Before committing, grep them for serial number, hardware UUID, host and user
name, absolute home paths, UUID and MAC patterns, and process or volume names from the
raw output. Objects that use device data as **keys** (a dictionary keyed by
process or interface name) must not be recorded as properties; v0.12 has none
(every such collection is an array of objects). If one appears, record it as a
generic map and extend the format deliberately.

## Newer tools (Rust rebuild)

The oracle freezes v0.12; it does not grow. The areas added since (storage,
audio, Bluetooth, ...) show up in `tools/list` as extra tools. They are
checked against the register and `snapshots/mcp/tools_list.json`, which the
`symcockpit` test `the_new_tools_match_their_schema_snapshot` keeps current
(`SYMCOCKPIT_UPDATE_SNAPSHOTS=1` rewrites it; review the diff). The fixture
under `oracle/v0.12/` is never edited for a new tool.

## Allowed drift

`oracle/allowed-drift.json` (outside the frozen `v0.12/` directory) lists, per
case id and JSON path, a missing or extra key that is expected, with the reason:
a documented additive extension (for example `fans` and `software_override` in
`fan status` since v0.13.1, #429) or a key that depends on machine state
(`active_overrides.fan_fraction`, see Limits). A listed key is reported as a
hint; any unlisted drift, and any type change of a listed key, still fails the
case. Add an entry only together with the change that causes it (#455).

## Limits

* Structure, not values. A Rust port can match every fixture and still report
  wrong numbers, wrong units or wrong semantics; values need separate tests.
* One machine (Apple Silicon, one macOS version, one display setup, a battery,
  an SMC). Keys that depend on hardware state are fixed to what this machine
  showed, for example `active_overrides.fan_fraction` (present only while the
  fans are in manual mode), the `apple_*` battery keys and the EDR display keys.
* Empty arrays and `null` values (`metrics.cpu.per_core_utilization`,
  `*.notes`, `cool_target_celsius`) carry no element or type information; the
  harness should accept any content there.
* Only the root dispatcher `symcockpit` is recorded. The longer tune usage text
  in `SymCockpitMain.swift` is unreachable through it (`help` is answered by the
  root) and is not part of the oracle.
