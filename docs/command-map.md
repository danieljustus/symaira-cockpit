# Cockpit command map and transition contract

This is the reviewed command map for PB-2026-09-09 §4/§8. It describes the
current `symcockpit` dispatcher, not a release declaration or a promise to
remove compatibility surfaces.

## Root ownership

| Root spelling | Owner / route | Status |
|---|---|---|
| `sensors`, `battery`, `displays`, `metrics`, `ai-usage`, `processes`, `top` | Tune | Direct alias; help must match `tune <command>` |
| `status`, `awake`, `brightness`, `extbright`, `dim`, `warmth`, `restore`, `profile`, `fan`, `battery-limit` | Tune | Direct alias; help must match `tune <command>` |
| `doctor`, `permissions`, `history` | Reserved by the Operate family name | Tune remains available only as `tune <command>` |
| `serve` | Reserved by both Operate and Scope family names | Tune remains available only as `tune serve`; Operate/Scope remain namespaced |
| `version`, `--version`, `-V` | Cockpit | Equivalent root version aliases |
| `help`, `--help`, `-h` | Cockpit | Root help aliases |

The four collision names are intentionally not direct Tune aliases. Choosing
one family silently for a colliding spelling would make existing clients
ambiguous and would violate the retained `operate`/`scope` surfaces.

## Retained legacy family routes

These remain supported compatibility routes:

- `symcockpit tune <command>` for every Tune command, including collisions.
- `symcockpit operate <command>` and `symcockpit scope <command>`.
- The package-level historical `symtune`, `symoperate`, and `symscope` targets
  remain implementation/package compatibility surfaces; this map does not
  authorize standalone distribution or rename their identifiers and data
  paths.

## Completion and MCP status

There is currently **no completion implementation**: no `completion`
subcommand, completion script, or shell-completion entry point exists in this
repository. The acceptance suite therefore verifies that completion is not
falsely advertised or routed as a Tune command. This is an honest capability
statement, not a migration gate waiver.

MCP remains family-owned and namespaced: `tune serve`, `operate serve`, and
`scope serve` retain their existing stdio JSON-RPC contracts. Protocol tests
use safe initialize/tools-list fixtures only; they do not call hardware,
Operate desktop actions, or state-changing Scope operations.

## Transition window

The direct aliases are additive during the transition. The `tune` prefix and
family routes stay supported until a **future authorized release** explicitly
announces a reviewed migration. No date or version is implied here. Before
that release, the project must have tested replacement spellings, completion
(if introduced), help and MCP compatibility, data backup/restore and
rollback, and the native permission/identifier migration gates. Do not remove
old command paths, helper/signing/Keychain identifiers, or data directories
as part of a cosmetic rename.
