# Swift byte fixtures

`expected/` holds what the Swift v0.12.2 binary (`Products/Release/symcockpit`,
built from main 1a91baf) printed for the inputs in `data/`, captured with a
cleared environment (`HOME` empty dir, `TZ=UTC`, `LC_ALL=C`,
`SYMCOCKPIT_CHECK_UPDATES=0`):

```
symcockpit history --json --data-dir data         > expected/history_--json.out
symcockpit history --data-dir data                > expected/history.out
symcockpit history --json -n 2 --data-dir data    > expected/history_--json_-n_2.out
symcockpit history --limit 1 --data-dir data      > expected/history_--limit_1.out
symcockpit profile list --data-dir data           > expected/profile_list.out
symcockpit version --json | version               > expected/version_--json.out, version.out
symcockpit serve --data-dir data  (tools/call get_history {limit:5}, list_profiles)
                                                  > expected/mcp_*.json  (the result text)
```

The inputs are synthetic (no private data). They cover whole-number doubles
(`85`, not `85.0`), `1e-05`, a 12-digit integer-valued double, `0.30000000000000004`,
quotes, a newline, a backslash, `/` and non-ASCII text. `tests/swift_fixtures.rs`
runs the Rust binary on the same inputs and compares the bytes.
